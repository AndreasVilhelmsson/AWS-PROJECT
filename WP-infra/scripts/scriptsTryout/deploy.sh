#!/usr/bin/env bash
set -euo pipefail

# === Paths ===
WF_ROOT="$(cd "$(dirname "$0")/.." && pwd)"             # .../AWS/WP-infra
REPO_ROOT="$(cd "$WF_ROOT/.." && pwd)"                  # .../AWS
SCRIPTS_DIR="$WF_ROOT/scripts"
TEMPLATES_DIR="$WF_ROOT/templates"

# 1) Ladda miljön
if [ ! -f "$SCRIPTS_DIR/env.build.sh" ]; then
  echo "Hittar inte $SCRIPTS_DIR/env.build.sh — skapa den först." >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$SCRIPTS_DIR/env.build.sh"

echo "==[ ENV ]=================================================="
echo "Region:         $AWS_REGION"
echo "VPC:            $VPC_ID"
echo "Private A / B:  $SUBNET_PRIVATE_A / $SUBNET_PRIVATE_B"
echo "Public:         $SUBNET_PUBLIC"
echo "KeyPair:        $KEYPAIR_NAME"
echo "My CIDR:        $MY_CIDR"
echo "Repo root:      $REPO_ROOT"
echo "============================================================"

# --- Nyckelväg (RELATIV TILL REPO-ROT) ------------------------------------
KEY_PATH="$REPO_ROOT/myDemokey.pem"          # <-- HÄR: alltid AWS/myDemokey.pem
if [ ! -f "$KEY_PATH" ]; then
  echo "Hittar inte nyckel på $KEY_PATH — kontrollera sökvägen." >&2
  exit 1
fi
chmod 400 "$KEY_PATH"
# ---------------------------------------------------------------------------

# 2) Deploy base-storage (EFS + RDS + SG)
echo -e "\n[1/3] Deploy: base-storage (EFS + RDS + SG) ..."
aws cloudformation deploy \
  --stack-name base-storage \
  --template-file "$TEMPLATES_DIR/base-storage.yaml" \
  --parameter-overrides \
    VpcId="$VPC_ID" \
    PrivateSubnet1Id="$SUBNET_PRIVATE_A" \
    PrivateSubnet2Id="$SUBNET_PRIVATE_B" \
    ClientSubnetId="$SUBNET_PUBLIC" \
    DBPassword="$DB_PASSWORD"

EFS_ID=$(aws cloudformation list-exports --query "Exports[?Name=='base-storage-EfsId'].Value" --output text)
DB_ENDPOINT=$(aws cloudformation list-exports --query "Exports[?Name=='base-storage-DbEndpoint'].Value" --output text)
echo "EFS: $EFS_ID"
echo "RDS endpoint: $DB_ENDPOINT"

# 3) Deploy EC2 #1 (utan EFS mount i detta steg)
echo -e "\n[2/3] Deploy: ec2-1 (WordPress → RDS) ..."
aws cloudformation deploy \
  --stack-name ec2-1 \
  --template-file "$TEMPLATES_DIR/ec2-single.yaml" \
  --parameter-overrides \
    SubnetId="$SUBNET_PUBLIC" \
    KeyPairName="$KEYPAIR_NAME" \
    MyCidr="$MY_CIDR" \
    DBPassword="$DB_PASSWORD"

EC2_INSTANCE_ID=$(aws cloudformation describe-stacks --stack-name ec2-1 \
  --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" --output text)
EC2_PUBLIC_IP=$(aws ec2 describe-instances --instance-ids "$EC2_INSTANCE_ID" \
  --query "Reservations[0].Instances[0].PublicIpAddress" --output text)

echo "EC2 #1 InstanceId: $EC2_INSTANCE_ID"
echo "EC2 #1 Public IP:  $EC2_PUBLIC_IP"

# --- Öppna SSH (22) från din IP i Web-SG ----------------------------------
WEB_SG=$(aws cloudformation list-exports \
  --query "Exports[?Name=='base-storage-WebSgId'].Value" --output text)
aws ec2 authorize-security-group-ingress \
  --group-id "$WEB_SG" --protocol tcp --port 22 --cidr "$MY_CIDR" >/dev/null 2>&1 || true
# ---------------------------------------------------------------------------

# 4) Mounta EFS på EC2 #1 (titthål) — använder lokalt EFS_ID
echo -e "\n[3/3] Mountar EFS på EC2 #1 och skapar titthål ..."
ssh -o StrictHostKeyChecking=no -i "$KEY_PATH" ec2-user@"$EC2_PUBLIC_IP" <<EOF
  set -euxo pipefail
  EFS_ID="$EFS_ID"
  sudo dnf -y install amazon-efs-utils
  sudo mkdir -p /var/www/html
  sudo mount -t efs -o tls \${EFS_ID}:/ /var/www/html || true
  grep -q "\${EFS_ID}:" /etc/fstab || echo "\${EFS_ID}:/ /var/www/html efs _netdev,tls 0 0" | sudo tee -a /etc/fstab
  echo "from-ec2-1" | sudo tee /var/www/html/.probe
  df -h | grep "\$EFS_ID" || true
  ls -la /var/www/html/.probe || true
EOF

echo -e "\n✅ KLART steg 0–3."
echo "------------------------------------------------------------"
echo "Surfa till:  http://$EC2_PUBLIC_IP  (WordPress-setup)"
echo "EFS-ID:      $EFS_ID"
echo "RDS-endpoint $DB_ENDPOINT"
echo "Titthål:     /var/www/html/.probe på EC2 #1 (ligger på EFS)"
echo "------------------------------------------------------------"
echo "Nästa: kör 'remount-efs.sh' (om du nyss lagt MT), eller 'deploy-step4-6.sh'."