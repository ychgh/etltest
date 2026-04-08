#!/usr/bin/env bash
# Plan C – Launch a cost-optimised persistent Spot instance
# Target: ~$20-30/month for 4 hrs/day usage
# Usage: ./launch-spot.sh [instance-type]
# Default: m5.2xlarge (32 GB RAM, ~$0.082/hr spot)
# Budget:  m5.xlarge  (16 GB RAM, ~$0.041/hr spot)

set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
INSTANCE_TYPE="${1:-m5.2xlarge}"
KEY_NAME="${KEY_NAME:-devspot-key}"
VOLUME_SIZE="${VOLUME_SIZE:-50}"
PROJECT_TAG="etl-devtest"
STATE_FILE="${HOME}/.devspot-state"

echo "==========================================="
echo " Plan C – Cost-Optimised Spot Dev Machine"
echo "==========================================="
echo " Region:        $REGION"
echo " Instance type: $INSTANCE_TYPE"
echo " Disk:          ${VOLUME_SIZE} GB gp3"
echo " Target cost:   ~\$20-30/month (4 hrs/day)"
echo "==========================================="
echo ""

# ── Key Pair ──────────────────────────────────────────────────────────────────
echo "==> [1/6] Key pair..."
if ! aws ec2 describe-key-pairs --key-names "$KEY_NAME" --region "$REGION" &>/dev/null; then
    aws ec2 create-key-pair \
        --region "$REGION" \
        --key-name "$KEY_NAME" \
        --query 'KeyMaterial' \
        --output text > "${HOME}/.ssh/${KEY_NAME}.pem"
    chmod 400 "${HOME}/.ssh/${KEY_NAME}.pem"
    echo "    Created: ~/.ssh/${KEY_NAME}.pem"
else
    echo "    '$KEY_NAME' already exists."
fi

# ── Security Group ─────────────────────────────────────────────────────────────
echo "==> [2/6] Security group..."
SG_ID=$(aws ec2 create-security-group \
    --region "$REGION" \
    --group-name "devspot-sg-$(date +%s)" \
    --description "Dev Spot SG (Plan C)" \
    --query 'GroupId' --output text)
MY_IP=$(curl -s https://checkip.amazonaws.com)
aws ec2 authorize-security-group-ingress \
    --region "$REGION" \
    --group-id "$SG_ID" \
    --protocol tcp --port 22 \
    --cidr "${MY_IP}/32"
echo "    SG: $SG_ID  (SSH from ${MY_IP})"

# ── AMI ────────────────────────────────────────────────────────────────────────
echo "==> [3/6] Finding Ubuntu 22.04 AMI..."
AMI_ID=$(aws ec2 describe-images \
    --region "$REGION" \
    --owners 099720109477 \
    --filters \
        "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
        "Name=state,Values=available" \
    --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
    --output text)
echo "    AMI: $AMI_ID"

# ── Elastic IP ────────────────────────────────────────────────────────────────
echo "==> [4/6] Allocating Elastic IP (stable across stop/start)..."
ALLOC_ID=$(aws ec2 allocate-address \
    --domain vpc \
    --region "$REGION" \
    --query 'AllocationId' --output text)
ELASTIC_IP=$(aws ec2 describe-addresses \
    --allocation-ids "$ALLOC_ID" \
    --region "$REGION" \
    --query 'Addresses[0].PublicIp' --output text)
echo "    Elastic IP: $ELASTIC_IP"

# ── User Data (Bootstrap Script) ───────────────────────────────────────────────
USER_DATA=$(base64 -w0 << 'USERDATA'
#!/bin/bash
# Minimal bootstrap: essential tools only for cost efficiency
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get upgrade -y -qq
apt-get install -y -qq git curl wget tmux htop jq build-essential python3-pip python3-venv docker.io

# Node.js 20
curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/dev/null
apt-get install -y nodejs
usermod -aG docker ubuntu

# Auto-shutdown on idle (30 minutes)
cat > /usr/local/bin/auto-shutdown.sh << 'SHUTDOWN'
#!/bin/bash
IDLE_THRESHOLD=1800
SESSIONS=$(who | grep -vc "^$" 2>/dev/null || echo 0)
if [ "$SESSIONS" -eq 0 ]; then
    NOW=$(date +%s)
    LAST_TS=$(last -n 1 ubuntu 2>/dev/null | head -1 | awk '{print $5" "$6" "$7" "$8}' | xargs -I{} date -d "{}" +%s 2>/dev/null || echo $((NOW - 100)))
    IDLE=$((NOW - LAST_TS))
    if [ "$IDLE" -gt "$IDLE_THRESHOLD" ]; then
        logger "auto-shutdown: idle ${IDLE}s"
        shutdown -h now
    fi
fi
SHUTDOWN
chmod +x /usr/local/bin/auto-shutdown.sh
(crontab -l 2>/dev/null; echo "*/5 * * * * /usr/local/bin/auto-shutdown.sh") | crontab -
USERDATA
)

# ── Launch Persistent Spot Instance ───────────────────────────────────────────
echo "==> [5/6] Launching persistent spot instance..."
INSTANCE_ID=$(aws ec2 run-instances \
    --region "$REGION" \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SG_ID" \
    --user-data "$USER_DATA" \
    --instance-market-options '{
        "MarketType":"spot",
        "SpotOptions":{
            "SpotInstanceType":"persistent",
            "InstanceInterruptionBehavior":"stop"
        }
    }' \
    --block-device-mappings "[{
        \"DeviceName\":\"/dev/sda1\",
        \"Ebs\":{
            \"VolumeSize\":${VOLUME_SIZE},
            \"VolumeType\":\"gp3\",
            \"DeleteOnTermination\":false
        }
    }]" \
    --tag-specifications "ResourceType=instance,Tags=[
        {Key=Name,Value=dev-spot-c},
        {Key=Project,Value=${PROJECT_TAG}},
        {Key=Plan,Value=C},
        {Key=AutoShutdown,Value=enabled}
    ]" \
    --query 'Instances[0].InstanceId' \
    --output text)

