#!/usr/bin/env bash
# Plan A – Tear down GPU dev machine
# Usage: ./teardown.sh [--stop | --terminate]
#   --stop       : Stop instance, preserve EBS disk (default)
#   --terminate  : Permanently delete instance and all resources

set -euo pipefail

STATE_FILE="${HOME}/.llm-gpu-state"
if [ ! -f "$STATE_FILE" ]; then
    echo "Error: State file not found at $STATE_FILE"
    exit 1
fi
source "$STATE_FILE"

ACTION="${1:---stop}"

echo "==========================================="
echo " Plan A – Tear Down"
echo "==========================================="
echo " Instance: $INSTANCE_ID"
echo " Action:   $ACTION"
echo "==========================================="

if [ "$ACTION" = "--terminate" ]; then
    echo ""
    echo "WARNING: This will PERMANENTLY DELETE the instance and all associated resources."
    echo "         EBS volumes marked DeleteOnTermination=false will be preserved."
    read -r -p "Type 'yes' to confirm: " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        echo "Aborted."
        exit 0
    fi

    echo "==> Terminating instance $INSTANCE_ID..."
    aws ec2 terminate-instances --region "$REGION" --instance-ids "$INSTANCE_ID"
    aws ec2 wait instance-terminated --region "$REGION" --instance-ids "$INSTANCE_ID"
    echo "    Instance terminated."

    echo "==> Releasing Elastic IP ($ALLOC_ID)..."
    aws ec2 release-address --region "$REGION" --allocation-id "$ALLOC_ID"
    echo "    Elastic IP released."

    echo "==> Deleting security group $SG_ID..."
    sleep 5  # let network interfaces detach
    aws ec2 delete-security-group --region "$REGION" --group-id "$SG_ID" 2>/dev/null || \
        echo "    Note: security group deletion skipped (may have dependencies)"

    echo "==> Deleting CloudWatch alarm..."
    aws cloudwatch delete-alarms \
        --region "$REGION" \
        --alarm-names "llm-gpu-idle-stop-${INSTANCE_ID}" 2>/dev/null || true

    rm -f "$STATE_FILE"
    echo ""
    echo "==> All resources deleted."
else
    # Default: --stop
    STATUS=$(aws ec2 describe-instances \
        --region "$REGION" \
        --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].State.Name' \
        --output text)

    if [ "$STATUS" = "running" ]; then
        echo "==> Stopping instance $INSTANCE_ID..."
        aws ec2 stop-instances --region "$REGION" --instance-ids "$INSTANCE_ID"
        echo "    Instance stopping..."
        echo "    EBS disk preserved. You can restart with: ./connect.sh"
    else
        echo "    Instance is already in state: $STATUS"
    fi

    echo ""
    echo "==> Instance stopped."
    echo "    Elastic IP $ELASTIC_IP retained (cost: ~\$0.005/hr while not attached to running instance)."
    echo "    To restart: ./connect.sh"
    echo "    To delete everything: ./teardown.sh --terminate"
fi
