#!/bin/bash
# EC2 user-data startup script — runs on first boot (Ubuntu 24.04 LTS).
# Installs Docker, detects IPs via IMDS v2, and prepares for deployment.
set -euo pipefail

LOG_FILE="/var/log/sip-gateway-startup.log"
INSTALL_DIR="/opt/sip-gateway"

exec > >(tee -a "$LOG_FILE") 2>&1
echo "=== SIP Gateway startup $(date) ==="

# Install Docker if not present
if ! command -v docker &> /dev/null; then
    echo "Installing Docker..."
    apt-get update -y
    apt-get install -y ca-certificates curl
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable docker
    systemctl start docker
    echo "Docker installed: $(docker --version)"
fi

# Detect IPs from EC2 Instance Metadata Service (IMDS v2)
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 300")

EXTERNAL_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/public-ipv4 || echo "")

INTERNAL_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/local-ipv4)

echo "Detected external IP: $EXTERNAL_IP"
echo "Detected internal IP: $INTERNAL_IP"

mkdir -p "$INSTALL_DIR/docker"

ENV_FILE="$INSTALL_DIR/docker/.env"
if [ ! -f "$ENV_FILE" ]; then
    cat > "$ENV_FILE" <<EOF
EXTERNAL_IP=$EXTERNAL_IP
INTERNAL_IP=$INTERNAL_IP
CUSTOMER_SBC_ADDRESS=REPLACE_ME_WITH_SBC_IP
CUSTOMER_SBC_PORT=5060
ELEVENLABS_SIP_HOST=sip-static.rtc.elevenlabs.io
ELEVENLABS_SIP_PORT=5060
AUTH_USER=
AUTH_PASSWORD=
AUTH_REALM=
EOF
    echo "Created .env template at $ENV_FILE — set CUSTOMER_SBC_ADDRESS to your telephony provider's SBC IP"
fi

sed -i "s/^EXTERNAL_IP=.*/EXTERNAL_IP=$EXTERNAL_IP/" "$ENV_FILE"
sed -i "s/^INTERNAL_IP=.*/INTERNAL_IP=$INTERNAL_IP/" "$ENV_FILE"

echo "=== Startup complete ==="
echo "Deploy the docker-compose stack to $INSTALL_DIR using scripts/deploy.sh"
