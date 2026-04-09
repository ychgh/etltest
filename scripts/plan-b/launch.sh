#!/usr/bin/env bash
# Plan B – Launch a CPU-only EC2 dev/test machine + use cloud LLM (Copilot/OpenCode)
# Usage: ./launch.sh [--spot] [instance-type]
# Default: On-Demand m5.2xlarge (32 GB RAM)
# Examples:
#   ./launch.sh                        # On-Demand m5.2xlarge
#   ./launch.sh --spot                 # Spot m5.2xlarge
#   ./launch.sh --spot r5.2xlarge      # Spot r5.2xlarge (64 GB RAM)

set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
KEY_NAME="${KEY_NAME:-devmachine-key}"
VOLUME_SIZE="${VOLUME_SIZE:-50}"
PROJECT_TAG="etl-devtest"
STATE_FILE="${HOME}/.devmachine-state"

# Parse arguments
USE_SPOT=false
INSTANCE_TYPE="m5.2xlarge"
for arg in "$@"; do
    case "$arg" in
        --spot) USE_SPOT=true ;;
        *) INSTANCE_TYPE="$arg" ;;
    esac
done

echo "==========================================="
echo " Plan B – CPU Dev Machine + Cloud LLM"
echo "==========================================="
echo " Region:        $REGION"
echo " Instance type: $INSTANCE_TYPE"
echo " Spot:          $USE_SPOT"
echo " Disk:          ${VOLUME_SIZE} GB gp3"
echo "==========================================="
echo ""

# ── Key Pair ──────────────────────────────────────────────────────────────────
echo "==> [1/5] Setting up key pair..."
if ! aws ec2 describe-key-pairs --key-names "$KEY_NAME" --region "$REGION" &>/dev/null; then
    aws ec2 create-key-pair \
        --region "$REGION" \
        --key-name "$KEY_NAME" \
        --query 'KeyMaterial' \
        --output text > "${HOME}/.ssh/${KEY_NAME}.pem"
    chmod 400 "${HOME}/.ssh/${KEY_NAME}.pem"
    echo "    Created: ~/.ssh/${KEY_NAME}.pem"
else
    echo "    Key pair '$KEY_NAME' already exists."
fi

# ── Security Group ─────────────────────────────────────────────────────────────
echo "==> [2/5] Creating security group..."
SG_ID=$(aws ec2 create-security-group \
    --region "$REGION" \
    --group-name "devmachine-sg-$(date +%s)" \
    --description "Dev Machine SG (Plan B)" \
    --query 'GroupId' --output text)

MY_IP=$(curl -s https://checkip.amazonaws.com)
aws ec2 authorize-security-group-ingress \
    --region "$REGION" \
    --group-id "$SG_ID" \
    --protocol tcp --port 22 \
    --cidr "${MY_IP}/32"
echo "    Security Group: $SG_ID  (SSH from ${MY_IP})"

# ── AMI ────────────────────────────────────────────────────────────────────────
echo "==> [3/5] Finding latest Ubuntu 22.04 AMI..."
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
echo "==> [4/5] Allocating Elastic IP..."
ALLOC_ID=$(aws ec2 allocate-address \
    --domain vpc \
    --region "$REGION" \
    --query 'AllocationId' --output text)
ELASTIC_IP=$(aws ec2 describe-addresses \
    --allocation-ids "$ALLOC_ID" \
    --region "$REGION" \
    --query 'Addresses[0].PublicIp' --output text)
echo "    Elastic IP: $ELASTIC_IP"

# ── Launch Instance ───────────────────────────────────────────────────────────
echo "==> [5/5] Launching instance ($INSTANCE_TYPE, spot=$USE_SPOT)..."

MARKET_OPTIONS=""
if [ "$USE_SPOT" = true ]; then
    MARKET_OPTIONS='--instance-market-options {"MarketType":"spot","SpotOptions":{"SpotInstanceType":"persistent","InstanceInterruptionBehavior":"stop"}}'
fi

INSTANCE_ID=$(aws ec2 run-instances \
    --region "$REGION" \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SG_ID" \
    ${USE_SPOT:+--instance-market-options '{"MarketType":"spot","SpotOptions":{"SpotInstanceType":"persistent","InstanceInterruptionBehavior":"stop"}}'} \
    --block-device-mappings "[{
        \"DeviceName\":\"/dev/sda1\",
        \"Ebs\":{
            \"VolumeSize\":${VOLUME_SIZE},
            \"VolumeType\":\"gp3\",
            \"DeleteOnTermination\":false
        }
    }]" \
    --tag-specifications "ResourceType=instance,Tags=[
        {Key=Name,Value=dev-machine-b},
        {Key=Project,Value=${PROJECT_TAG}},
        {Key=Plan,Value=B}
    ]" \
    --query 'Instances[0].InstanceId' \
    --output text)

echo "    Instance: $INSTANCE_ID"
echo "    Waiting for instance to be running..."
aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"

echo "    Associating Elastic IP..."
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
USE_SPOT=$USE_SPOT
EOF

echo ""
echo "==========================================="
echo " Instance Ready!"
echo "==========================================="
echo " Instance ID:  $INSTANCE_ID"
echo " Elastic IP:   $ELASTIC_IP"
echo " Type:         $INSTANCE_TYPE (spot=$USE_SPOT)"
echo ""
echo " Next steps:"
echo "   1. Run setup.sh to install dev tools"
echo "   2. Run connect.sh to SSH in"
echo "   3. Run teardown.sh to stop/delete"
echo ""
echo " SSH: ssh -i ~/.ssh/${KEY_NAME}.pem ubuntu@${ELASTIC_IP}"
echo "==========================================="
