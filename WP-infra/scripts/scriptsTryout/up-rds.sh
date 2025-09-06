#!/usr/bin/env bash
set -euo pipefail

# ---- Grundkonfig (kan överstyras vid körning) ----
REGION=${REGION:-eu-west-1}
STACK=${STACK:-wp-rds-al2023}
TEMPLATE=${TEMPLATE:-templates/wp-rds-al2023.yaml}
PARAMS_FILE=${PARAMS_FILE:-params/rds-dev.json}

echo "Region  : $REGION"
echo "Stack   : $STACK"
echo "Template: $TEMPLATE"
echo "Params  : $PARAMS_FILE"
echo

# ---- Interaktiv input ----
read -rp "My public IP in CIDR (e.g. 188.148.159.34/32): " MYIP
read -srp "DB master password: " DBPASS; echo

# ---- Validera template ----
aws cloudformation validate-template \
  --region "$REGION" \
  --template-body file://"$TEMPLATE" >/dev/null
echo "✅ Template validation OK"

# ---- Bygg en temporär, sammanslagen parameterlista (bas + MyIP + DBPASS) ----
if ! command -v jq >/dev/null 2>&1; then
  echo "❌ jq saknas. Installera med: brew install jq"
  exit 1
fi

TMP_PARAMS="$(mktemp)"
jq -c \
  --arg MYIP "$MYIP" \
  --arg DBPASS "$DBPASS" \
  '. + [
     {"ParameterKey":"MyIP","ParameterValue":$MYIP},
     {"ParameterKey":"DBMasterPassword","ParameterValue":$DBPASS}
   ]' "$PARAMS_FILE" > "$TMP_PARAMS"

# ---- Skapa stack ----
aws cloudformation create-stack \
  --region "$REGION" \
  --stack-name "$STACK" \
  --template-body file://"$TEMPLATE" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameters file://"$TMP_PARAMS"

echo "⏳ Creating stack '$STACK' in '$REGION' ..."
aws cloudformation wait stack-create-complete --region "$REGION" --stack-name "$STACK"
echo "✅ CREATE_COMPLETE"

# ---- Plocka ut outputs ----
SITE_URL=$(
  aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='SiteURL'].OutputValue" --output text
)
PHPINFO_URL=$(
  aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='PhpInfoURL'].OutputValue" --output text
)
RDS_HOST=$(
  aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='RdsEndpoint'].OutputValue" --output text
)
EC2_DNS=$(
  aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='Ec2PublicDNS'].OutputValue" --output text
)

rm -f "$TMP_PARAMS"

echo
echo "🔗 WordPress: $SITE_URL"
echo "ℹ️  PHP info : $PHPINFO_URL"
echo "🗄️  RDS host : $RDS_HOST"
echo "🖥️  EC2 DNS  : $EC2_DNS"
echo
echo "Tips: ssh -i ~/Desktop/AWS/WP-infra/myDemokey.pem ec2-user@$EC2_DNS"