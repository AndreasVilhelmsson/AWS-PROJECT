# AWS/WP-infra/scripts/teardown-all.sh
#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/env.sh"

"$(dirname "$0")/teardown-asg.sh"
"$(dirname "$0")/teardown-alb.sh"
"$(dirname "$0")/teardown-storage.sh"

echo "All teardown steps completed. VPC, subnät och key pair lämnades orörda."