#!/usr/bin/env bash
set -euo pipefail

# ======= Konfig (justera vid behov) =======
REGION="${REGION:-eu-west-1}"
GOOD_EC2_ID="${GOOD_EC2_ID:-}"             # <-- Sätt ditt fungerande EC2-ID (från Step 2)
LT_NAME="${LT_NAME:-wp-alb-asg-lt}"        # Launch Template-namn
ASG_NAME="${ASG_NAME:-wp-alb-asg-AutoScalingGroup}"  # Prefix räcker ofta: 'wp-alb-asg'
TG_NAME_FILTER="${TG_NAME_FILTER:-wp}"      # för att hitta rätt Target Group
ALB_NAME_FILTER="${ALB_NAME_FILTER:-wp-alb}" # för att hitta rätt ALB
WARMUP="${WARMUP:-150}"                     # ASG Instance Refresh warmup sekunder
# ==========================================

say(){ echo -e "\n==> $*"; }

req() {
  if [[ -z "${!1:-}" ]]; then
    echo "Sätt $1=... (miljövariabel)"; exit 1
  fi
}

# 0) Kolla förutsättningar
req GOOD_EC2_ID

say "1) Skapar AMI från EC2 $GOOD_EC2_ID (ingen reboot)..."
AMI_ID=$(aws ec2 create-image \
  --region "$REGION" \
  --instance-id "$GOOD_EC2_ID" \
  --name "wp-golden-$(date +%Y%m%d-%H%M%S)" \
  --no-reboot \
  --query 'ImageId' --output text)
echo "AMI_ID=$AMI_ID"

say "   Väntar på att AMI blir tillgänglig..."
aws ec2 wait image-available --region "$REGION" --image-ids "$AMI_ID"
echo "   AMI är klar."

say "2) Hämtar Launch Template-id för '$LT_NAME'..."
LT_ID=$(aws ec2 describe-launch-templates \
  --region "$REGION" \
  --query "LaunchTemplates[?LaunchTemplateName==\`$LT_NAME\`].LaunchTemplateId" \
  --output text)
if [[ -z "$LT_ID" || "$LT_ID" == "None" ]]; then
  echo "Hittar inte Launch Template med namn '$LT_NAME'"; exit 1
fi
echo "LT_ID=$LT_ID"

say "   Skapar NY LT-version med AMI=$AMI_ID + AssociatePublicIpAddress=true..."
NEW_VER=$(aws ec2 create-launch-template-version \
  --region "$REGION" \
  --launch-template-id "$LT_ID" \
  --source-version '$Latest' \
  --launch-template-data "{
    \"ImageId\": \"${AMI_ID}\",
    \"NetworkInterfaces\": [{
      \"DeviceIndex\": 0,
      \"AssociatePublicIpAddress\": true
    }]
  }" \
  --query 'LaunchTemplateVersion.LaunchTemplateVersionNumber' --output text)
echo "NEW_LT_VERSION=$NEW_VER"

say "3) Hittar ASG-namn (matchar '$ASG_NAME' eller innehåller 'wp-alb-asg')..."
ASG=$(aws autoscaling describe-auto-scaling-groups --region "$REGION" \
  --query "AutoScalingGroups[?contains(AutoScalingGroupName, \`wp-alb-asg\`) || AutoScalingGroupName==\`$ASG_NAME\`].AutoScalingGroupName" \
  --output text | head -n1)
if [[ -z "$ASG" ]]; then
  echo "Hittar ingen ASG som matchar"; exit 1
fi
echo "ASG=$ASG"

say "   Pekar ASG på LT $LT_ID version $NEW_VER ..."
aws autoscaling update-auto-scaling-group \
  --region "$REGION" \
  --auto-scaling-group-name "$ASG" \
  --launch-template "LaunchTemplateId=$LT_ID,Version=$NEW_VER"

say "   Startar Instance Refresh (warmup=${WARMUP}s)..."
aws autoscaling start-instance-refresh \
  --region "$REGION" \
  --auto-scaling-group-name "$ASG" \
  --preferences "MinHealthyPercentage=100,InstanceWarmup=${WARMUP}" >/dev/null

say "4) Hämtar ALB DNS + Target Group ARN..."
ALB_DNS=$(aws elbv2 describe-load-balancers --region "$REGION" \
  --query "LoadBalancers[?contains(LoadBalancerName, \`$ALB_NAME_FILTER\`)].DNSName" \
  --output text | head -n1)
TG_ARN=$(aws elbv2 describe-target-groups --region "$REGION" \
  --query "TargetGroups[?contains(TargetGroupName, \`$TG_NAME_FILTER\`)].TargetGroupArn" \
  --output text | head -n1)
echo "ALB: http://$ALB_DNS"
echo "TG_ARN=$TG_ARN"

say "   Väntar på friska targets (pollar i ~6-8 min max)..."
ATTEMPTS=40
SLEEP=10
OK=0
for i in $(seq 1 $ATTEMPTS); do
  STATES=$(aws elbv2 describe-target-health --region "$REGION" \
    --target-group-arn "$TG_ARN" \
    --query 'TargetHealthDescriptions[].TargetHealth.State' --output text | tr '\t' '\n' | sort -u || true)
  echo "  [$i/$ATTEMPTS] TG states: ${STATES:-<none>}"
  if [[ "$STATES" == "healthy" || "$STATES" == *"healthy"* ]]; then
    OK=1; break
  fi
  sleep "$SLEEP"
done

if [[ "$OK" -ne 1 ]]; then
  echo "⚠️ Targets blev inte healthy i tid – testar ändå ALB health endpoint."
fi

say "5) Testar ALB /health.txt"
set +e
curl -sS -i "http://$ALB_DNS/health.txt" || true
set -e

echo -e "\n✅ Klart (kontrollera att du får 200 OK ovan). Öppna:  http://$ALB_DNS/"