#!/usr/bin/env bash
# Plan A – Set up Ollama + local LLM on the GPU dev machine
# Run this after launch.sh succeeds
# Usage: ./setup.sh [model-name]
# Default model: qwen2.5-coder:14b

set -euo pipefail

STATE_FILE="${HOME}/.llm-gpu-state"
if [ ! -f "$STATE_FILE" ]; then
    echo "Error: State file not found. Run launch.sh first."
    exit 1
fi
source "$STATE_FILE"

MODEL="${1:-qwen2.5-coder:14b}"
SSH_CMD="ssh -i ~/.ssh/${KEY_NAME}.pem -o StrictHostKeyChecking=no ubuntu@${ELASTIC_IP}"

echo "==========================================="
echo " Plan A – Setup GPU Dev Environment"
echo "==========================================="
echo " Instance: $INSTANCE_ID"
echo " IP:       $ELASTIC_IP"
echo " Model:    $MODEL"
echo "==========================================="

echo "==> Waiting for SSH to be available..."
RETRIES=0
until $SSH_CMD "echo OK" 2>/dev/null; do
    RETRIES=$((RETRIES + 1))
    if [ "$RETRIES" -gt 30 ]; then
        echo "Error: SSH not available after 150 seconds."
        exit 1
    fi
    echo "    Waiting... (${RETRIES}/30)"
    sleep 5
done

echo "==> Installing system packages and tools..."
$SSH_CMD << 'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq
sudo apt-get upgrade -y -qq
sudo apt-get install -y -qq \
    git curl wget unzip tmux htop nvtop \
    build-essential python3-pip python3-venv \
    docker.io docker-compose-v2 jq

# Node.js 20
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - >/dev/null
sudo apt-get install -y nodejs

# Docker access
sudo usermod -aG docker ubuntu
echo "System packages installed."
REMOTE

echo "==> Installing NVIDIA drivers (if not pre-installed)..."
$SSH_CMD << 'REMOTE'
if ! command -v nvidia-smi &>/dev/null; then
    echo "Installing NVIDIA drivers..."
    sudo apt-get install -y ubuntu-drivers-common
    sudo ubuntu-drivers autoinstall
    echo "NVIDIA drivers installed. Reboot may be needed."
else
    echo "NVIDIA drivers already present:"
    nvidia-smi --query-gpu=name,memory.total --format=csv,noheader
fi
REMOTE

echo "==> Installing Ollama..."
$SSH_CMD << 'REMOTE'
if ! command -v ollama &>/dev/null; then
    curl -fsSL https://ollama.ai/install.sh | sh
    sudo systemctl enable ollama
    sudo systemctl start ollama
    echo "Ollama installed and started."
else
    echo "Ollama already installed: $(ollama --version 2>/dev/null || echo 'unknown version')"
    sudo systemctl start ollama || true
fi
# Verify Ollama is running
sleep 3
curl -s http://localhost:11434/api/tags >/dev/null && echo "Ollama API is responsive."
REMOTE

echo "==> Pulling model: $MODEL..."
$SSH_CMD "ollama pull $MODEL"
echo "    Model '$MODEL' ready."

echo "==> Testing model inference..."
RESULT=$($SSH_CMD "ollama run $MODEL 'Write a one-line Python hello world' --nowordwrap 2>/dev/null | head -5" || echo "(test skipped)")
echo "    Test result: $RESULT"

echo "==> Setting up auto-shutdown..."
$SSH_CMD << 'REMOTE'
sudo tee /usr/local/bin/auto-shutdown.sh > /dev/null << 'SHUTDOWN'
#!/bin/bash
# Auto-shutdown if no SSH sessions for 30 minutes
IDLE_THRESHOLD=1800
SESSIONS=$(who | grep -vc "^$" 2>/dev/null || echo 0)
if [ "$SESSIONS" -eq 0 ]; then
    LAST_TS=$(last -n 1 ubuntu 2>/dev/null | head -1 | awk '{print $5" "$6" "$7" "$8}' | xargs -I{} date -d "{}" +%s 2>/dev/null || echo 0)
    NOW=$(date +%s)
    if [ "$LAST_TS" -gt 0 ]; then
        IDLE=$((NOW - LAST_TS))
        if [ "$IDLE" -gt "$IDLE_THRESHOLD" ]; then
            logger "auto-shutdown: idle ${IDLE}s — halting"
            sudo shutdown -h now
        fi
    fi
fi
SHUTDOWN
sudo chmod +x /usr/local/bin/auto-shutdown.sh
(crontab -l 2>/dev/null; echo "*/5 * * * * /usr/local/bin/auto-shutdown.sh") | crontab -
echo "Auto-shutdown configured (30 min idle threshold)."
REMOTE

echo "==> Setting up tmux default session..."
$SSH_CMD "tmux new-session -d -s dev 2>/dev/null || true"

echo ""
echo "==========================================="
echo " Setup Complete!"
echo "==========================================="
echo ""
echo " Model '$MODEL' is ready on the GPU instance."
echo ""
echo " Connect:     ssh -i ~/.ssh/${KEY_NAME}.pem ubuntu@${ELASTIC_IP}"
echo " Resume tmux: tmux attach -t dev"
echo ""
echo " Ollama API (via SSH tunnel):"
echo "   ssh -L 11434:localhost:11434 -i ~/.ssh/${KEY_NAME}.pem ubuntu@${ELASTIC_IP} -N"
echo ""
echo " Continue.dev config (apiBase):"
echo '   "apiBase": "http://localhost:11434"'
echo "==========================================="
