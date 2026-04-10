# ElevenLabs SIP Gateway — AWS Deployment

Deploy a regional SIP gateway on **AWS EC2** to bridge ElevenLabs Conversational AI
with your SBC. The gateway provides a **static IP** (Elastic IP), **in-region presence**,
and **media anchoring** — all SIP signaling and RTP audio flow through it.

```
┌──────────────┐     SIP (TCP 5060)    ┌──────────────────┐     SIP + RTP         ┌──────────────┐
│              │  ───────────────────► │                  │  ───────────────────► │              │
│  ElevenLabs  │                       │   EC2 Instance   │                       │  Your SBC    │
│  SIP Server  │  ◄─────────────────── │   Elastic IP     │  ◄─────────────────── │              │
│              │     SIP + RTP         │  (Kamailio +     │     SIP + RTP         │              │
│              │                       │   RTPEngine)     │                       │              │
└──────────────┘                       └──────────────────┘                       └──────────────┘
```

---

## Prerequisites

| Requirement | Details |
|-------------|---------|
| **AWS CLI** | Configured and authenticated (`aws sts get-caller-identity`) |
| **Terraform** | >= 1.5 |
| **EC2 Key Pair** | Create one in the AWS Console → EC2 → Key Pairs. Download the `.pem` file. |

> **VPC/Subnet**: If you don't specify one, Terraform uses your account's **default VPC** automatically. No extra setup needed.

---

## Step 1 — Provision Infrastructure

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` — only two values are required:

```hcl
region   = "ap-south-1"       # pick your region
key_name = "my-key-pair"      # your EC2 key pair name
```

That's it. VPC, subnet, security group, and Elastic IP are all handled automatically.

Then run:

```bash
terraform init
terraform plan
terraform apply
```

**Created resources:**
- EC2 instance (Ubuntu 24.04 LTS) with Docker pre-installed via startup script
- **Elastic IP** (static — this is the IP you whitelist on your SBC)
- Security group: SIP (TCP/UDP 5060), RTP (UDP 10000–20000), SSH (22)

**Save the output** `sip_gateway_elastic_ip` — you'll need it for ElevenLabs trunk config and SBC whitelisting.

---

## Step 2 — Deploy the SIP Gateway

```bash
cd scripts
./deploy.sh \
    --customer-sbc <YOUR_SBC_IP_OR_FQDN> \
    --key ~/.ssh/your-key.pem \
    --region ap-south-1
```

This will:
1. SSH into the EC2 instance
2. Copy the Docker stack (Kamailio + RTPEngine)
3. Write the `.env` configuration
4. Build and start the containers

The deploy script will:
1. Find the EC2 instance by its Name tag
2. Wait for Docker to finish installing (if the instance just launched)
3. Copy the Docker stack via SCP
4. Write the `.env` config
5. Build and start Kamailio + RTPEngine

### All options

```bash
./deploy.sh \
    --customer-sbc sbc.example.com \
    --customer-sbc-port 5060 \
    --auth-user elevenlabs \
    --auth-password 'YourPassword' \
    --region ap-south-1 \
    --instance-name sip-gateway \
    --key ~/.ssh/my-key.pem
```

| Option | Default | Description |
|--------|---------|-------------|
| `--customer-sbc` | *(required)* | Your SBC IP or FQDN |
| `--key` | *(required)* | Path to SSH `.pem` key file |
| `--customer-sbc-port` | `5060` | SBC SIP port |
| `--auth-user` | *(empty)* | Digest auth username (optional) |
| `--auth-password` | *(empty)* | Digest auth password (optional) |
| `--region` | `ap-south-1` | AWS region |
| `--instance-id` | *(auto)* | EC2 instance ID (auto-detected from Name tag) |
| `--instance-name` | `sip-gateway` | Name tag for auto-detection |
| `--ssh-user` | `ubuntu` | SSH username |

---

## Step 3 — Configure ElevenLabs

In the ElevenLabs dashboard (or API), set the **outbound trunk**:

| Field | Value |
|-------|-------|
| **Address** | `<elastic-ip>` (from Terraform output) |
| **Transport** | TCP |
| **Auth username** | *(if you set `--auth-user`)* |
| **Auth password** | *(if you set `--auth-password`)* |

---

## Step 4 — Smoke Test

```bash
./scripts/test-sip.sh <elastic-ip>
```

A `200 OK` response means the SIP signaling layer is healthy.

---

## Operations

### SSH into the instance

```bash
ssh -i ~/.ssh/your-key.pem ubuntu@<elastic-ip>
```

### View logs

```bash
ssh -i ~/.ssh/your-key.pem ubuntu@<elastic-ip> \
    'sudo docker compose -f /opt/sip-gateway/docker/docker-compose.yml logs -f'
```

### Check container status

```bash
ssh -i ~/.ssh/your-key.pem ubuntu@<elastic-ip> \
    'sudo docker compose -f /opt/sip-gateway/docker/docker-compose.yml ps'
```

### Restart the stack

```bash
ssh -i ~/.ssh/your-key.pem ubuntu@<elastic-ip> \
    'sudo docker compose -f /opt/sip-gateway/docker/docker-compose.yml restart'
```

### Stop the gateway

```bash
ssh -i ~/.ssh/your-key.pem ubuntu@<elastic-ip> \
    'cd /opt/sip-gateway/docker && sudo docker compose --env-file .env down'
