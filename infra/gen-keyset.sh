#!/usr/bin/env bash
# terraform の external データソース用。初回の cookie マスター鍵を作り {"b64": "..."} を返す。
# 鍵の secret version は ignore_changes なので、使われるのは最初の作成時だけ
set -euo pipefail
tmp=$(mktemp)
trap 'rm -f "${tmp}"' EXIT
python3 "$(dirname "$0")/../scripts/ntpd-keyset.py" new "${tmp}" >/dev/null
printf '{"b64":"%s"}' "$(base64 < "${tmp}" | tr -d '\n')"
