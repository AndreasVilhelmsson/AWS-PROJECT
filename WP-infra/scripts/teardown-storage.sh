# AWS/WP-infra/scripts/teardown-storage.sh
#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/env.sh"

echo "[STORAGE] Tar bort EFS/RDS och kvarvarande SG..."

# A) Stacken base-storage om den finns
if aws cloudformation describe-stacks --stack-name base-storage >/dev/null 2>&1; then
  echo "  - Delete stack: base-storage"
  aws cloudformation delete-stack --stack-name base-storage
  aws cloudformation wait stack-delete-complete --stack-name base-storage || true
fi

# B) RDS (med ev. snapshot)
DBS=$(aws rds describe-db-instances --query "DBInstances[?starts_with(DBInstanceIdentifier,'wp-')].DBInstanceIdentifier" --output text)
for D in $DBS; do
  if [ "${MAKE_RDS_SNAPSHOT}" = "yes" ]; then
    SNAP="${D}-final-$(date +%Y%m%d%H%M%S)"
    echo "  - Create snapshot $SNAP for $D"
    aws rds create-db-snapshot --db-instance-identifier "$D" --db-snapshot-identifier "$SNAP" || true
    aws rds wait db-snapshot-available --db-snapshot-identifier "$SNAP" || true
  fi
  echo "  - Delete RDS $D"
  aws rds delete-db-instance --db-instance-identifier "$D" --skip-final-snapshot || true
  aws rds wait db-instance-deleted --db-instance-identifier "$D" || true
done

# Ta bort ev. DB Subnet Groups med prefix wp-
DBG=$(aws rds describe-db-subnet-groups \
  --query "DBSubnetGroups[?starts_with(DBSubnetGroupName,'wp-')].DBSubnetGroupName" --output text)
for G in $DBG; do
  echo "  - Delete DB Subnet Group $G"
  aws rds delete-db-subnet-group --db-subnet-group-name "$G" || true
done

# C) EFS i vår VPC (ta mount targets först)
EFS_IDS=$(aws efs describe-file-systems --query "FileSystems[].FileSystemId" --output text)
for F in $EFS_IDS; do
  # kolla att EFS hör till vår VPC via dess mount targets
  MT_SUBNETS=$(aws efs describe-mount-targets --file-system-id "$F" --query "MountTargets[].SubnetId" --output text || true)
  [ -z "$MT_SUBNETS" ] && { aws efs delete-file-system --file-system-id "$F" || true; continue; }
  MT_VPCS=""
  for S in $MT_SUBNETS; do
    V=$(aws ec2 describe-subnets --subnet-ids "$S" --query "Subnets[].VpcId" --output text)
    MT_VPCS="$MT_VPCS $V"
  done
  if echo "$MT_VPCS" | grep -q "$PROTECT_VPC_ID"; then
    echo "  - Delete EFS $F (in our VPC)"
    MT_IDS=$(aws efs describe-mount-targets --file-system-id "$F" --query "MountTargets[].MountTargetId" --output text)
    for M in $MT_IDS; do aws efs delete-mount-target --mount-target-id "$M" || true; done
    sleep 10
    aws efs delete-file-system --file-system-id "$F" || true
  fi
done

# D) Kvarvarande SG i VPC som börjar med wp-
SGS=$(aws ec2 describe-security-groups --filters Name=vpc-id,Values="$PROTECT_VPC_ID" \
  --query "SecurityGroups[?starts_with(GroupName,'wp-')].GroupId" --output text)
for S in $SGS; do
  echo "  - Delete leftover SG $S"
  aws ec2 delete-security-group --group-id "$S" || true
done

echo "[STORAGE] Klart."