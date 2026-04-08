# Action Plan C – Cost-Optimised Spot Instance + Cloud LLM

> **Goal**: Reduce cloud spend to **$20–$30/month** by combining AWS Spot Instances,
> automated shutdown after idle periods, and a predictable cloud LLM subscription.
> Daily usage assumed at ~4 hours/day.

---

## Overview

| Lever | Technique | Saving |
|-------|-----------|--------|
| **Spot Instance** | Up to 80% off On-Demand pricing | $30–$40/mo saved |
| **Auto-Shutdown** | CloudWatch alarm + EventBridge rule stops instance when idle | 0 cost while stopped |
| **Minimal storage** | 30 GB gp3 EBS (expandable) | ~$1/mo saved vs 100 GB |
| **Flat LLM subscription** | GitHub Copilot Pro ($10/mo) instead of per-request | Predictable cost |

---

## Complete Monthly Budget Breakdown

### Scenario: `m5.xlarge` Spot · 32 GB RAM · 4 hrs/day · 22 working days

| Line Item | Unit Price | Quantity | Monthly Cost |
|-----------|-----------|----------|-------------|
| EC2 `m5.xlarge` Spot | ~$0.041/hr | 88 hrs (22d × 4h) | **$3.61** |
| EBS gp3 30 GB | $0.08/GB/mo | 30 GB | **$2.40** |
| EBS snapshot (weekly) | $0.05/GB/mo | ~5 GB average | **$0.25** |
| Data transfer (egress) | $0.09/GB | ~3 GB | **$0.27** |
| Elastic IP (while stopped) | $0.005/hr | ~632 stopped hrs | **$3.16** |
| CloudWatch alarms (2) | $0.10/alarm/mo | 2 | **$0.20** |
| **Subtotal – Infrastructure** | | | **~$9.89** |
| **GitHub Copilot Pro** | flat $10/mo | 1 | **$10.00** |
| **TOTAL** | | | **≈ $20/month** |

### Scenario: `m5.2xlarge` Spot · 32 GB RAM · 4 hrs/day · 22 working days

| Line Item | Unit Price | Quantity | Monthly Cost |
|-----------|-----------|----------|-------------|
| EC2 `m5.2xlarge` Spot | ~$0.082/hr | 88 hrs | **$7.22** |
| EBS gp3 50 GB | $0.08/GB/mo | 50 GB | **$4.00** |
| EBS snapshot (weekly) | $0.05/GB/mo | ~8 GB average | **$0.40** |
| Data transfer (egress) | $0.09/GB | ~3 GB | **$0.27** |
| Elastic IP (while stopped) | $0.005/hr | ~632 stopped hrs | **$3.16** |
| CloudWatch alarms (2) | $0.10/alarm/mo | 2 | **$0.20** |
| **Subtotal – Infrastructure** | | | **~$15.25** |
| **GitHub Copilot Pro** | flat $10/mo | 1 | **$10.00** |
| **TOTAL** | | | **≈ $25/month** ✅ |

### OpenCode Zen Alternative (Pay-as-you-go)

If you prefer OpenCode over Copilot:

| Usage Profile | Est. Requests/Day | Daily Cost | Monthly (22 days) |
|---------------|------------------|------------|-------------------|
| Light (review only) | 20–40 requests | $0.20–$1.00 | **$4–$22** |
| Moderate (regular coding) | 50–100 requests | $0.50–$2.00 | **$11–$44** |
| Heavy (all-day coding) | 100–200 requests | $1.00–$5.00 | **$22–$110** |

> **Recommendation**: For 4 hrs/day moderate coding → ~$15–$20/mo on OpenCode Zen.
> GitHub Copilot Pro at $10/mo flat is more predictable for regular users.

---

## Phase 1 – Launch the Spot Instance

### 1.1 Create Spot Instance with Persistent EBS

