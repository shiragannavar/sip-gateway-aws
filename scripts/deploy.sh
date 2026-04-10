#!/bin/bash
##
## Deploy (or update) the SIP gateway Docker Compose stack to an EC2 instance.
##
## Usage:
##   ./deploy.sh --customer-sbc <address> --key <path-to-pem> [options]
##
## Prerequisites:
##   - AWS CLI configured (aws sts get-caller-identity works)
##   - EC2 instance already running (via terraform)
##   - SSH key pair (.pem) for the instance
##
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DOCKER_DIR="$PROJECT_ROOT/docker"

REGION="${AWS_DEFAULT_REGION:-ap-south-1}"
INSTANCE_ID=""
INSTANCE_NAME="sip-gateway"
KEY_FILE=""
SSH_USER="ubuntu"
CUSTOMER_SBC_ADDRESS=""
CUSTOMER_SBC_PORT="5060"
AUTH_USER=""
AUTH_PASSWORD=""
ELEVENLABS_SIP_HOST="${ELEVENLABS_SIP_HOST:-sip-static.rtc.elevenlabs.io}"
ELEVENLABS_SIP_PORT="${ELEVENLABS_SIP_PORT:-5060}"

while [[ $# -gt 0 ]]; do
    case $1 in
        --customer-sbc)      CUSTOMER_SBC_ADDRESS="$2"; shift 2 ;;
        --customer-sbc-port) CUSTOMER_SBC_PORT="$2"; shift 2 ;;
        --auth-user)         AUTH_USER="$2"; shift 2 ;;
        --auth-password)     AUTH_PASSWORD="$2"; shift 2 ;;
        --region)            REGION="$2"; shift 2 ;;
        --instance-id)       INSTANCE_ID="$2"; shift 2 ;;
        --instance-name)     INSTANCE_NAME="$2"; shift 2 ;;
        --key)               KEY_FILE="$2"; shift 2 ;;
        --ssh-user)          SSH_USER="$2"; shift 2 ;;
        *)                   echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [ -z "$CUSTOMER_SBC_ADDRESS" ]; then
    echo "Error: --customer-sbc <address> is required"
    echo ""
    echo "Usage: ./deploy.sh --customer-sbc <SBC_IP> --key <path-to-pem> [options]"
    echo ""
    echo "Required:"
    echo "  --customer-sbc <addr>         Telephony provider SBC IP or FQDN"
    echo "  --key <path>                  Path to SSH .pem key file"
    echo ""
    echo "Optional:"
    echo "  --customer-sbc-port <port>    SBC SIP port (default: 5060)"
    echo "  --auth-user <user>            Digest auth username"
    echo "  --auth-password <pass>        Digest auth password"
    echo "  --region <region>             AWS region (default: ap-south-1)"
    echo "  --instance-id <id>            EC2 instance ID (auto-detected if omitted)"
    echo "  --instance-name <name>        Instance Name tag (default: sip-gateway)"
    echo "  --ssh-user <user>             SSH username (default: ubuntu)"
    exit 1
fi

if [ -z "$KEY_FILE" ]; then
    echo "Error: --key <path-to-pem> is required for SSH access"
    exit 1
fi

if [ ! -f "$KEY_FILE" ]; then
    echo "Error: Key file not found: $KEY_FILE"
    exit 1
fi

if [ ! -d "$DOCKER_DIR" ]; then
    echo "Error: Docker directory not found at $DOCKER_DIR"
    echo "Make sure you're running this from the amazon/scripts/ folder."
    exit 1
fi

# Auto-detect instance ID from Name tag if not provided
if [ -z "$INSTANCE_ID" ]; then
    echo "Looking up instance ID for Name=$INSTANCE_NAME in $REGION..."
    INSTANCE_ID=$(aws ec2 describe-instances \
        --region "$REGION" \
        --filters "Name=tag:Name,Values=$INSTANCE_NAME" "Name=instance-state-name,Values=running" \
        --query 'Reservations[0].Instances[0].InstanceId' \
        --output text 2>/dev/null || echo "")

    if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "None" ]; then
        echo "Error: Could not find running instance with Name=$INSTANCE_NAME in $REGION"
        echo "Did you run 'terraform apply' first?"
        exit 1
    fi
fi

echo "=== Deploying SIP Gateway (AWS) ==="
echo "  Region:      $REGION"
echo "  Instance ID: $INSTANCE_ID"
echo "  SBC:         $CUSTOMER_SBC_ADDRESS:$CUSTOMER_SBC_PORT"
[ -n "$AUTH_USER" ] && echo "  Auth:        $AUTH_USER / ****"
echo ""

# Get Elastic IP (public IP)
EXTERNAL_IP=$(aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text 2>/dev/null || echo "")

