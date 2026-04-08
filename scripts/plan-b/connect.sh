#!/usr/bin/env bash
# Plan B – Connect (SSH) to the dev machine
# Usage: ./connect.sh

set -euo pipefail

STATE_FILE="${HOME}/.devmachine-state"
if [ ! -f "$STATE_FILE" ]; then
    echo "Error: State file not found. Run launch.sh first."
    exit 1
fi
source "$STATE_FILE"

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
    echo "==> Waiting 20 seconds for SSH..."
    sleep 20
elif [ "$STATUS" = "stopping" ]; then
    echo "==> Instance is stopping. Waiting..."
    aws ec2 wait instance-stopped --region "$REGION" --instance-ids "$INSTANCE_ID"
    aws ec2 start-instances --region "$REGION" --instance-ids "$INSTANCE_ID"
    aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"
    sleep 20
fi

echo "==> Connecting to $ELASTIC_IP..."
ssh -i "${HOME}/.ssh/${KEY_NAME}.pem" \
    -o StrictHostKeyChecking=no \
    -o ServerAliveInterval=60 \
    -o ServerAliveCountMax=3 \
    ubuntu@"${ELASTIC_IP}" \
    -t "tmux new-session -A -s dev"
