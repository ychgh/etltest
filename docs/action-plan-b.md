# Action Plan B – EC2 CPU Dev/Test Machine + Cloud LLM

> **Goal**: A powerful, GPU-free EC2 instance (32–64 GB RAM) used purely as a remote development
> and test machine. All LLM inference is delegated to a cloud subscription
> (OpenCode Zen or GitHub Copilot) — no local model management required.

---

## Overview

| Item | Detail |
|------|--------|
| **Philosophy** | CPU instance = cheap compute. Cloud LLM = cheap intelligence. |
| **Why no GPU?** | The GPU is overkill for a dev machine that just SSHes into it |
| **LLM access** | OpenCode Zen (pay-as-you-go ~$0.01–0.05/req) or GitHub Copilot ($10/mo flat) |
| **Instance size** | 32 GB RAM: `m5.2xlarge` · 64 GB RAM: `r5.2xlarge` or `m5.4xlarge` |
| **Est. cost** | $50–$150/month (On-Demand); lower with Reserved or Spot |

---

## Instance Type Comparison

| Instance | vCPU | RAM | On-Demand/hr | Spot/hr | Monthly Spot (720 hrs) | Best for |
|----------|------|-----|-------------|---------|------------------------|----------|
| `m5.2xlarge` | 8 | 32 GB | $0.384 | $0.082 | ~$59 | Balanced dev |
| `m5.4xlarge` | 16 | 64 GB | $0.768 | $0.163 | ~$117 | Heavy multi-service dev |
| `c5.4xlarge` | 16 | 32 GB | $0.680 | $0.116 | ~$83 | CPU-intensive builds |
| `r5.2xlarge` | 8 | 64 GB | $0.504 | $0.149 | ~$107 | Memory-heavy workloads |
| `r5.xlarge` | 4 | 32 GB | $0.252 | $0.075 | ~$54 | Lighter dev, budget-friendly |

> **Recommendation**: Start with `m5.2xlarge` (32 GB) for most developers. Upgrade to `r5.2xlarge` (64 GB) if you run Docker Compose stacks with multiple services simultaneously.

---

## LLM Subscription Comparison

| Plan | Cost | Model Access | Best For |
|------|------|-------------|----------|
| **OpenCode Zen** | Pay-as-you-go ~$0.01–0.05/request | Curated top models | Flexible, privacy-focused developers |
| **OpenCode GO** | $10/month | GLM-5, Kimi K2.5, MiniMax M2.5 | Cost-predictable with heavy usage |
| **GitHub Copilot Free** | $0 | Limited (2,000 completions/mo, 50 premium req) | Occasional use |
| **GitHub Copilot Pro** | $10/month | Claude 3.7, Gemini 2.5 Pro, GPT-4.1 | Regular development |
| **GitHub Copilot Pro+** | $39/month | All models, 1,500 premium req/mo | Power users |

---

## Phase 1 – Launch the Instance

### 1.1 Prerequisites

```bash
# Install AWS CLI v2
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip awscliv2.zip && sudo ./aws/install
aws configure
```

### 1.2 Set Variables

```bash
# Adjust these to your preferences
REGION="us-east-1"
INSTANCE_TYPE="m5.2xlarge"   # 32 GB RAM; use r5.2xlarge for 64 GB
KEY_NAME="devmachine-key"
PROJECT_TAG="etl-devtest"
VOLUME_SIZE=50               # GB
```

### 1.3 Create Key Pair and Security Group

```bash
# Key pair
aws ec2 create-key-pair \
    --region "$REGION" \
    --key-name "$KEY_NAME" \
    --query 'KeyMaterial' \
    --output text > ~/.ssh/${KEY_NAME}.pem
chmod 400 ~/.ssh/${KEY_NAME}.pem

# Security group – SSH only from your IP
SG_ID=$(aws ec2 create-security-group \
    --region "$REGION" \
    --group-name "devmachine-sg-$(date +%s)" \
    --description "Dev Machine SG" \
    --query 'GroupId' --output text)

MY_IP=$(curl -s https://checkip.amazonaws.com)
aws ec2 authorize-security-group-ingress \
    --region "$REGION" \
    --group-id "$SG_ID" \
    --protocol tcp --port 22 \
    --cidr "${MY_IP}/32"

echo "SG: $SG_ID"
```

