#!/usr/bin/env bash
# Plan A – Launch a GPU spot instance for running local LLMs
# Usage: ./launch.sh [instance-type]
# Default: g5.xlarge (A10G 24GB VRAM)
# Budget option: g4dn.xlarge (T4 16GB VRAM)

set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
INSTANCE_TYPE="${1:-g5.xlarge}"
KEY_NAME="${KEY_NAME:-llm-gpu-key}"
VOLUME_SIZE="${VOLUME_SIZE:-100}"
PROJECT_TAG="etl-local-llm"
STATE_FILE="${HOME}/.llm-gpu-state"

echo "==========================================="
echo " Plan A – GPU Dev Machine for Local LLMs"
echo "==========================================="
echo " Region:        $REGION"
echo " Instance type: $INSTANCE_TYPE"
echo " Key name:      $KEY_NAME"
echo " Disk:          ${VOLUME_SIZE} GB gp3"
echo "==========================================="
echo ""

# ── Key Pair ──────────────────────────────────────────────────────────────────
echo "==> [1/6] Setting up key pair..."
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
echo "==> [2/6] Creating security group..."
SG_ID=$(aws ec2 create-security-group \
    --region "$REGION" \
    --group-name "llm-gpu-sg-$(date +%s)" \
    --description "LLM GPU Dev Machine SG" \
    --query 'GroupId' --output text)

MY_IP=$(curl -s https://checkip.amazonaws.com)
aws ec2 authorize-security-group-ingress \
    --region "$REGION" \
    --group-id "$SG_ID" \
    --protocol tcp --port 22 \
    --cidr "${MY_IP}/32"
echo "    Security Group: $SG_ID  (SSH allowed from ${MY_IP})"

# ── AMI ────────────────────────────────────────────────────────────────────────
echo "==> [3/6] Finding Deep Learning AMI..."
AMI_ID=$(aws ec2 describe-images \
    --region "$REGION" \
    --owners amazon \
    --filters \
        "Name=name,Values=Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04)*" \
        "Name=state,Values=available" \
        "Name=architecture,Values=x86_64" \
    --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
    --output text 2>/dev/null || true)

# Fallback to standard Ubuntu if Deep Learning AMI not found
if [ -z "$AMI_ID" ] || [ "$AMI_ID" = "None" ]; then
    echo "    Deep Learning AMI not found, using Ubuntu 22.04..."
    AMI_ID=$(aws ec2 describe-images \
        --region "$REGION" \
        --owners 099720109477 \
        --filters \
            "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
            "Name=state,Values=available" \
        --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
        --output text)
fi
echo "    AMI: $AMI_ID"

# ── Elastic IP ────────────────────────────────────────────────────────────────
echo "==> [4/6] Allocating Elastic IP..."
ALLOC_ID=$(aws ec2 allocate-address \
    --domain vpc \
    --region "$REGION" \
    --query 'AllocationId' --output text)
ELASTIC_IP=$(aws ec2 describe-addresses \
    --allocation-ids "$ALLOC_ID" \
    --region "$REGION" \
    --query 'Addresses[0].PublicIp' --output text)
echo "    Elastic IP: $ELASTIC_IP"

# ── Launch Spot Instance ───────────────────────────────────────────────────────
echo "==> [5/6] Launching spot instance ($INSTANCE_TYPE)..."
INSTANCE_ID=$(aws ec2 run-instances \
    --region "$REGION" \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SG_ID" \
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
        {Key=Name,Value=llm-gpu-dev},
        {Key=Project,Value=${PROJECT_TAG}},
        {Key=Plan,Value=A}
    ]" \
    --query 'Instances[0].InstanceId' \
    --output text)

echo "    Instance: $INSTANCE_ID"
echo "    Waiting for instance to be running..."
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
echo " Instance Ready!"
echo "==========================================="
echo " Instance ID:  $INSTANCE_ID"
echo " Elastic IP:   $ELASTIC_IP"
echo " Instance type: $INSTANCE_TYPE"
echo ""
echo " Connect:  ssh -i ~/.ssh/${KEY_NAME}.pem ubuntu@${ELASTIC_IP}"
echo " Setup:    ./setup.sh"
echo " Teardown: ./teardown.sh"
echo " State:    $STATE_FILE"
echo "==========================================="
