#!/usr/bin/env bash
# Plan A – Connect to GPU dev machine with Ollama port forwarding
# Usage: ./connect.sh [--tunnel-only]

set -euo pipefail

STATE_FILE="${HOME}/.llm-gpu-state"
if [ ! -f "$STATE_FILE" ]; then
    echo "Error: State file not found. Run launch.sh first."
    exit 1
fi
source "$STATE_FILE"

TUNNEL_ONLY="${1:-}"

# Start instance if stopped
STATUS=$(aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].State.Name' \
    --output text)

if [ "$STATUS" = "stopped" ]; then
    echo "==> Instance is stopped. Starting..."
    aws ec2 start-instances --region "$REGION" --instance-ids "$INSTANCE_ID"
    aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"
    echo "==> Waiting 20 seconds for SSH daemon..."
    sleep 20
fi

if [ "$TUNNEL_ONLY" = "--tunnel-only" ]; then
    echo "==> Starting SSH tunnel (Ollama port 11434)..."
    echo "    Local:  http://localhost:11434"
    echo "    Press Ctrl+C to stop."
    ssh -i "${HOME}/.ssh/${KEY_NAME}.pem" \
        -L 11434:localhost:11434 \
        -o StrictHostKeyChecking=no \
        -o ServerAliveInterval=60 \
        -N \
        ubuntu@"${ELASTIC_IP}"
else
    echo "==> Connecting to $ELASTIC_IP (tmux session: dev)..."
    echo "    Ollama port 11434 forwarded to localhost."
    ssh -i "${HOME}/.ssh/${KEY_NAME}.pem" \
        -L 11434:localhost:11434 \
        -o StrictHostKeyChecking=no \
        -o ServerAliveInterval=60 \
        -o ServerAliveCountMax=3 \
        ubuntu@"${ELASTIC_IP}" \
        -t "tmux new-session -A -s dev"
fi
