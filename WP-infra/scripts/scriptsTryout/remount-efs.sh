#!/usr/bin/env bash
set -euo pipefail

# === Paths ===
WF_ROOT="$(cd "$(dirname "$0")/.." && pwd)"           # .../AWS/WP-infra
REPO_ROOT="$(cd "$WF_ROOT/.." && pwd)"                # .../AWS
SCRIPTS_DIR="$WF_ROOT/scripts"

# env
# shellcheck source=/dev/null
source "$SCRIPTS_DIR/env.build.sh"

# Nyckel i repo-rot
KEY_PATH="$REPO_ROOT/myDemokey.pem"                   # <-- HÄR
[ -f "$KEY_PATH" ] || { echo "Hittar inte $KEY_PATH"; exit 1; }
chmod 400 "$KEY_PATH"

# Hämta resurser
INSTANCE_ID=$(aws cloudformation describe-stacks --stack-name ec2-1 \
  --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" --output text)
EC2_PUBLIC_IP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query "Reservations[0].Instances[0].PublicIpAddress" --output text)
EFS_ID=$(aws cloudformation list-exports --query "Exports[?Name=='base-storage-EfsId'].Value" --output text)
EC2_SUBNET=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query "Reservations[0].Instances[0].SubnetId" --output text)
MT_IP=$(aws efs describe-mount-targets --file-system-id "$EFS_ID" \
  --query "MountTargets[?SubnetId=='$EC2_SUBNET'].IpAddress" --output text)

echo "Remount EFS=$EFS_ID on $EC2_PUBLIC_IP (MT_IP=$MT_IP)"
ssh -o StrictHostKeyChecking=no -i "$KEY_PATH" ec2-user@"$EC2_PUBLIC_IP" <<EOF
  set -euxo pipefail
  sudo dnf -y install amazon-efs-utils
  sudo umount -f /var/www/html || true
  sudo mkdir -p /var/www/html

  # 1) Försök DNS-baserad efs-utils
  if ! sudo mount -t efs -o tls ${EFS_ID}:/ /var/www/html ; then
    echo "DNS mount misslyckades – provar IP/NFS4 mot $MT_IP"
    # 2) Fallback till IP (NFSv4.1)
    sudo mount -t nfs4 -o nfsvers=4.1 ${MT_IP}:/ /var/www/html
  fi

  # Säkra fstab (använd DNS-varianten som standard)
  grep -q "${EFS_ID}:" /etc/fstab || echo "${EFS_ID}:/ /var/www/html efs _netdev,tls 0 0" | sudo tee -a /etc/fstab

  echo "probe-\$(date +%H%M%S)" | sudo tee /var/www/html/.probe
  echo "== mount =="
  mount | grep -E 'efs|nfs4' || true
  echo "== df -hT /var/www/html =="
  df -hT /var/www/html
  ls -la /var/www/html/.probe
EOF
echo "✅ Remount klar."