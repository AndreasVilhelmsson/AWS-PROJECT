# Tutorial: WordPress Deployment på AWS med CloudFormation

## Introduktion

Denna rapport beskriver hur man steg för steg byggde upp en **WordPress-miljö på AWS** med hjälp av _Infrastructure as Code_ (IaC) via **CloudFormation**.  
Jag kommer att redovisa alla steg, inklusive fel som uppstod och hur man löste löstes. Rapporten fungerar som en tutorial som går att följa för att själv sätta upp en liknande miljö.

## Metod

Mitt mål var att lära mig så mycket som möjligt om de metoder som finns för att
lösa uppgiften. Jag har gjort övningsuppgifter i konsolen och anvönde den som referens för att köra nästa steg vilket var att försöka lösa det med Cloudformation dels med hjälp av att ladda upp filer via konsolen och via terminalen aws CLI

---

## Översiktlig arkitektur

Miljön består av följande komponenter:

- **VPC**: En virtuell nätverksmiljö i AWS (här `vpc-0293dde1c8b69bca7`).
- **Subnets**: Två publika subnät (för webbservrar) och två privata (för databas och EFS).
- **Security Groups (SG)**: Styr trafiken mellan komponenterna (t.ex. ALB → EC2).
- **Application Load Balancer (ALB)**: Fördelar HTTP-trafik till webbservrar.
- **Auto Scaling Group (ASG)**: Skalar EC2-instanser automatiskt upp/ned.
- **Launch Template (LT)**: Beskriver hur varje EC2-instans konfigureras.
- **RDS (MySQL)**: Databas för WordPress.
- **EFS (Elastic File System)**: Delad filyta mellan alla webbinstanser.
- **S3 bucket**: För backup och lagring av statiska filer.

![Cloudcraft Arkitektur](images/securitydiagram.jpg)

---

## Ordning för att bygga miljön

När man bygger upp infrastrukturen är det viktigt att ta det i rätt ordning, eftersom resurserna är beroende av varandra:

1. **Storage och nätverk**

   - Skapa VPC, subnät, security groups, RDS och EFS.
   - CloudFormation-mall: `templates/base-storage.yaml`

2. **Launch Template (LT)**

   - Skapa en AMI eller ange en bas-AMI (Amazon Linux 2023).
   - Beskriv hur EC2-instanser ska konfigureras.
   - CloudFormation-mall: `templates/web-lt.yaml`

3. **Application Load Balancer (ALB)**

   - Sätt upp en ALB som tar emot trafik på port 80.
   - Koppla den till target group.
   - CloudFormation-mall: `templates/web-alb.yaml`

   <!-- IMAGE: ALB → Target Groups diagram -->

4. **Auto Scaling Group (ASG)**

   - Skapa en ASG som använder Launch Template och ALB target group.
   - CloudFormation-mall: `templates/web-asg.yaml`

   <!-- IMAGE: ASG och instanser -->

5. **Verifiera WordPress-installation**

   - Öppna DNS för ALB (`wp-alb-xxxx.eu-west-1.elb.amazonaws.com`).
   - WordPress-installationen startar.

   <!-- IMAGE: WordPress setup screenshot -->

---

## Filer som skapades

### Templates (`WP-infra/templates/`)

- `base-storage.yaml`
- `web-lt.yaml`
- `web-alb.yaml`
- `web-asg.yaml`
- `web-sg.yaml`

### Scripts (`WP-infra/scripts/`)

- `env.build.sh` – export av miljövariabler.
- `deploy.sh` – huvudscript för att deploya allt.
- `teardown-*.sh` – script för att ta ner resurser.
- `validate.sh` – kontroll av mallar.
- `up-*.sh` / `down-*.sh` – manuella varianter för specifika resurser.

### Extra (valfria)

- `promote-golden-ami.sh` – för att spara en färdig AMI.
- `remount-efs.sh` – för att återmontera EFS på instanser.

---

## Vanliga fel och lösningar

Under arbetets gång uppstod flera problem som vi löste steg för steg:

- **SubnetBId does not exist**  
  → Orsak: En variabel var tom (`$SUBNET_PUBLIC_B`).  
  → Lösning: Uppdatera `env.build.sh` med korrekt script för att plocka två subnät.

- **Template format error**  
  → Orsak: YAML-formatfel.  
  → Lösning: Validera alltid mallar med `validate.sh` innan deployment.

- **Unhealthy targets i Target Group**  
  → Orsak: Några instanser svarade inte på health checks.  
  → Lösning: Terminera instansen via ASG (ersätts automatiskt).

- **Bash-terminal kraschar pga BOM**  
  → Orsak: `env.build.sh` innehöll dolda tecken (UTF-8 BOM).  
  → Lösning: Rensa filen med `perl -i -pe 's/\x{feff}//g' fil.sh`.

---

## Masterfil för one-click deployment

För att slippa köra varje script manuellt skapades en **masterfil**:

```bash
#!/bin/bash
set -euo pipefail

# 1. Ladda miljövariabler
source scripts/env.build.sh

# 2. Deploy storage
aws cloudformation deploy --stack-name base-storage --template-file templates/base-storage.yaml

# 3. Deploy launch template
aws cloudformation deploy --stack-name web-lt --template-file templates/web-lt.yaml

# 4. Deploy ALB
aws cloudformation deploy --stack-name web-alb --template-file templates/web-alb.yaml   --parameter-overrides VpcId="$VPC_ID" SubnetAId="$SUBNET_PUBLIC" SubnetBId="$SUBNET_PUBLIC_B"

# 5. Deploy ASG
aws cloudformation deploy --stack-name web-asg-ec2hc --template-file templates/web-asg.yaml   --parameter-overrides SubnetAId="$SUBNET_PUBLIC" SubnetBId="$SUBNET_PUBLIC_B"     LaunchTemplateId="$LT_ID" LaunchTemplateVersion="$LT_VER" TargetGroupArn="$TG_ARN"
```

---

## Slutsats

Genom att använda **CloudFormation** och **bashscript** lyckades vi automatisera hela flödet för att sätta upp en WordPress-miljö i AWS.  
Arbetet gav oss praktisk erfarenhet av:

- Infrastructure as Code (IaC).
- Att felsöka CloudFormation-fel.
- Att strukturera templates och script för återanvändbarhet.
- Att använda Auto Scaling + ALB för hög tillgänglighet.

![Cloudcraft Arkitektur](images/infrastructurediagram.jpg)

---
