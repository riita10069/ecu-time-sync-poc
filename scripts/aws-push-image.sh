#!/usr/bin/env bash
# arm64 イメージを Finch でビルドして ECR に push する
set -euo pipefail
export AWS_REGION=ap-northeast-1
cd "$(dirname "$0")/.."
TAG=${1:-v1}
REPO=$(terraform -chdir=infra output -raw ecr_repository)
aws ecr get-login-password --region ap-northeast-1 | finch login --username AWS --password-stdin "${REPO%%/*}" >/dev/null
finch build --platform linux/arm64 -t "${REPO}:${TAG}" . >/dev/null
finch push "${REPO}:${TAG}" 2>&1 | tail -1