```bash
#!/usr/bin/env bash
# scripts/plan-c/launch-spot.sh

REGION="${AWS_REGION:-us-east-1}"
INSTANCE_TYPE="${INSTANCE_TYPE:-m5.2xlarge}"
KEY_NAME="${KEY_NAME:-devspot-key}"
VOLUME_SIZE="${VOLUME_SIZE:-50}"
PROJECT_TAG="etl-devtest"

set -euo pipefail

echo "==> Creating key pair..."
if ! aws ec2 describe-key-pairs --key-names "$KEY_NAME" --region "$REGION" &>/dev/null; then
    aws ec2 create-key-pair \
        --region "$REGION" \
        --key-name "$KEY_NAME" \
        --query 'KeyMaterial' \
        --output text > ~/.ssh/${KEY_NAME}.pem
    chmod 400 ~/.ssh/${KEY_NAME}.pem
    echo "    Key pair created: ~/.ssh/${KEY_NAME}.pem"
fi

echo "==> Creating security group..."
SG_ID=$(aws ec2 create-security-group \
    --region "$REGION" \
    --group-name "devspot-sg-$$" \
    --description "Dev Spot Machine SG" \
    --query 'GroupId' --output text)

MY_IP=$(curl -s https://checkip.amazonaws.com)
aws ec2 authorize-security-group-ingress \
    --region "$REGION" \
    --group-id "$SG_ID" \
    --protocol tcp --port 22 \
    --cidr "${MY_IP}/32"

echo "==> Finding latest Ubuntu 22.04 AMI..."
AMI_ID=$(aws ec2 describe-images \
    --region "$REGION" \
    --owners 099720109477 \
    --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
              "Name=state,Values=available" \
    --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
    --output text)
echo "    AMI: $AMI_ID"

echo "==> Allocating Elastic IP (retains across stop/start)..."
ALLOC_ID=$(aws ec2 allocate-address --domain vpc --region "$REGION" \
    --query 'AllocationId' --output text)
ELASTIC_IP=$(aws ec2 describe-addresses \
    --allocation-ids "$ALLOC_ID" \
    --region "$REGION" \
    --query 'Addresses[0].PublicIp' --output text)
echo "    Elastic IP: $ELASTIC_IP (AllocationId: $ALLOC_ID)"

echo "==> Launching spot instance ($INSTANCE_TYPE)..."
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
        {Key=Name,Value=dev-spot},
        {Key=Project,Value=${PROJECT_TAG}},
        {Key=AutoShutdown,Value=enabled}
    ]" \
    --query 'Instances[0].InstanceId' \
    --output text)

echo "    Instance: $INSTANCE_ID"
echo "==> Waiting for instance to be running..."
aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"

echo "==> Associating Elastic IP..."
aws ec2 associate-address \
    --region "$REGION" \
    --instance-id "$INSTANCE_ID" \
    --allocation-id "$ALLOC_ID"

# Save state for other scripts
cat > ~/.devspot-state << EOF
INSTANCE_ID=$INSTANCE_ID
SG_ID=$SG_ID
ALLOC_ID=$ALLOC_ID
ELASTIC_IP=$ELASTIC_IP
KEY_NAME=$KEY_NAME
REGION=$REGION
EOF

echo ""
echo "==> Instance ready!"
echo "    SSH: ssh -i ~/.ssh/${KEY_NAME}.pem ubuntu@${ELASTIC_IP}"
echo "    State saved to ~/.devspot-state"
```

---

## Phase 2 – Set Up Your Development Environment

```bash
#!/usr/bin/env bash
# Run once after first launch: scripts/plan-c/setup.sh
source ~/.devspot-state

SSH="ssh -i ~/.ssh/${KEY_NAME}.pem -o StrictHostKeyChecking=no ubuntu@${ELASTIC_IP}"

echo "==> Waiting for SSH to be available..."
until $SSH "echo ready" 2>/dev/null; do sleep 5; done

echo "==> Installing development tools..."
$SSH << 'REMOTE'
set -euo pipefail
sudo apt-get update -qq && sudo apt-get upgrade -y -qq
sudo apt-get install -y -qq \
    git curl wget unzip tmux htop neovim \
    build-essential python3-pip python3-venv \
    docker.io docker-compose-v2 jq awscli

# Node.js 20
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - >/dev/null
sudo apt-get install -y nodejs

# Docker access
sudo usermod -aG docker ubuntu

# GitHub CLI
(type -p wget >/dev/null || sudo apt-get install wget -y)
sudo mkdir -p -m 755 /etc/apt/keyrings
wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null
sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
sudo apt-get update -qq && sudo apt-get install -y gh

echo "==> Installing auto-shutdown script..."
sudo tee /usr/local/bin/auto-shutdown.sh << 'SHUTDOWN_SCRIPT'
#!/bin/bash
# Auto-shutdown if no active SSH sessions for 30 minutes
IDLE_THRESHOLD=1800
SESSIONS=$(who | grep -v "boot" | wc -l)
if [ "$SESSIONS" -eq 0 ]; then
    LAST_ACTIVITY=$(last -n 1 -F | awk '{print $NF" "$9" "$10" "$11" "$12}' | head -1)
    LAST_TS=$(last -n 1 | grep -v "wtmp" | awk '{print $5" "$6" "$7" "$8}' | xargs -I{} date -d {} +%s 2>/dev/null || echo 0)
    NOW=$(date +%s)
    IDLE=$((NOW - LAST_TS))
    if [ "$IDLE" -gt "$IDLE_THRESHOLD" ]; then
        logger "auto-shutdown: idle for ${IDLE}s — stopping instance"
        sudo shutdown -h now
    fi
fi
SHUTDOWN_SCRIPT

sudo chmod +x /usr/local/bin/auto-shutdown.sh
(crontab -l 2>/dev/null; echo "*/5 * * * * /usr/local/bin/auto-shutdown.sh") | crontab -

echo "==> Setup complete!"
REMOTE

echo ""
echo "==> Dev environment ready. Run scripts/plan-c/connect.sh to start coding."
```

