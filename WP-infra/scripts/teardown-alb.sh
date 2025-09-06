# AWS/WP-infra/scripts/teardown-alb.sh
#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/env.sh"

echo "[ALB] Tar bort ALB/TG/Listeners..."

# A) Stacken edge-alb om den finns
if aws cloudformation describe-stacks --stack-name edge-alb >/dev/null 2>&1; then
  echo "  - Delete stack: edge-alb"
  aws cloudformation delete-stack --stack-name edge-alb
  aws cloudformation wait stack-delete-complete --stack-name edge-alb || true
fi

# B) Manuella ALB som börjar på wp-
LB_ARNS=$(aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?starts_with(LoadBalancerName,'wp-')].LoadBalancerArn" --output text)
for L in $LB_ARNS; do
  echo "  - Delete listeners for $L"
  LSN=$(aws elbv2 describe-listeners --load-balancer-arn "$L" --query "Listeners[].ListenerArn" --output text)
  for X in $LSN; do aws elbv2 delete-listener --listener-arn "$X" || true; done

  echo "  - Delete ALB $L"
  aws elbv2 delete-load-balancer --load-balancer-arn "$L" || true
done

# C) Ta target groups (efter att ALB är borta)
TG_ARNS=$(aws elbv2 describe-target-groups \
  --query "TargetGroups[?starts_with(TargetGroupName,'wp-')].TargetGroupArn" --output text)
for T in $TG_ARNS; do
  echo "  - Delete TG $T"
  aws elbv2 delete-target-group --target-group-arn "$T" || true
done

echo "[ALB] Klart."