if [ -z "$EXTERNAL_IP" ] || [ "$EXTERNAL_IP" = "None" ]; then
    echo "Error: Instance $INSTANCE_ID has no public IP."
    echo "Terraform should have created and attached an Elastic IP."
    echo "Check: aws ec2 describe-addresses --region $REGION"
    exit 1
fi

INTERNAL_IP=$(aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PrivateIpAddress' \
    --output text 2>/dev/null || echo "")

if [ -z "$INTERNAL_IP" ] || [ "$INTERNAL_IP" = "None" ]; then
    echo "Error: Could not detect private IP for $INSTANCE_ID."
    exit 1
fi

echo "  Elastic IP:  $EXTERNAL_IP"
echo "  Private IP:  $INTERNAL_IP"
echo ""

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 -i "$KEY_FILE")
SSH_TARGET="$SSH_USER@$EXTERNAL_IP"
REMOTE_DIR="/opt/sip-gateway"
STAGING_DIR="sip-gateway-docker-staging"

# Wait for instance to be SSH-reachable and Docker to be installed (user_data may still be running)
echo ">>> Waiting for instance to be ready..."
MAX_WAIT=180
WAITED=0
while true; do
    if ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "command -v docker" &>/dev/null; then
        break
    fi
    WAITED=$((WAITED + 10))
    if [ "$WAITED" -ge "$MAX_WAIT" ]; then
        echo "Error: Instance not ready after ${MAX_WAIT}s. user_data may have failed."
        echo "SSH in manually to check: ssh -i $KEY_FILE $SSH_TARGET"
        echo "Logs: /var/log/sip-gateway-startup.log"
        exit 1
    fi
    echo "  Waiting for Docker install... (${WAITED}s / ${MAX_WAIT}s)"
    sleep 10
done
echo "  Instance ready."
echo ""

echo ">>> Copying docker files to instance..."
ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "rm -rf ~/$STAGING_DIR && mkdir -p ~/$STAGING_DIR"

scp "${SSH_OPTS[@]}" -r "$DOCKER_DIR"/. "$SSH_TARGET:~/$STAGING_DIR/"

ssh "${SSH_OPTS[@]}" "$SSH_TARGET" \
    "sudo mkdir -p $REMOTE_DIR && sudo rm -rf $REMOTE_DIR/docker && sudo mv ~/$STAGING_DIR $REMOTE_DIR/docker"

echo ">>> Configuring .env..."
ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "sudo tee $REMOTE_DIR/docker/.env > /dev/null" <<EOF
EXTERNAL_IP=$EXTERNAL_IP
INTERNAL_IP=$INTERNAL_IP
CUSTOMER_SBC_ADDRESS=$CUSTOMER_SBC_ADDRESS
CUSTOMER_SBC_PORT=$CUSTOMER_SBC_PORT
ELEVENLABS_SIP_HOST=$ELEVENLABS_SIP_HOST
ELEVENLABS_SIP_PORT=$ELEVENLABS_SIP_PORT
AUTH_USER=$AUTH_USER
AUTH_PASSWORD=$AUTH_PASSWORD
AUTH_REALM=$EXTERNAL_IP
EOF

echo ">>> Building and starting Docker Compose stack..."
ssh "${SSH_OPTS[@]}" "$SSH_TARGET" \
    "cd $REMOTE_DIR/docker && sudo docker compose --env-file .env build && sudo docker compose --env-file .env up -d"

echo ""
echo "=== Deployment complete ==="
echo ""
echo "SIP Gateway running at $EXTERNAL_IP"
echo ""
echo "ElevenLabs outbound trunk config:"
echo "  address:   $EXTERNAL_IP"
echo "  transport: TCP"
[ -n "$AUTH_USER" ] && echo "  authUsername: $AUTH_USER"
[ -n "$AUTH_PASSWORD" ] && echo "  authPassword: ****"
echo ""
echo "Useful commands:"
echo "  SSH:    ssh -i $KEY_FILE $SSH_TARGET"
echo "  Status: ssh -i $KEY_FILE $SSH_TARGET 'sudo docker compose -f $REMOTE_DIR/docker/docker-compose.yml ps'"
echo "  Logs:   ssh -i $KEY_FILE $SSH_TARGET 'sudo docker compose -f $REMOTE_DIR/docker/docker-compose.yml logs -f'"
echo "  Stop:   ssh -i $KEY_FILE $SSH_TARGET 'cd $REMOTE_DIR/docker && sudo docker compose --env-file .env down'"
echo "  Start:  ssh -i $KEY_FILE $SSH_TARGET 'cd $REMOTE_DIR/docker && sudo docker compose --env-file .env up -d'"
