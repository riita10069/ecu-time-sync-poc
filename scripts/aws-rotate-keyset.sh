#!/usr/bin/env bash
# cookie マスター鍵のローテーションを 1 段階進める: add | promote | prune
# Secrets Manager の鍵を更新し、ECS のローリングデプロイで全タスクに読み込ませる
set -euo pipefail
export AWS_REGION=ap-northeast-1
cd "$(dirname "$0")/.."
OP=${1:?add|promote|prune}
ARN=$(terraform -chdir=infra output -raw keyset_secret_arn)
CLUSTER=$(terraform -chdir=infra output -raw cluster)
SERVICE=$(terraform -chdir=infra output -raw service)
tmp=$(mktemp); trap 'rm -f "${tmp}"' EXIT
aws secretsmanager get-secret-value --secret-id "${ARN}" --query SecretString --output text | base64 -d > "${tmp}"
python3 scripts/ntpd-keyset.py "${OP}" "${tmp}"
aws secretsmanager put-secret-value --secret-id "${ARN}" --secret-string "$(base64 < "${tmp}" | tr -d '\n')" --query VersionId --output text
aws ecs update-service --cluster "${CLUSTER}" --service "${SERVICE}" --force-new-deployment --query 'service.deployments[0].id' --output text
echo "waiting for rolling deployment..."
aws ecs wait services-stable --cluster "${CLUSTER}" --services "${SERVICE}"
echo "deployment stable at $(date +%H:%M:%S)"
