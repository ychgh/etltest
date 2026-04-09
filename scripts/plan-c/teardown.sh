#!/usr/bin/env bash
# Plan C – Full teardown: delete all resources
# WARNING: This permanently deletes the instance and releases the Elastic IP.
# Usage: ./teardown.sh [--force]

set -euo pipefail

STATE_FILE="${HOME}/.devspot-state"
if [ ! -f "$STATE_FILE" ]; then
    echo "Error: State file not found at $STATE_FILE"
    exit 1
fi
source "$STATE_FILE"

FORCE="${1:-}"

echo "==========================================="
echo " Plan C – Full Teardown"
echo "==========================================="
echo " Instance:   $INSTANCE_ID"
echo " Elastic IP: $ELASTIC_IP"
echo " SG:         $SG_ID"
echo "==========================================="

if [ "$FORCE" != "--force" ]; then
    echo ""
    echo "WARNING: This will PERMANENTLY DELETE all resources for Plan C."
    echo "         Make sure you have pushed all work to git first."
    read -r -p "Type 'yes' to confirm permanent deletion: " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        echo "Aborted."
        exit 0
    fi
fi

echo ""
echo "==> [1/4] Terminating instance $INSTANCE_ID..."
aws ec2 terminate-instances \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" >/dev/null
aws ec2 wait instance-terminated \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID"
echo "    Instance terminated."

echo "==> [2/4] Releasing Elastic IP ($ALLOC_ID)..."
aws ec2 release-address \
    --region "$REGION" \
    --allocation-id "$ALLOC_ID"
echo "    Elastic IP released."

echo "==> [3/4] Deleting security group ($SG_ID)..."
sleep 5  # allow network interfaces to detach
aws ec2 delete-security-group \
    --region "$REGION" \
    --group-id "$SG_ID" 2>/dev/null || \
    echo "    Note: SG deletion skipped (check console for remaining dependencies)"

echo "==> [4/4] Removing CloudWatch alarm..."
aws cloudwatch delete-alarms \
    --region "$REGION" \
    --alarm-names "dev-spot-idle-stop-${INSTANCE_ID}" 2>/dev/null || true

rm -f "$STATE_FILE"

echo ""
echo "==========================================="
echo " Teardown Complete"
echo "==========================================="
echo " All Plan C resources deleted."
echo " No further AWS charges for this environment."
echo "==========================================="
