#!/usr/bin/env bash
# Plan B – Set up development environment on the CPU dev machine
# Run once after launch.sh succeeds
# Usage: ./setup.sh

set -euo pipefail

STATE_FILE="${HOME}/.devmachine-state"
if [ ! -f "$STATE_FILE" ]; then
    echo "Error: State file not found. Run launch.sh first."
    exit 1
fi
source "$STATE_FILE"

SSH_CMD="ssh -i ~/.ssh/${KEY_NAME}.pem -o StrictHostKeyChecking=no ubuntu@${ELASTIC_IP}"

echo "==========================================="
echo " Plan B – Setup Dev Environment"
echo "==========================================="
echo " Instance: $INSTANCE_ID"
echo " IP:       $ELASTIC_IP"
echo "==========================================="

# Wait for SSH
echo "==> Waiting for SSH..."
RETRIES=0
until $SSH_CMD "echo OK" 2>/dev/null; do
    RETRIES=$((RETRIES + 1))
    if [ "$RETRIES" -gt 30 ]; then echo "SSH timeout"; exit 1; fi
    sleep 5
done

echo "==> Installing system packages..."
$SSH_CMD << 'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq && sudo apt-get upgrade -y -qq
sudo apt-get install -y -qq \
    git curl wget unzip tmux htop neovim vim \
    build-essential python3-pip python3-venv python3-dev \
    docker.io docker-compose-v2 \
    jq awscli shellcheck
sudo usermod -aG docker ubuntu
echo "System packages installed."
REMOTE

echo "==> Installing Node.js 20 LTS..."
$SSH_CMD << 'REMOTE'
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - >/dev/null
sudo apt-get install -y -qq nodejs
node --version
npm --version
REMOTE

echo "==> Installing GitHub CLI..."
$SSH_CMD << 'REMOTE'
(type -p wget >/dev/null || sudo apt-get install wget -y)
sudo mkdir -p -m 755 /etc/apt/keyrings
wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null
sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
sudo apt-get update -qq && sudo apt-get install -y gh
echo "GitHub CLI $(gh --version | head -1)"
REMOTE

echo "==> Installing OpenCode AI agent..."
$SSH_CMD << 'REMOTE'
npm install -g opencode-ai 2>/dev/null || echo "OpenCode install skipped (may need manual auth)"
echo "OpenCode: $(opencode --version 2>/dev/null || echo 'installed, auth needed')"
REMOTE

echo "==> Setting up Python dev tools..."
$SSH_CMD << 'REMOTE'
pip3 install --quiet --upgrade pip
pip3 install --quiet poetry black ruff mypy pytest ipython
echo "Python tools installed."
REMOTE

echo "==> Configuring tmux..."
$SSH_CMD << 'REMOTE'
cat > ~/.tmux.conf << 'TMUXCONF'
set -g mouse on
set -g history-limit 10000
set -g default-terminal "screen-256color"
bind | split-window -h
bind - split-window -v
set -g status-right "%H:%M %d-%b"
TMUXCONF
tmux new-session -d -s dev 2>/dev/null || true
echo "tmux configured."
REMOTE

echo "==> Adding SSH config on local machine..."
SSH_CONFIG="${HOME}/.ssh/config"
if ! grep -q "Host devmachine-b" "$SSH_CONFIG" 2>/dev/null; then
    cat >> "$SSH_CONFIG" << EOF

Host devmachine-b
    HostName ${ELASTIC_IP}
    User ubuntu
    IdentityFile ~/.ssh/${KEY_NAME}.pem
    ServerAliveInterval 60
    ServerAliveCountMax 3
    ForwardAgent yes
EOF
    echo "    Added 'devmachine-b' to ~/.ssh/config"
fi

echo "==> Setting up auto-shutdown on idle..."
$SSH_CMD << 'REMOTE'
sudo tee /usr/local/bin/auto-shutdown.sh > /dev/null << 'SHUTDOWN'
#!/bin/bash
IDLE_THRESHOLD=1800
SESSIONS=$(who | grep -vc "^$" 2>/dev/null || echo 0)
if [ "$SESSIONS" -eq 0 ]; then
    LAST_TS=$(last -n 1 ubuntu 2>/dev/null | head -1 | awk '{print $5" "$6" "$7" "$8}' | xargs -I{} date -d "{}" +%s 2>/dev/null || echo 0)
    NOW=$(date +%s)
    if [ "$LAST_TS" -gt 0 ]; then
        IDLE=$((NOW - LAST_TS))
        if [ "$IDLE" -gt "$IDLE_THRESHOLD" ]; then
            logger "auto-shutdown: idle ${IDLE}s"
            sudo shutdown -h now
        fi
    fi
fi
SHUTDOWN
sudo chmod +x /usr/local/bin/auto-shutdown.sh
(crontab -l 2>/dev/null; echo "*/5 * * * * /usr/local/bin/auto-shutdown.sh") | crontab -
echo "Auto-shutdown configured."
REMOTE

echo ""
echo "==========================================="
echo " Setup Complete!"
echo "==========================================="
echo ""
echo " To connect:     ./connect.sh"
echo " VS Code:        Remote-SSH → devmachine-b"
echo ""
echo " LLM Setup:"
echo "   GitHub Copilot: Install 'GitHub Copilot' extension in VS Code"
echo "   OpenCode:       ssh in and run 'opencode auth login'"
echo "   Copilot CLI:    ssh in and run 'gh extension install github/gh-copilot'"
echo "==========================================="
