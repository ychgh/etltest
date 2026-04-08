#!/usr/bin/env bash
# Plan C – Stop the spot instance at end of coding session
# EBS data is preserved. Elastic IP is retained (small charge while stopped).
# Usage: ./stop.sh [--push-git]

set -euo pipefail

STATE_FILE="${HOME}/.devspot-state"
if [ ! -f "$STATE_FILE" ]; then
    echo "Error: State file not found."
    exit 1
fi
source "$STATE_FILE"

PUSH_GIT="${1:-}"

STATUS=$(aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].State.Name' \
    --output text)

if [ "$STATUS" = "running" ] && [ "$PUSH_GIT" = "--push-git" ]; then
    echo "==> Pushing uncommitted work..."
    ssh -i "${HOME}/.ssh/${KEY_NAME}.pem" \
        -o StrictHostKeyChecking=no ubuntu@"${ELASTIC_IP}" \
        'find ~/projects -name ".git" -maxdepth 2 2>/dev/null | while read d; do
            cd "$(dirname "$d")"
            if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
                git add -A && git commit -m "WIP: auto-save $(date)" && git push 2>/dev/null || true
                echo "Pushed: $(pwd)"
            fi
        done' 2>/dev/null || echo "    (git push skipped — no projects found)"
fi

if [ "$STATUS" = "running" ]; then
    echo "==> Stopping instance $INSTANCE_ID..."
    aws ec2 stop-instances --region "$REGION" --instance-ids "$INSTANCE_ID" >/dev/null
    echo "    Instance stopping."
    echo "    EBS disk preserved. Data safe."
    echo "    Elastic IP ${ELASTIC_IP} retained (cost: ~\$0.12/day while stopped)."
    echo "    To resume: ./connect.sh"
else
    echo "    Instance is already in state: $STATUS"
fi