### 2.1 Set Up CloudWatch Auto-Stop Alarm (Additional Safety Net)

```bash
#!/usr/bin/env bash
# scripts/plan-c/setup-cloudwatch-alarm.sh
source ~/.devspot-state

echo "==> Creating CloudWatch alarm to stop instance after 30 min of low CPU..."
aws cloudwatch put-metric-alarm \
    --region "$REGION" \
    --alarm-name "dev-spot-idle-stop-${INSTANCE_ID}" \
    --alarm-description "Stop dev spot instance when CPU < 5% for 30 minutes" \
    --metric-name CPUUtilization \
    --namespace AWS/EC2 \
    --statistic Average \
    --dimensions "Name=InstanceId,Value=${INSTANCE_ID}" \
    --period 300 \
    --evaluation-periods 6 \
    --threshold 5 \
    --comparison-operator LessThanThreshold \
    --alarm-actions "arn:aws:automate:${REGION}:ec2:stop" \
    --ok-actions "arn:aws:automate:${REGION}:ec2:stop"

echo "==> Alarm set: instance will stop after 30 min of CPU < 5%"
```

### 2.2 Install GitHub Copilot CLI

```bash
ssh -i ~/.ssh/devspot-key.pem ubuntu@${ELASTIC_IP}
# On the remote machine:
gh auth login   # authenticate with GitHub
gh extension install github/gh-copilot
echo "alias cop='gh copilot suggest'" >> ~/.bashrc
source ~/.bashrc
```

---

## Phase 3 – Connect and Code

### 3.1 Connect Script

```bash
#!/usr/bin/env bash
# scripts/plan-c/connect.sh
source ~/.devspot-state

# Start instance if stopped
STATUS=$(aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].State.Name' \
    --output text)

if [ "$STATUS" = "stopped" ]; then
    echo "==> Starting stopped instance..."
    aws ec2 start-instances --region "$REGION" --instance-ids "$INSTANCE_ID"
    aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"
    echo "==> Instance started. Waiting 20s for SSH..."
    sleep 20
fi

echo "==> Connecting to $ELASTIC_IP..."
ssh -i ~/.ssh/${KEY_NAME}.pem \
    -o StrictHostKeyChecking=no \
    -o ServerAliveInterval=60 \
    -o ServerAliveCountMax=3 \
    ubuntu@${ELASTIC_IP} \
    -t "tmux new-session -A -s dev"
```

### 3.2 Daily Coding Workflow

```bash
# 1. Start your session
./scripts/plan-c/connect.sh

# 2. In the remote tmux session, use Copilot in the terminal
gh copilot suggest "write a GitHub Actions workflow for Python tests"
gh copilot explain "awk '{print $1}' file.txt"

# 3. Use VS Code with Remote-SSH + Copilot extension for GUI editing
# 4. When done, just close the terminal — auto-shutdown handles the rest
```

### 3.3 VS Code SSH Config

```
# ~/.ssh/config (on your local machine)
Host devspot
    HostName <ELASTIC_IP>
    User ubuntu
    IdentityFile ~/.ssh/devspot-key.pem
    ServerAliveInterval 60
    ServerAliveCountMax 3
    ForwardAgent yes
```

---

## Phase 4 – Tear Down

### 4.1 Daily Stop (Keep Data)