echo "    Instance: $INSTANCE_ID"
echo "    Waiting for running state..."
aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"

# ── Associate Elastic IP ──────────────────────────────────────────────────────
echo "==> [6/6] Associating Elastic IP..."
aws ec2 associate-address \
    --region "$REGION" \
    --instance-id "$INSTANCE_ID" \
    --allocation-id "$ALLOC_ID" >/dev/null

# ── Save State ─────────────────────────────────────────────────────────────────
cat > "$STATE_FILE" << EOF
INSTANCE_ID=$INSTANCE_ID
SG_ID=$SG_ID
ALLOC_ID=$ALLOC_ID
ELASTIC_IP=$ELASTIC_IP
KEY_NAME=$KEY_NAME
REGION=$REGION
INSTANCE_TYPE=$INSTANCE_TYPE
EOF

echo ""
echo "==========================================="
echo " Spot Instance Ready!"
echo "==========================================="
echo " Instance:    $INSTANCE_ID"
echo " Elastic IP:  $ELASTIC_IP"
echo " Type:        $INSTANCE_TYPE (persistent spot)"
echo ""
echo " Bootstrap running in background (~3-5 min)."
echo " Next steps:"
echo "   1. ./setup-cloudwatch-alarm.sh  (auto-stop on idle CPU)"
echo "   2. ./connect.sh                 (SSH in + tmux)"
echo "   3. ./stop.sh                    (end of day)"
echo "   4. ./teardown.sh                (permanent delete)"
echo ""
echo " Monthly estimate (~4 hrs/day × 22 days):"
HOURLY=$(aws ec2 describe-spot-price-history \
    --region "$REGION" \
    --instance-types "$INSTANCE_TYPE" \
    --product-descriptions "Linux/UNIX" \
    --max-items 1 \
    --query 'SpotPriceHistory[0].SpotPrice' \
    --output text 2>/dev/null || echo "N/A")
echo "   Spot price: \$$HOURLY/hr"
if [ "$HOURLY" != "N/A" ]; then
    MONTHLY=$(echo "scale=2; $HOURLY * 88" | bc 2>/dev/null || echo "~\$7-15")
    echo "   Est. compute: \$$MONTHLY/month"
fi
echo "   + EBS 50 GB:  ~\$4/month"
echo "   + Elastic IP: ~\$3/month (while stopped)"
echo "   + Copilot Pro: \$10/month"
echo "   ─────────────────────────────"
echo "   TOTAL:         ~\$20-30/month"
echo "==========================================="
