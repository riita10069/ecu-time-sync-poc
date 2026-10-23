#!/usr/bin/env bash
# NAT Gateway 障害の再現。指定 AZ の private subnet のデフォルトルートを消し、ターゲットの健全性を観察して戻す
set -euo pipefail
export AWS_REGION=ap-northeast-1
cd "$(dirname "$0")/.."
AZ=${1:-ap-northeast-1a}
HOLD=${2:-90}
RT=$(terraform -chdir=infra output -json private_route_table_ids | python3 -c "import json,sys; print(json.load(sys.stdin)['${AZ}'])")
NAT=$(terraform -chdir=infra output -json nat_gateway_ids | python3 -c "import json,sys; print(json.load(sys.stdin)['${AZ}'])")
TG=$(terraform -chdir=infra output -raw ntp_target_group_arn)
health() { aws elbv2 describe-target-health --target-group-arn "${TG}" \
  --query 'TargetHealthDescriptions[].[Target.Id,Target.AvailabilityZone,TargetHealth.State,TargetHealth.Reason]' --output text | sed "s/^/  $(date +%H:%M:%S) /"; }
echo "before:"; health
aws ec2 delete-route --route-table-id "${RT}" --destination-cidr-block 0.0.0.0/0
echo "$(date +%H:%M:%S) deleted default route in ${AZ} (${RT})"
for _ in $(seq 1 $((HOLD / 10))); do sleep 10; health; done
aws ec2 create-route --route-table-id "${RT}" --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "${NAT}" >/dev/null
echo "$(date +%H:%M:%S) restored default route"
for _ in 1 2 3 4 5 6; do sleep 10; health; done