### 1.4 Find Latest Ubuntu 22.04 LTS AMI

```bash
AMI_ID=$(aws ec2 describe-images \
    --region "$REGION" \
    --owners 099720109477 \
    --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
              "Name=state,Values=available" \
    --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
    --output text)

echo "AMI: $AMI_ID"
```

### 1.5 Launch the Instance

```bash
INSTANCE_ID=$(aws ec2 run-instances \
    --region "$REGION" \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SG_ID" \
    --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":${VOLUME_SIZE},\"VolumeType\":\"gp3\"}}]" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=dev-machine},{Key=Project,Value=${PROJECT_TAG}}]" \
    --query 'Instances[0].InstanceId' \
    --output text)

echo "Instance: $INSTANCE_ID"
aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"

PUBLIC_IP=$(aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)

echo "Public IP: $PUBLIC_IP"
echo "SSH: ssh -i ~/.ssh/${KEY_NAME}.pem ubuntu@${PUBLIC_IP}"
```

> For **On-Demand pricing**: `m5.2xlarge` = ~$0.384/hr → ~$55/mo at 4 hrs/day × 22 days.  
> For **Spot pricing**: same instance = ~$0.082/hr → ~$7.20/mo at same usage.

---

## Phase 2 – Set Up Your Development Environment

```bash
# Connect
ssh -i ~/.ssh/${KEY_NAME}.pem ubuntu@${PUBLIC_IP}
```

### 2.1 System Updates and Essentials

```bash
sudo apt-get update && sudo apt-get upgrade -y
sudo apt-get install -y \
    git curl wget unzip tmux htop \
    build-essential pkg-config \
    python3-pip python3-venv python3-dev \
    docker.io docker-compose-v2 \
    awscli jq

# Add ubuntu to docker group
sudo usermod -aG docker ubuntu
newgrp docker
```

### 2.2 Install Node.js 20 LTS

```bash
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt-get install -y nodejs
node --version && npm --version
```

### 2.3 Set Up GitHub Copilot CLI (Option A)

```bash
# Install GitHub CLI
(type -p wget >/dev/null || sudo apt-get install wget -y) && \
sudo mkdir -p -m 755 /etc/apt/keyrings && \
wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null && \
sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg && \
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null && \
sudo apt-get update && sudo apt-get install gh -y

# Authenticate
gh auth login    # follow prompts; select GitHub.com + SSH

# Install Copilot extension
gh extension install github/gh-copilot
```

### 2.4 Set Up OpenCode (Option B)

```bash
# Install OpenCode (open-source AI coding agent)
npm install -g opencode-ai

# Configure with your subscription key
opencode auth login
# Or set env var:
export OPENCODE_API_KEY="your-key-here"

# Add to ~/.bashrc for persistence
echo 'export OPENCODE_API_KEY="your-key-here"' >> ~/.bashrc
```

### 2.5 Configure VS Code Remote Development

On your **local machine**:

1. Install the **Remote - SSH** extension in VS Code
2. Add to `~/.ssh/config`:

```
Host devmachine
    HostName <PUBLIC_IP>
    User ubuntu
    IdentityFile ~/.ssh/devmachine-key.pem
    ServerAliveInterval 60
    ServerAliveCountMax 3
```

3. Connect: `Ctrl+Shift+P` → "Remote-SSH: Connect to Host" → `devmachine`

### 2.6 Install GitHub Copilot VS Code Extension (Remote)

Once connected via Remote-SSH, install **GitHub Copilot** and **GitHub Copilot Chat** extensions on the remote machine through VS Code's extension marketplace.

### 2.7 Set Up a Persistent tmux Session

```bash
# Create a named session that survives SSH disconnects
tmux new-session -d -s dev -x 220 -y 50

# Attach
tmux attach -t dev
```

---

## Phase 3 – Connect and Code

