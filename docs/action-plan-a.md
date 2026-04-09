# Action Plan A – Cloud GPU Dev Machine for Local LLMs

> **Goal**: Build a dedicated cloud development machine with a GPU so you can run a local LLM
> (Qwen2.5-Coder, DeepSeek Coder, CodeLlama, etc.) entirely within your own cloud environment —
> no cloud LLM subscription fees, full privacy, no rate limits.

---

## Overview

| Item | Detail |
|------|--------|
| **Target instance** | AWS `g5.xlarge` (A10G 24 GB VRAM) or `g4dn.xlarge` (T4 16 GB) |
| **Spot discount** | 50–70% off On-Demand |
| **Recommended model** | Qwen2.5-Coder 14B (fits in 16 GB VRAM) |
| **Estimated cost** | $0.30–$0.60/hr spot × 4 hrs/day × 22 days ≈ **$26–$52/month** |
| **LLM cost** | $0 (running locally) |

---

## Phase 1 – Launch the Spot Instance

### 1.1 Prerequisites

```bash
# Install AWS CLI v2
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip awscliv2.zip && sudo ./aws/install

# Configure credentials
aws configure
# AWS Access Key ID: <your-key>
# AWS Secret Access Key: <your-secret>
# Default region name: us-east-1
# Default output format: json
```

### 1.2 Create a Key Pair

```bash
KEY_NAME="llm-dev-key"
aws ec2 create-key-pair \
    --key-name "$KEY_NAME" \
    --query 'KeyMaterial' \
    --output text > ~/.ssh/${KEY_NAME}.pem
chmod 400 ~/.ssh/${KEY_NAME}.pem
```

### 1.3 Create a Security Group

```bash
SG_ID=$(aws ec2 create-security-group \
    --group-name "llm-dev-sg" \
    --description "LLM Dev Machine Security Group" \
    --query 'GroupId' --output text)

# Allow SSH from your IP only
MY_IP=$(curl -s https://checkip.amazonaws.com)
aws ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" \
    --protocol tcp --port 22 \
    --cidr "${MY_IP}/32"

echo "Security Group: $SG_ID"
```

### 1.4 Launch the Spot Instance

```bash
# Choose AMI: Deep Learning AMI GPU PyTorch (Amazon Linux 2)
# Find latest AMI ID:
AMI_ID=$(aws ec2 describe-images \
    --owners amazon \
    --filters "Name=name,Values=Deep Learning AMI GPU PyTorch*" \
              "Name=architecture,Values=x86_64" \
    --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
    --output text)

echo "Using AMI: $AMI_ID"

# Launch spot instance
INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type g5.xlarge \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SG_ID" \
    --instance-market-options '{"MarketType":"spot","SpotOptions":{"SpotInstanceType":"one-time","InstanceInterruptionBehavior":"terminate"}}' \
    --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":100,"VolumeType":"gp3"}}]' \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=llm-dev-gpu},{Key=Project,Value=etldev}]' \
    --query 'Instances[0].InstanceId' \
    --output text)

echo "Instance ID: $INSTANCE_ID"

# Wait until running
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"

# Get public IP
PUBLIC_IP=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)

echo "Public IP: $PUBLIC_IP"
echo "Connect: ssh -i ~/.ssh/${KEY_NAME}.pem ec2-user@${PUBLIC_IP}"
```

> **Note**: The `g5.xlarge` spot price in `us-east-1` is typically **$0.35–$0.45/hr**.
> Use `g4dn.xlarge` (~$0.16–$0.20/hr spot) for a cheaper option with the T4 GPU (16 GB VRAM).

---

## Phase 2 – Set Up Your Development Environment

```bash
# Connect to the instance
ssh -i ~/.ssh/llm-dev-key.pem ec2-user@${PUBLIC_IP}
```

### 2.1 Install Ollama

```bash
curl -fsSL https://ollama.ai/install.sh | sh
sudo systemctl enable ollama
sudo systemctl start ollama

# Verify GPU is visible
nvidia-smi
```

### 2.2 Pull Your Model

```bash
# Option 1: Qwen2.5-Coder 14B – best accuracy for 16 GB VRAM
ollama pull qwen2.5-coder:14b

# Option 2: Qwen2.5-Coder 7B – fastest, fits T4 easily
ollama pull qwen2.5-coder:7b

# Option 3: DeepSeek Coder V2 16B – best for multi-language repos
ollama pull deepseek-coder-v2:16b

# Option 4: Codestral 22B – great FIM for autocomplete
ollama pull codestral:22b
```

### 2.3 Test the Model

```bash
ollama run qwen2.5-coder:14b "Write a Python function to find the longest palindrome in a string"
```

### 2.4 Install Development Tools

```bash
# Node.js (for TypeScript/JS projects)
curl -fsSL https://rpm.nodesource.com/setup_20.x | sudo bash -
sudo yum install -y nodejs

# Python tools
pip install --upgrade pip poetry black ruff mypy

# Git config
git config --global user.name "Your Name"
git config --global user.email "you@example.com"

# tmux for persistent sessions
sudo yum install -y tmux
```

