# AWS/WP-infra/scripts/teardown-asg.sh
#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/env.sh"

echo "[ASG] Sänker och tar bort Auto Scaling + lösa instanser..."

# A) Försök via kända stackar (web-asg/wp-alb-asg)
for S in web-asg wp-alb-asg; do
  if aws cloudformation describe-stacks --stack-name "$S" >/dev/null 2>&1; then
    echo "  - Downscale stack: $S"
    ASGS=$(aws cloudformation describe-stack-resources --stack-name "$S" \
      --query "StackResources[?ResourceType=='AWS::AutoScaling::AutoScalingGroup'].PhysicalResourceId" --output text)
    for A in $ASGS; do
      aws autoscaling update-auto-scaling-group --auto-scaling-group-name "$A" --min-size 0 --desired-capacity 0 || true
    done
    echo "  - Delete stack: $S"
    aws cloudformation delete-stack --stack-name "$S"
    aws cloudformation wait stack-delete-complete --stack-name "$S" || true
  fi
done

# B) Ta bort ev. manuella ASG som börjar på wp-
LEFT_ASG=$(aws autoscaling describe-auto-scaling-groups \
  --query "AutoScalingGroups[?starts_with(AutoScalingGroupName,'wp-')].AutoScalingGroupName" --output text)
for A in $LEFT_ASG; do
  echo "  - Delete leftover ASG: $A"
  aws autoscaling update-auto-scaling-group --auto-scaling-group-name "$A" --min-size 0 --desired-capacity 0 || true
  aws autoscaling delete-auto-scaling-group --auto-scaling-group-name "$A" --force-delete || true
done

# C) Terminera ev. instanser med namn som börjar på wp-
INST=$(aws ec2 describe-instances \
  --filters Name=tag:Name,Values=wp-* Name=instance-state-name,Values=pending,running,stopping,stopped \
  --query "Reservations[].Instances[].InstanceId" --output text)
if [ -n "${INST:-}" ]; then
  echo "  - Terminate instances: $INST"
  aws ec2 terminate-instances --instance-ids $INST || true
  aws ec2 wait instance-terminated --instance-ids $INST || true
fi

echo "[ASG] Klart."