#!/usr/bin/env bash
# ============================================================
# WP-infra/scripts/deploy-all.sh
# One-click IaC deploy för WordPress-labbet
# - Validerar mallar
# - Kör stackar i rätt ordning
# - Hämtar outputs/exports (LT_ID/LT_VER/TG_ARN/DNS)
# - Visar en snabb hälsosummary i slutet
# ============================================================

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TPL_DIR="${ROOT_DIR}/templates"
SCRIPTS_DIR="${ROOT_DIR}/scripts"

# 1) Ladda miljö (dödar inte terminalen om man råkar köra 'source')
#    -> ger AWS_REGION, VPC_ID, SUBNET_PUBLIC(_B), KEYPAIR_NAME, DB_PASSWORD, m.m.
#    -> plockar även upp ev. tidigare exports (WEB_SG, ALB_* ...)
#    OBS: filen är skriven så fel inte kraschar här; vi gör extra kontroller nedan
# shellcheck source=/dev/null
source "${SCRIPTS_DIR}/env.build.sh"

# -------- Små hjälpfunktioner --------------------------------
log(){ printf "\n\033[1;36m%s\033[0m\n" "$*"; }
warn(){ printf "\033[1;33m%s\033[0m\n" "$*" >&2; }
die(){ printf "\033[1;31mERROR:\033[0m %s\n" "$*" >&2; exit 1; }

need(){
  local name="$1" value="${!1:-}"
  [[ -n "$value" ]] || die "Saknar obligatorisk variabel: ${name}"
}

awsc(){ aws "$@" >/dev/null; }    # “quiet” variant för kontroller
validate_tpl(){ aws cloudformation validate-template --template-body "file://$1" >/dev/null; }

# -------- Grundkrav -------------------------------------------
need AWS_REGION
need VPC_ID
need SUBNET_PUBLIC
need SUBNET_PUBLIC_B
need KEYPAIR_NAME
need DB_PASSWORD

# -------- 0) Validera mallar ----------------------------------
log "Validerar CloudFormation-mallar…"
validate_tpl "${TPL_DIR}/base-storage.yaml"
validate_tpl "${TPL_DIR}/web-lt.yaml"
validate_tpl "${TPL_DIR}/web-alb.yaml"
validate_tpl "${TPL_DIR}/web-asg.yaml"
log "Mallvalidering OK."

# -------- 1) Storage (EFS + SG + ev. DB-endpoint export) ------
log "1/4: Deploy 'base-storage' …"
aws cloudformation deploy \
  --stack-name base-storage \
  --template-file "${TPL_DIR}/base-storage.yaml" \
  --capabilities CAPABILITY_NAMED_IAM \
  --no-fail-on-empty-changeset

# Läs ut export av webb-SG (skapas av base-storage)
WEB_SG="$(aws cloudformation list-exports \
  --query "Exports[?Name=='base-storage-WebSgId'].Value" --output text)"
[[ -n "${WEB_SG}" && "${WEB_SG}" != "None" ]] || die "Hittade inget WebSgId från base-storage."

log "Web SG: ${WEB_SG}"

# -------- 2) Launch Template (userdata, EFS-mount, WP-setup) ---
log "2/4: Deploy 'web-lt' (Launch Template) …"
aws cloudformation deploy \
  --stack-name web-lt \
  --template-file "${TPL_DIR}/web-lt.yaml" \
  --parameter-overrides \
     KeyPairName="${KEYPAIR_NAME}" \
     DBPassword="${DB_PASSWORD}" \
  --no-fail-on-empty-changeset

# Hämta LaunchTemplateId + Version från stackresurserna
LT_ID="$(aws cloudformation describe-stack-resources \
  --stack-name web-lt \
  --query "StackResources[?ResourceType=='AWS::EC2::LaunchTemplate'].PhysicalResourceId" \
  --output text)"
LT_VER="$(aws ec2 describe-launch-templates \
  --launch-template-ids "$LT_ID" \
  --query "LaunchTemplates[0].LatestVersionNumber" --output text)"

need LT_ID
need LT_VER
log "LaunchTemplateId=${LT_ID}  Version=${LT_VER}"

# -------- 3) ALB (SG + ALB + TG + Listener) -------------------
log "3/4: Deploy 'web-alb' …"
aws cloudformation deploy \
  --stack-name web-alb \
  --template-file "${TPL_DIR}/web-alb.yaml" \
  --parameter-overrides \
     VpcId="${VPC_ID}" \
     SubnetAId="${SUBNET_PUBLIC}" \
     SubnetBId="${SUBNET_PUBLIC_B}" \
  --no-fail-on-empty-changeset

# Läs ut exports från web-alb
ALB_SG="$(aws cloudformation list-exports \
  --query "Exports[?Name=='web-alb-AlbSgId'].Value" --output text)"
ALB_DNS="$(aws cloudformation list-exports \
  --query "Exports[?Name=='web-alb-AlbDnsName'].Value" --output text)"
TG_ARN="$(aws cloudformation list-exports \
  --query "Exports[?Name=='web-alb-TgArn'].Value" --output text)"

need ALB_SG
need ALB_DNS
need TG_ARN
log "ALB SG=${ALB_SG}"
log "ALB  DNS=${ALB_DNS}"
log "TG   ARN=${TG_ARN}"

# -------- 4) ASG (kopplar in LT + TG i två AZ) ----------------
log "4/4: Deploy 'web-asg' …"
aws cloudformation deploy \
  --stack-name web-asg-ec2hc \
  --template-file "${TPL_DIR}/web-asg.yaml" \
  --parameter-overrides \
     SubnetAId="${SUBNET_PUBLIC}" \
     SubnetBId="${SUBNET_PUBLIC_B}" \
     LaunchTemplateId="${LT_ID}" \
     LaunchTemplateVersion="${LT_VER}" \
     TargetGroupArn="${TG_ARN}" \
  --no-fail-on-empty-changeset

# -------- Snabb status ----------------------------------------
log "Sammanfattning:"
printf '  %-18s %s\n' "Region:"         "${AWS_REGION}"
printf '  %-18s %s\n' "VPC:"            "${VPC_ID}"
printf '  %-18s %s / %s\n' "Subnets:"   "${SUBNET_PUBLIC}" "${SUBNET_PUBLIC_B}"
printf '  %-18s %s\n' "Web SG:"         "${WEB_SG}"
printf '  %-18s %s (v%s)\n' "LaunchTpl:" "${LT_ID}" "${LT_VER}"
printf '  %-18s %s\n' "ALB DNS:"        "${ALB_DNS}"
printf '  %-18s %s\n' "TG ARN:"         "${TG_ARN}"

log "Target health (kan ta ~1–2 min att bli healthy):"
aws elbv2 describe-target-health --target-group-arn "${TG_ARN}" \
  --query 'TargetHealthDescriptions[].{Id:Target.Id,State:TargetHealth.State,Desc:TargetHealth.Description}' \
  --output table || true

log "Klart! Öppna: http://${ALB_DNS}"