### 2.5 Configure Continue.dev (VS Code Extension)

On your **local machine**, install the [Continue.dev](https://continue.dev) VS Code extension, then add to `~/.continue/config.json`:

```json
{
  "models": [
    {
      "title": "Qwen2.5-Coder 14B (GPU Cloud)",
      "provider": "ollama",
      "model": "qwen2.5-coder:14b",
      "apiBase": "http://<EC2-PUBLIC-IP>:11434",
      "contextLength": 32768
    }
  ],
  "tabAutocompleteModel": {
    "title": "Qwen2.5-Coder 7B FIM",
    "provider": "ollama",
    "model": "qwen2.5-coder:7b",
    "apiBase": "http://<EC2-PUBLIC-IP>:11434"
  }
}
```

> **Security note**: Expose Ollama port only via SSH tunnel in production:
> ```bash
> ssh -L 11434:localhost:11434 -i ~/.ssh/llm-dev-key.pem ec2-user@${PUBLIC_IP} -N
> ```
> Then use `http://localhost:11434` in your Continue config.

### 2.6 Set Up Auto-Shutdown (Cost Protection)

```bash
# Install a cron job to shut down the instance if idle for 30 minutes
cat << 'EOF' | sudo tee /usr/local/bin/auto-shutdown.sh
#!/bin/bash
# Auto-shutdown if no SSH sessions active for 30 minutes
IDLE_THRESHOLD=1800  # seconds
LAST_SSH=$(who | wc -l)
if [ "$LAST_SSH" -eq 0 ]; then
    LAST_ACTIVITY=$(stat -c %Y /var/run/utmp 2>/dev/null || echo 0)
    NOW=$(date +%s)
    IDLE=$((NOW - LAST_ACTIVITY))
    if [ "$IDLE" -gt "$IDLE_THRESHOLD" ]; then
        logger "Auto-shutdown: idle for ${IDLE}s"
        sudo shutdown -h now
    fi
fi
EOF
sudo chmod +x /usr/local/bin/auto-shutdown.sh

# Run every 5 minutes
(crontab -l 2>/dev/null; echo "*/5 * * * * /usr/local/bin/auto-shutdown.sh") | crontab -
```

---

## Phase 3 – Connect and Code

### 3.1 SSH Tunnel + Port Forwarding

```bash
# Forward Ollama (11434) and optional Jupyter (8888)
ssh -i ~/.ssh/llm-dev-key.pem \
    -L 11434:localhost:11434 \
    -L 8888:localhost:8888 \
    ec2-user@${PUBLIC_IP}
```

### 3.2 VS Code Remote SSH

Install the **Remote - SSH** extension in VS Code, then:

1. Press `Ctrl+Shift+P` → "Remote-SSH: Connect to Host"
2. Add host: `ec2-user@<PUBLIC_IP>`
3. Select identity file: `~/.ssh/llm-dev-key.pem`
4. Open your project folder on the remote machine

### 3.3 Verify Model is Serving

```bash
# On your local machine (after SSH tunnel)
curl http://localhost:11434/api/generate \
  -d '{"model":"qwen2.5-coder:14b","prompt":"print hello world in Python","stream":false}' \
  | jq .response
```

---

## Phase 4 – Tear Down

### 4.1 Save Your Work First

```bash
# On the remote machine: push any uncommitted work
git add . && git commit -m "WIP: save before shutdown" && git push
```

### 4.2 Stop or Terminate the Instance

```bash
# STOP (preserves EBS disk – you pay for storage ~$0.08/GB/month)
aws ec2 stop-instances --instance-ids "$INSTANCE_ID"

# TERMINATE (deletes everything – no further charges)
aws ec2 terminate-instances --instance-ids "$INSTANCE_ID"
```

### 4.3 Clean Up Security Group (Optional)

```bash
aws ec2 delete-security-group --group-id "$SG_ID"
```

---

## Cost Summary (Plan A)

| Item | Unit Cost | Daily (4 hrs) | Monthly (22 days) |
|------|-----------|---------------|-------------------|
| g5.xlarge spot | ~$0.40/hr | $1.60 | **$35** |
| g4dn.xlarge spot | ~$0.18/hr | $0.72 | **$16** |
| EBS gp3 100 GB | $0.08/GB/mo | – | **$8** |
| Data transfer | ~$0.09/GB | minimal | **~$2** |
| LLM inference | $0 (local) | $0 | **$0** |
| **Total (g5.xlarge)** | | | **~$45/month** |
| **Total (g4dn.xlarge)** | | | **~$26/month** |

> For full guidance on model selection, see the [Best Local LLM Guide](best-local-llm-guide.md).

---

## Script Reference

| Script | Purpose |
|--------|---------|
| `scripts/plan-a/launch.sh` | Launch spot GPU instance |
| `scripts/plan-a/setup.sh` | Install Ollama + model on remote |
| `scripts/plan-a/connect.sh` | SSH tunnel helper |
| `scripts/plan-a/teardown.sh` | Stop or terminate instance |
