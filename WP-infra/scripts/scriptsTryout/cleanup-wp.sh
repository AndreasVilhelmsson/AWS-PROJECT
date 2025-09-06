#!/usr/bin/env bash
set -euo pipefail

########################################
# Konfig
########################################
REGION="${REGION:-eu-west-1}"

# Vanliga stacknamn i labben – lägg gärna till egna om du använde andra namn
STACKS=(
  "wp-alb-asg"
  "wp-rds-al2023"
  "WP"
)

# Mönster vi städar på för resurser som kan bli “orphans”
NAME_PATTERNS=("wp-" "wp-alb" "wp-ec2" "wp-rds")

# Sätt DRY_RUN=true för att bara visa vad som skulle köras
DRY_RUN="${DRY_RUN:-false}"

########################################
# Hjälpare
########################################
say() { echo -e "\n==> $*"; }

run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    printf '[DRY-RUN] %s\n' "$*"
  else
    eval "$@"
  fi
}

exists_stack() {
  aws cloudformation describe-stacks \
    --region "$REGION" \
    --stack-name "$1" >/dev/null 2>&1
}

########################################
# 1) Radera CloudFormation-stacks
########################################
say "Raderar CloudFormation-stacks (om de finns)…"
for s in "${STACKS[@]}"; do
  if exists_stack "$s"; then
    say "Delete stack: $s"
    run "aws cloudformation delete-stack --region '$REGION' --stack-name '$s'"
    if [[ "$DRY_RUN" == "false" ]]; then
      say "Väntar på stack-delete: $s"
      aws cloudformation wait stack-delete-complete \
        --region "$REGION" \
        --stack-name "$s" || true
    fi
  else
    echo "  (saknas) $s"
  fi
done

########################################
# 2) Ta ned ASG (skala till 0, radera)
########################################
say "Skalar ned och tar bort Auto Scaling Groups som matchar namn-mönster…"
ASGS=$(aws autoscaling describe-auto-scaling-groups --region "$REGION" \
  --query "AutoScalingGroups[?${NAME_PATTERNS[*]/#/contains(AutoScalingGroupName, '}${NAME_PATTERNS[*]/%/')||contains(AutoScalingGroupName, '} }')].AutoScalingGroupName" \
  --output text | tr '\t' '\n' | sort -u)

if [[ -n "${ASGS:-}" ]]; then
  while read -r g; do
    [[ -z "$g" ]] && continue
    say "ASG: $g -> desired=0 (min=0, max=0), sedan delete"
    run "aws autoscaling update-auto-scaling-group --region '$REGION' --auto-scaling-group-name '$g' --min-size 0 --max-size 0 --desired-capacity 0"
    # Vänta lite så instanser får dräneras
    if [[ "$DRY_RUN" == "false" ]]; then sleep 10; fi
    run "aws autoscaling delete-auto-scaling-group --region '$REGION' --auto-scaling-group-name '$g' --force-delete"
  done <<< "$ASGS"
else
  echo "  (inga matchande ASGs)"
fi

########################################
# 3) Ta bort Launch Templates
########################################
say "Tar bort Launch Templates som matchar namn-mönster…"
LT_IDS=$(aws ec2 describe-launch-templates --region "$REGION" \
  --query "LaunchTemplates[?${NAME_PATTERNS[*]/#/contains(LaunchTemplateName, '}${NAME_PATTERNS[*]/%/')||contains(LaunchTemplateName, '} }')].LaunchTemplateId" \
  --output text | tr '\t' '\n' | sort -u)

if [[ -n "${LT_IDS:-}" ]]; then
  while read -r lt; do
    [[ -z "$lt" ]] && continue
    say "Delete LaunchTemplate: $lt"
    run "aws ec2 delete-launch-template --region '$REGION' --launch-template-id '$lt'"
  done <<< "$LT_IDS"
else
  echo "  (inga matchande Launch Templates)"
fi

########################################
# 4) Ta bort ALB-listeners, ALBs och Target Groups
########################################
say "Tar bort ALB + Listeners…"
LB_ARNS=$(aws elbv2 describe-load-balancers --region "$REGION" \
  --query "LoadBalancers[?${NAME_PATTERNS[*]/#/contains(LoadBalancerName, '}${NAME_PATTERNS[*]/%/')||contains(LoadBalancerName, '} }')].LoadBalancerArn" \
  --output text | tr '\t' '\n' | sort -u)

