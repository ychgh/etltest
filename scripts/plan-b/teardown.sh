#!/usr/bin/env bash
# Plan B – Stop or delete the dev machine
# Usage: ./teardown.sh [--stop | --terminate]

set -euo pipefail

STATE_FILE="${HOME}/.devmachine-state"
if [ ! -f "$STATE_FILE" ]; then
    echo "Error: State file not found at $STATE_FILE"
    exit 1
fi
source "$STATE_FILE"

ACTION="${1:---stop}"

echo "==========================================="
echo " Plan B – Tear Down"
echo "==========================================="
echo " Instance: $INSTANCE_ID"
echo " Action:   $ACTION"
echo "==========================================="

if [ "$ACTION" = "--terminate" ]; then
    echo ""
    echo "WARNING: This will PERMANENTLY DELETE the instance and all resources."
    read -r -p "Type 'yes' to confirm: " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then echo "Aborted."; exit 0; fi

    echo "==> Terminating $INSTANCE_ID..."
    aws ec2 terminate-instances --region "$REGION" --instance-ids "$INSTANCE_ID"
    aws ec2 wait instance-terminated --region "$REGION" --instance-ids "$INSTANCE_ID"

    echo "==> Releasing Elastic IP..."
    aws ec2 release-address --region "$REGION" --allocation-id "$ALLOC_ID"

    echo "==> Deleting security group..."
    sleep 5
    aws ec2 delete-security-group --region "$REGION" --group-id "$SG_ID" 2>/dev/null || \
        echo "    Skipped (may have remaining dependencies)"

    rm -f "$STATE_FILE"
    echo "==> All resources deleted."
else
    STATUS=$(aws ec2 describe-instances \
        --region "$REGION" \
        --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].State.Name' \
        --output text)

    if [ "$STATUS" = "running" ]; then
        echo "==> Stopping instance..."
        aws ec2 stop-instances --region "$REGION" --instance-ids "$INSTANCE_ID"
        echo "    Instance stopping. EBS preserved."
        echo "    To restart: ./connect.sh"
    else
        echo "    Instance already in state: $STATUS"
    fi
fi
