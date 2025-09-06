# AWS/WP-infra/scripts/env.sh
export AWS_REGION=eu-west-1
export PROTECT_VPC_ID="vpc-0293dde1c8b69bca7"   # BEHÅLLS
export PROTECT_KEYPAIR="myDemokey"              # BEHÅLLS
export MAKE_RDS_SNAPSHOT="no"                   # "yes" om du vill spara snapshot
aws configure set region "$AWS_REGION" >/dev/null