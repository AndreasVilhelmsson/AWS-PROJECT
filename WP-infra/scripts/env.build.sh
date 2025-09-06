# ===== WP-infra/scripts/env.build.sh =====
# Avsedd att SOURCAS i interaktivt skal utan att döda terminalen.

_is_sourced() { [[ "${BASH_SOURCE[0]}" != "${0}" ]]; }
if _is_sourced; then :; else set -euo pipefail; fi

_aws() { command aws "$@" 2>/dev/null || true; }
_say() { printf '%s\n' "$*"; }

export AWS_REGION=${AWS_REGION:-eu-west-1}
_aws configure set region "$AWS_REGION" >/dev/null || true

export VPC_ID=${VPC_ID:-"vpc-0293dde1c8b69bca7"}

SUBNETS=$(_aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=map-public-ip-on-launch,Values=true" \
  --query "sort_by(Subnets,&AvailabilityZone)[].SubnetId" --output text)
set -- $SUBNETS
export SUBNET_PUBLIC=${1:-}
export SUBNET_PUBLIC_B=${2:-}

export KEYPAIR_NAME=${KEYPAIR_NAME:-"myDemokey"}
export DB_PASSWORD=${DB_PASSWORD:-"StarktLosen123"}

MY_IP=$(curl -s --max-time 2 ifconfig.me || true)
export MY_CIDR="${MY_IP:+$MY_IP/32}"

export WEB_SG=$(_aws cloudformation list-exports \
  --query "Exports[?Name=='base-storage-WebSgId'].Value" --output text)
export ALB_SG=$(_aws cloudformation list-exports \
  --query "Exports[?Name=='web-alb-AlbSgId'].Value" --output text)
export ALB_DNS=$(_aws cloudformation list-exports \
  --query "Exports[?Name=='web-alb-AlbDns'].Value" --output text)

export AWS_PAGER=""
export AWSCLI_PAGER=""

_say "Region=$AWS_REGION"
_say "VPC_ID=$VPC_ID"
_say "SUBNET_PUBLIC=$SUBNET_PUBLIC"
_say "SUBNET_PUBLIC_B=$SUBNET_PUBLIC_B"
_say "KEYPAIR_NAME=$KEYPAIR_NAME"
_say "WEB_SG=$WEB_SG"
_say "ALB_SG=$ALB_SG"
_say "ALB_DNS=$ALB_DNS"
_say "MY_CIDR=$MY_CIDR"

_is_sourced && return 0 || true
# ===== end =====
