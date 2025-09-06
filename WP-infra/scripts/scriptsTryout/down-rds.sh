#!/usr/bin/env bash
set -euo pipefail

REGION=${REGION:-eu-west-1}
STACK=${STACK:-wp-rds-al2023}

echo "Region: $REGION"
read -rp "Stack name to delete [${STACK}]: " INPUT
STACK=${INPUT:-$STACK}

echo
echo "🔎 Fetching current stack outputs (om stacken finns)..."
aws cloudformation describe-stacks \
  --region "$REGION" --stack-name "$STACK" \
  --query "Stacks[0].Outputs[].{Key:OutputKey,Val:OutputValue}" --output table || true

echo
read -rp "⚠️  CONFIRM delete stack '${STACK}' in '${REGION}'? (yes/no): " OK
[[ "$OK" == "yes" ]] || { echo "Avbrutet."; exit 0; }

echo "🧹 Deleting stack '$STACK' ..."
aws cloudformation delete-stack --region "$REGION" --stack-name "$STACK"

echo "⏳ Waiting for delete to complete..."
aws cloudformation wait stack-delete-complete --region "$REGION" --stack-name "$STACK"

echo "✅ DELETE_COMPLETE for '$STACK'"

echo
echo "Tips:"
echo "- Kontrollera i EC2 > Instances att instansen är borta."
echo "- RDS > Databases ska vara tomt för stackens instans."
echo "- CloudFormation > Stacks: '${STACK}' ska inte längre finnas."