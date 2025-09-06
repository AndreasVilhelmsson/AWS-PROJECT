#!/usr/bin/env bash
set -euo pipefail

# === Paths ===
WF_ROOT="$(cd "$(dirname "$0")/.." && pwd)"           # .../AWS/WP-infra
REPO_ROOT="$(cd "$WF_ROOT/.." && pwd)"                # .../AWS
SCRIPTS_DIR="$WF_ROOT/scripts"
TEMPLATES_DIR="$WF_ROOT/templates"

# === Env ===
# shellcheck source=/dev/null
source "$SCRIPTS_DIR/env.build.sh"

# === SSH key in repo root ===
KEY_PATH="$REPO_ROOT/myDemokey.pem"
[ -f "$KEY_PATH" ] || { echo "Hittar inte $KEY_PATH"; exit 1; }
chmod 400 "$KEY_PATH"

# === Common lookups ===
EFS_ID=$(aws cloudformation list-exports --query "Exports[?Name=='base-storage-EfsId'].Value" --output text)
WEB_SG=$(aws cloudformation list-exports --query "Exports[?Name=='base-storage-WebSgId'].Value" --output text)

echo "==[ STEP 4/6 ]=========================================================="
echo "[4] Skapar EC2 #2 (samma mall som #1, utan EFS i UD)..."
aws cloudformation deploy \
  --stack-name ec2-2 \
  --template-file "$TEMPLATES_DIR/ec2-single.yaml" \
  --parameter-overrides \
    SubnetId="$SUBNET_PUBLIC" \
    KeyPairName="$KEYPAIR_NAME" \
    MyCidr="$MY_CIDR" \
    DBPassword="$DB_PASSWORD"

INSTANCE_ID2=$(aws cloudformation describe-stacks --stack-name ec2-2 \
  --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" --output text)

echo "[4a] Väntar på att EC2 #2 blir 'running'..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID2"
echo "[4a] Väntar på status checks (2/2 ok)..."
aws ec2 wait instance-status-ok --instance-ids "$INSTANCE_ID2"

EC2_PUBLIC_IP2=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID2" \
  --query "Reservations[0].Instances[0].PublicIpAddress" --output text)
echo "EC2 #2 public IP: $EC2_PUBLIC_IP2"

# se till att 22 är öppet från din IP (tyst om du redan har regeln)
aws ec2 authorize-security-group-ingress \
  --group-id "$WEB_SG" --protocol tcp --port 22 --cidr "$MY_CIDR" >/dev/null 2>&1 || true

echo "[4b] Mountar EFS på EC2 #2 och verifierar delning..."
ssh -o StrictHostKeyChecking=no -i "$KEY_PATH" ec2-user@"$EC2_PUBLIC_IP2" <<EOF
  set -euxo pipefail
  sudo dnf -y install amazon-efs-utils
  sudo mkdir -p /var/www/html
  # Försök DNS via efs-utils (TLS)
  if ! sudo mount -t efs -o tls ${EFS_ID}:/ /var/www/html ; then
    echo "DNS mount misslyckades – hämtar MT-IP för subnet och provar NFSv4.1"
    EC2_SUBNET=\$(curl -s http://169.254.169.254/latest/meta-data/network/interfaces/macs/ | head -n1 | xargs -I{} curl -s http://169.254.169.254/latest/meta-data/network/interfaces/macs/{}subnet-id)
    MT_IP=\$(aws efs describe-mount-targets --file-system-id ${EFS_ID} --query "MountTargets[?SubnetId==\`\$EC2_SUBNET\`].IpAddress" --output text)
    sudo mount -t nfs4 -o nfsvers=4.1 \${MT_IP}:/ /var/www/html
  fi
  grep -q "${EFS_ID}:" /etc/fstab || echo "${EFS_ID}:/ /var/www/html efs _netdev,tls 0 0" | sudo tee -a /etc/fstab
  echo "from-ec2-2" | sudo tee /var/www/html/.probe2
  ls -la /var/www/html/.probe /var/www/html/.probe2 || true
  df -hT /var/www/html
EOF

echo
echo "⏸ Paus: Öppna konsolen och bekräfta att EC2 #2 kör och ser .probe/.probe2."
read -p "Tryck [Enter] för att gå vidare till Launch Template..."

echo "==[ STEP 5/6 ]=========================================================="
echo "[5] Skapar/uppdaterar Launch Template (cloud-init mountar EFS först)..."
aws cloudformation deploy \
  --stack-name web-lt \
  --template-file "$TEMPLATES_DIR/web-lt.yaml" \
  --parameter-overrides \
    KeyPairName="$KEYPAIR_NAME" \
    DBPassword="$DB_PASSWORD"

echo
echo "⏸ Paus: Kolla EC2 → Launch Templates att 'wp-lt' finns."
read -p "Tryck [Enter] för att gå vidare till ASG..."

echo "==[ STEP 6/6 ]=========================================================="
echo "[6] Skapar/uppdaterar ASG från LT och skalar upp till 2..."

# ⚠️ Viktigt: om du INTE har NAT i privata subnät, låt båda subnät vara PUBLIC
# Annars kan user-data (curl wordpress.org) fallera i privata subnät pga saknad egress.
ASG_SUBNET_1="$SUBNET_PUBLIC"
ASG_SUBNET_2="$SUBNET_PUBLIC"   # ändra till t.ex. $SUBNET_PRIVATE_A om du har NAT

aws cloudformation deploy \
  --stack-name web-asg-ec2hc \
  --template-file "$TEMPLATES_DIR/web-asg.yaml" \
  --parameter-overrides \
    PublicSubnet1Id="$ASG_SUBNET_1" \
    PublicSubnet2Id="$ASG_SUBNET_2"

ASG=$(aws cloudformation describe-stack-resources --stack-name web-asg-ec2hc \
  --query "StackResources[?ResourceType=='AWS::AutoScaling::AutoScalingGroup'].PhysicalResourceId" --output text)

# Skala upp
aws autoscaling update-auto-scaling-group --auto-scaling-group-name "$ASG" --desired-capacity 2

echo "Hämtar översikt på körande instanser:"
aws ec2 describe-instances --filters Name=instance-state-name,Values=running \
  --query "Reservations[].Instances[].{ID:InstanceId,AZ:Placement.AvailabilityZone,IP:PublicIpAddress,Name:Tags[?Key=='Name']|[0].Value}"

echo
echo "⏸ Paus: När den nya ASG-instanse(n) är 'running', SSH:a in och kör:"
echo "  df -hT /var/www/html   # ska visa efs eller nfs4"
echo "  ls -la /var/www/html/.probe /var/www/html/.probe2"
echo "======================================================================="
echo "✅ Klart steg 4–6."