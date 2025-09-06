#!/usr/bin/env bash
set -euo pipefail

STACK_NAME="wp-alb-asg"

echo "⚠️ Raderar CloudFormation stack: $STACK_NAME ..."
aws cloudformation delete-stack --stack-name "$STACK_NAME"

echo "⏳ Väntar tills stacken är helt raderad..."
aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME"
echo "✅ Stacken är raderad."

# Dubbelkolla att inga resurser ligger kvar (ska ge tom output)
echo "Kvarvarande ALB/TG med prefix 'wp' (om några):"
aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?contains(LoadBalancerName, \`wp\`)].{Name:LoadBalancerName, ARN:LoadBalancerArn}" \
  --output table || true

aws elbv2 describe-target-groups \
  --query "TargetGroups[?contains(TargetGroupName, \`wp\`)].{Name:TargetGroupName, ARN:TargetGroupArn}" \
  --output table || true

echo "✅ Reset klar. Nu kan du köra deploy igen."