```

### Start the gateway

```bash
ssh -i ~/.ssh/your-key.pem ubuntu@<elastic-ip> \
    'cd /opt/sip-gateway/docker && sudo docker compose --env-file .env up -d'
```

### Update SBC address (without redeploying)

```bash
ssh -i ~/.ssh/your-key.pem ubuntu@<elastic-ip> \
    "sudo sed -i 's/^CUSTOMER_SBC_ADDRESS=.*/CUSTOMER_SBC_ADDRESS=new-sbc.example.com/' \
    /opt/sip-gateway/docker/.env && \
    cd /opt/sip-gateway/docker && sudo docker compose --env-file .env up -d"
```

### Check RTPEngine sessions

```bash
ssh -i ~/.ssh/your-key.pem ubuntu@<elastic-ip> \
    'sudo docker exec sip-gateway-rtpengine rtpengine-ctl list sessions'
```

---

## How It Works

1. **ElevenLabs sends INVITE** → to `<elastic-ip>:5060` (TCP)
2. **Kamailio rewrites R-URI** → `sip:<number>@<your-sbc>:5060`
3. **RTPEngine rewrites SDP** → media IP becomes the Elastic IP
4. **Kamailio forwards INVITE** → to your SBC
5. **Your SBC responds** → 100 Trying → 180 Ringing → 200 OK
6. **RTP audio flows** → ElevenLabs ↔ EC2 (RTPEngine) ↔ Your SBC
7. **BYE** → either side hangs up, Kamailio relays, RTPEngine cleans up

For **inbound** calls (your SBC → ElevenLabs): the gateway detects the source IP matches
`CUSTOMER_SBC_ADDRESS` and routes the INVITE to `sip-static.rtc.elevenlabs.io` over TCP.

---

## Recommended AWS Regions

| Use Case | Region | Location |
|----------|--------|----------|
| India | `ap-south-1` | Mumbai |
| India (DR) | `ap-south-2` | Hyderabad |
| Southeast Asia | `ap-southeast-1` | Singapore |
| Malaysia | `ap-southeast-1` | Singapore (nearest) |
| US East | `us-east-1` | N. Virginia |
| US West | `us-west-2` | Oregon |
| Europe | `eu-west-1` | Ireland |
| Middle East | `me-south-1` | Bahrain |

---

## Requirements

| Resource | Minimum |
|----------|---------|
| **OS** | Ubuntu 24.04 LTS (auto-selected by Terraform) |
| **Instance type** | `t3.medium` (2 vCPU, 4 GB) |
| **Disk** | 20 GB gp3 |
| **Ports inbound** | TCP 5060, UDP 5060, UDP 10000–20000 |
| **IP** | Elastic IP (created automatically) |

For high call volume (500+ concurrent), use `c5.large` or `c5.xlarge`.

---

## File Structure

```
amazon/
├── docker/
│   ├── docker-compose.yml          # Kamailio + RTPEngine stack
│   ├── .env.example                # Environment template (reference only)
│   ├── kamailio/
│   │   ├── Dockerfile              # Kamailio 5.8 image
│   │   ├── kamailio.cfg            # SIP routing configuration
│   │   └── entrypoint.sh           # Env var → config substitution
│   └── rtpengine/
│       └── Dockerfile              # RTPEngine media relay image
├── terraform/
│   ├── main.tf                     # EC2, Elastic IP, security group
│   ├── variables.tf                # Configurable parameters
│   ├── outputs.tf                  # Elastic IP, instance ID, SIP URI
│   └── terraform.tfvars.example    # Example configuration
├── scripts/
│   ├── deploy.sh                   # Deploy stack to EC2 via SSH
│   ├── startup.sh                  # EC2 user-data (Docker install)
│   └── test-sip.sh                 # SIP OPTIONS smoke test
└── README.md                       # This file
```

---

## Troubleshooting

| Symptom | Check |
|---------|-------|
| `deploy.sh` says "Waiting for Docker install..." for a long time | Instance just launched — user_data is installing Docker. Wait up to 3 min. SSH in and check `/var/log/sip-gateway-startup.log` |
| `deploy.sh` says "Could not find running instance" | Terraform didn't run yet, or instance is in a different region. Check `--region` matches `terraform.tfvars` |
| `408 Request Timeout` on INVITE | SBC not reachable from EC2 — check SBC firewall allows traffic from the Elastic IP |
| `500 Server Internal Error` | SBC rejected the INVITE — check number format, SBC logs |
| No SIP response at all | Security group issue? Test: `nc -vz <elastic-ip> 5060` from outside |
| RTP one-way audio | Security group must allow UDP 10000–20000 inbound from `0.0.0.0/0` (Terraform does this) |
| Docker not starting | SSH in: `sudo docker compose -f /opt/sip-gateway/docker/docker-compose.yml logs` |
| Elastic IP not attached | Check: `aws ec2 describe-addresses --region <region>` and verify association |

---

## Support

For questions about this gateway, contact your ElevenLabs technical account manager.

For ElevenLabs SIP trunk configuration, see the
[ElevenLabs SIP Trunking documentation](https://elevenlabs.io/docs/conversational-ai/phone-numbers/sip-trunking).