### 3.1 Daily Connect Workflow

```bash
# From your local machine
ssh -i ~/.ssh/devmachine-key.pem ubuntu@${PUBLIC_IP}
tmux attach -t dev
# Resume coding exactly where you left off
```

### 3.2 Use GitHub Copilot in the Terminal

```bash
# Explain code
gh copilot explain "git rebase -i HEAD~3"

# Get command suggestions
gh copilot suggest "find all Python files modified in the last week"

# Alias for convenience
echo 'alias cop="gh copilot suggest"' >> ~/.bashrc
```

### 3.3 Use OpenCode Agent

```bash
# Start an interactive coding session
opencode

# Ask it to implement a feature
# > "Add a REST endpoint /health that returns {"status": "ok"}"
# OpenCode will edit files, run tests, and iterate
```

### 3.4 Use Copilot Chat in VS Code

After connecting via Remote-SSH and opening your project:
- `Ctrl+Alt+I` → Open Copilot Chat
- Ask questions, refactor code, generate tests directly in the editor

---

## Phase 4 – Tear Down

### 4.1 Push Your Work

```bash
# On the remote machine
git add . && git commit -m "feat: end of session" && git push origin main
```

### 4.2 Stop the Instance (Preserve Disk)

```bash
# From your local machine
aws ec2 stop-instances \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID"

echo "Instance stopped. EBS disk preserved."
echo "Storage cost: ~\$0.08/GB/mo = \$$(echo "$VOLUME_SIZE * 0.08" | bc)/mo while stopped"
```

### 4.3 Restart When Needed

```bash
aws ec2 start-instances \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID"

aws ec2 wait instance-running \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID"

# Note: public IP changes on restart unless you use an Elastic IP
PUBLIC_IP=$(aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)
echo "New IP: $PUBLIC_IP"
```

### 4.4 Full Teardown (Delete Everything)

```bash
aws ec2 terminate-instances \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID"

aws ec2 delete-security-group \
    --region "$REGION" \
    --group-id "$SG_ID"

aws ec2 delete-key-pair \
    --region "$REGION" \
    --key-name "$KEY_NAME"
```

---

## Monthly Cost Estimate (Plan B)

### 32 GB RAM – `m5.2xlarge`

| Item | Rate | Daily Usage | Monthly (22 days) |
|------|------|-------------|-------------------|
| EC2 On-Demand | $0.384/hr | 4 hrs | $33.80 |
| EC2 Spot | $0.082/hr | 4 hrs | $7.22 |
| EBS gp3 50 GB | $0.08/GB/mo | – | $4.00 |
| Data Transfer | ~$0.09/GB | ~2 GB | $2.00 |
| **GitHub Copilot Pro** | flat | – | **$10.00** |
| **Total (On-Demand + Copilot)** | | | **~$50/month** |
| **Total (Spot + Copilot)** | | | **~$23/month** |

### 64 GB RAM – `r5.2xlarge`

| Item | Rate | Daily Usage | Monthly (22 days) |
|------|------|-------------|-------------------|
| EC2 On-Demand | $0.504/hr | 4 hrs | $44.35 |
| EC2 Spot | $0.149/hr | 4 hrs | $13.11 |
| EBS gp3 50 GB | $0.08/GB/mo | – | $4.00 |
| Data Transfer | ~$0.09/GB | ~2 GB | $2.00 |
| **GitHub Copilot Pro** | flat | – | **$10.00** |
| **Total (On-Demand + Copilot)** | | | **~$60/month** |
| **Total (Spot + Copilot)** | | | **~$29/month** |

> For a cost-optimised approach using Spot instances + auto-shutdown, see **[Action Plan C](action-plan-c.md)**.

---

## Script Reference

| Script | Purpose |
|--------|---------|
| `scripts/plan-b/launch.sh` | Launch On-Demand or Spot instance |
| `scripts/plan-b/setup.sh` | Bootstrap dev environment (run once after launch) |
| `scripts/plan-b/connect.sh` | SSH helper with tmux attach |
| `scripts/plan-b/teardown.sh` | Stop or terminate instance |
