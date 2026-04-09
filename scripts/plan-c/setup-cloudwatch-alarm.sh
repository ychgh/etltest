#!/usr/bin/env bash
# Plan C – Set up CloudWatch alarm to auto-stop the instance on low CPU
# Run after launch-spot.sh
# Usage: ./setup-cloudwatch-alarm.sh

set -euo pipefail

STATE_FILE="${HOME}/.devspot-state"
if [ ! -f "$STATE_FILE" ]; then
    echo "Error: State file not found. Run launch-spot.sh first."
    exit 1
fi
source "$STATE_FILE"

ALARM_NAME="dev-spot-idle-stop-${INSTANCE_ID}"

echo "==> Creating CloudWatch auto-stop alarm..."
echo "    Instance:    $INSTANCE_ID"
echo "    Alarm:       $ALARM_NAME"
echo "    Trigger:     CPU < 5% for 30 consecutive minutes (6 × 5-min periods)"
echo "    Action:      Stop instance"

aws cloudwatch put-metric-alarm \
    --region "$REGION" \
    --alarm-name "$ALARM_NAME" \
    --alarm-description "Auto-stop dev spot instance when CPU < 5% for 30 min" \
    --metric-name CPUUtilization \
    --namespace AWS/EC2 \
    --statistic Average \
    --dimensions "Name=InstanceId,Value=${INSTANCE_ID}" \
    --period 300 \
    --evaluation-periods 6 \
    --threshold 5 \
    --comparison-operator LessThanThreshold \
    --treat-missing-data notBreaching \
    --alarm-actions "arn:aws:automate:${REGION}:ec2:stop"

echo ""
echo "==> Alarm created successfully."
echo "    Instance will auto-stop after 30 minutes of idle (CPU < 5%)."
echo "    View in console: https://${REGION}.console.aws.amazon.com/cloudwatch/home#alarmsV2:"