```bash
#!/usr/bin/env bash
# scripts/plan-c/stop.sh
source ~/.devspot-state

echo "==> Pushing any uncommitted work..."
ssh -i ~/.ssh/${KEY_NAME}.pem ubuntu@${ELASTIC_IP} \
    "cd ~/current-project 2>/dev/null && git add -A && git commit -m 'WIP: session end' && git push || true"

echo "==> Stopping instance $INSTANCE_ID..."
aws ec2 stop-instances --region "$REGION" --instance-ids "$INSTANCE_ID"
echo "    Instance stopping. Elastic IP $ELASTIC_IP retained."
echo "    EBS disk preserved. Storage cost: ~\$4/mo for 50 GB."
```

### 4.2 Full Teardown (Delete Everything)

```bash
#!/usr/bin/env bash
# scripts/plan-c/teardown.sh
source ~/.devspot-state

echo "==> Terminating instance..."
aws ec2 terminate-instances --region "$REGION" --instance-ids "$INSTANCE_ID"
aws ec2 wait instance-terminated --region "$REGION" --instance-ids "$INSTANCE_ID"

echo "==> Releasing Elastic IP..."
aws ec2 release-address --region "$REGION" --allocation-id "$ALLOC_ID"

echo "==> Deleting security group..."
aws ec2 delete-security-group --region "$REGION" --group-id "$SG_ID"

echo "==> Deleting CloudWatch alarm..."
aws cloudwatch delete-alarms \
    --region "$REGION" \
    --alarm-names "dev-spot-idle-stop-${INSTANCE_ID}"

echo "==> Teardown complete. All resources deleted."
rm -f ~/.devspot-state
```

---

## Cost Optimisation Checklist

- [x] Use **Spot Instance** (up to 80% cheaper than On-Demand)
- [x] Use **`persistent` Spot** type — instance stops (not terminates) on interruption, EBS preserved
- [x] Attach an **Elastic IP** — stable address even after stop/start ($0.005/hr while stopped)
- [x] **Auto-shutdown on idle** — CloudWatch CPU alarm + in-instance cron script
- [x] **Minimal EBS** — start with 30–50 GB, expand only if needed
- [x] **Flat-rate LLM subscription** — GitHub Copilot $10/mo, unlimited completions
- [x] **Region selection** — `us-east-1` or `us-west-2` tend to have lowest spot prices
- [x] **Instance family spread** — specify multiple instance types in Spot Fleet for better availability

---

## Advanced: Spot Fleet for Higher Availability

```bash
# Use a Spot Fleet across multiple instance types to reduce interruption risk
aws ec2 request-spot-fleet --spot-fleet-request-config '{
  "IamFleetRole": "arn:aws:iam::<ACCOUNT_ID>:role/AmazonEC2SpotFleetRole",
  "SpotPrice": "0.15",
  "TargetCapacity": 1,
  "LaunchSpecifications": [
    {"InstanceType": "m5.2xlarge", "ImageId": "<AMI_ID>", "KeyName": "<KEY>"},
    {"InstanceType": "m5a.2xlarge", "ImageId": "<AMI_ID>", "KeyName": "<KEY>"},
    {"InstanceType": "m4.2xlarge", "ImageId": "<AMI_ID>", "KeyName": "<KEY>"},
    {"InstanceType": "r5.xlarge", "ImageId": "<AMI_ID>", "KeyName": "<KEY>"}
  ],
  "AllocationStrategy": "lowestPrice",
  "Type": "maintain"
}'
```

---

## Script Reference

| Script | Purpose |
|--------|---------|
| `scripts/plan-c/launch-spot.sh` | Launch persistent spot instance with Elastic IP |
| `scripts/plan-c/setup.sh` | Bootstrap dev environment + auto-shutdown |
| `scripts/plan-c/setup-cloudwatch-alarm.sh` | CloudWatch idle-stop alarm |
| `scripts/plan-c/connect.sh` | Start/resume instance + SSH into tmux session |
| `scripts/plan-c/stop.sh` | Save work + stop instance |
| `scripts/plan-c/teardown.sh` | Full deletion of all resources |

---

## Related Plans

- [Action Plan A – GPU Cloud Dev Machine for Local LLMs](action-plan-a.md)
- [Action Plan B – CPU Dev Machine + Cloud LLM](action-plan-b.md)
- [Best Local LLM Guide](best-local-llm-guide.md)