if [[ -n "${LB_ARNS:-}" ]]; then
  while read -r lb; do
    [[ -z "$lb" ]] && continue
    say "ALB: $lb – tar bort listeners"
    LST=$(aws elbv2 describe-listeners --region "$REGION" --load-balancer-arn "$lb" \
      --query "Listeners[].ListenerArn" --output text | tr '\t' '\n')
    if [[ -n "${LST:-}" ]]; then
      while read -r l; do
        [[ -z "$l" ]] && continue
        run "aws elbv2 delete-listener --region '$REGION' --listener-arn '$l'"
      done <<< "$LST"
      if [[ "$DRY_RUN" == "false" ]]; then sleep 5; fi
    fi
    say "Delete ALB: $lb"
    run "aws elbv2 delete-load-balancer --region '$REGION' --load-balancer-arn '$lb'"
  done <<< "$LB_ARNS"
else
  echo "  (inga matchande ALBs)"
fi

say "Tar bort Target Groups…"
TG_ARNS=$(aws elbv2 describe-target-groups --region "$REGION" \
  --query "TargetGroups[?${NAME_PATTERNS[*]/#/contains(TargetGroupName, '}${NAME_PATTERNS[*]/%/')||contains(TargetGroupName, '} }')].TargetGroupArn" \
  --output text | tr '\t' '\n' | sort -u)

if [[ -n "${TG_ARNS:-}" ]]; then
  # LBs behöver hinna försvinna först
  if [[ "$DRY_RUN" == "false" ]]; then sleep 10; fi
  while read -r tg; do
    [[ -z "$tg" ]] && continue
    say "Delete Target Group: $tg"
    run "aws elbv2 delete-target-group --region '$REGION' --target-group-arn '$tg'"
  done <<< "$TG_ARNS"
else
  echo "  (inga matchande Target Groups)"
fi

########################################
# 5) Ta bort Security Groups som inte används
########################################
say "Rensar Security Groups (som matchar mönster och inte är associerade)…"
SG_IDS=$(aws ec2 describe-security-groups --region "$REGION" \
  --query "SecurityGroups[?(${NAME_PATTERNS[*]/#/contains(GroupName, '}${NAME_PATTERNS[*]/%/')||contains(GroupName, '} }') && GroupName!='default')].GroupId" \
  --output text | tr '\t' '\n' | sort -u)

if [[ -n "${SG_IDS:-}" ]]; then
  while read -r sg; do
    [[ -z "$sg" ]] && continue
    # Hoppa över SGs som fortfarande sitter på ENIs
    ATTACH=$(aws ec2 describe-network-interfaces --region "$REGION" \
      --filters "Name=group-id,Values=$sg" \
      --query "NetworkInterfaces[].NetworkInterfaceId" --output text)
    if [[ -n "${ATTACH:-}" ]]; then
      echo "  (skippar – i bruk) $sg"
      continue
    fi
    say "Delete Security Group: $sg"
    run "aws ec2 delete-security-group --region '$REGION' --group-id '$sg'"
  done <<< "$SG_IDS"
else
  echo "  (inga matchande Security Groups utan kopplingar)"
fi

########################################
# 6) Manuell koll
########################################
say "Kvarvarande ‘wp*’-instanser (om några):"
aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Name,Values=wp-*" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query "Reservations[].Instances[].{Id:InstanceId,State:State.Name,Name:Tags[?Key=='Name']|[0].Value}" \
  --output table || true

say "Kvarvarande ‘wp*’-ALB/TG (om några):"
aws elbv2 describe-load-balancers --region "$REGION" \
  --query "LoadBalancers[?starts_with(LoadBalancerName, 'wp')].[LoadBalancerName,State.Code]" \
  --output table || true
aws elbv2 describe-target-groups --region "$REGION" \
  --query "TargetGroups[?starts_with(TargetGroupName, 'wp')].[TargetGroupName,TargetType]" \
  --output table || true

say "Rensning klar."