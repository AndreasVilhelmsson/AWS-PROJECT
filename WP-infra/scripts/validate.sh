#!/usr/bin/env bash
# ============================================================
# WP-infra/scripts/validate.sh
# Validerar projektets CloudFormation-mallar.
# - aws cloudformation validate-template
# - (valfritt) cfn-lint om det finns installerat
# Exit code 0 = allt OK, annars != 0
# ============================================================

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TPL_DIR="${ROOT_DIR}/templates"

# Lista över aktiva mallar i det här projektet:
TEMPLATES=(
  "base-storage.yaml"
  "web-lt.yaml"
  "web-alb.yaml"
  "web-asg.yaml"
)

# --------- Hjälpfunktioner ----------
bold(){ printf "\033[1m%s\033[0m\n" "$*"; }
ok(){   printf "\033[1;32m%s\033[0m\n" "$*"; }
warn(){ printf "\033[1;33m%s\033[0m\n" "$*" >&2; }
err(){  printf "\033[1;31mERROR:\033[0m %s\n" "$*" >&2; }

need_bin(){
  command -v "$1" >/dev/null 2>&1 || { err "Saknar binär: $1"; exit 1; }
}

aws_validate(){
  local f="$1"
  aws cloudformation validate-template --template-body "file://${f}" >/dev/null
}

cfn_lint_if_present(){
  if command -v cfn-lint >/dev/null 2>&1; then
    # Kör lint, låt fel bubbla upp (fail fast)
    cfn-lint -t "$1"
  else
    warn "cfn-lint ej installerad – hoppar över lint för: $1"
  fi
}

# --------- Förkontroller ----------
need_bin aws

# Visa vad som valideras
bold "Validerar CloudFormation-mallar i: ${TPL_DIR}"
printf "Filer:\n"
for t in "${TEMPLATES[@]}"; do
  printf "  - %s\n" "$t"
done
printf "\n"

# --------- Validera filer ----------
for t in "${TEMPLATES[@]}"; do
  FILE="${TPL_DIR}/${t}"
  if [[ ! -f "$FILE" ]]; then
    err "Hittar inte fil: ${FILE}"
    exit 2
  fi

  printf "▶︎ AWS-validate: %s ... " "$t"
  aws_validate "$FILE"
  ok "OK"

  printf "▶︎ cfn-lint:     %s ... " "$t"
  cfn_lint_if_present "$FILE" && ok "OK"
done

bold ""
ok "Alla mallar validerade utan fel."