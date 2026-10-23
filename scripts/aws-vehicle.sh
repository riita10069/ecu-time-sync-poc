#!/usr/bin/env bash
# 車両役のクライアントを Finch コンテナで実行する。引数は app/aws_vehicle.py に渡す
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<PY
import json, subprocess
o = json.loads(subprocess.check_output(["terraform", "-chdir=infra", "output", "-json"]))
host = o["api_url"]["value"].split("/")[2]
json.dump({"api_host": host, "ntp_host": o["ntp_host"]["value"]}, open("out/aws/endpoints.json", "w"))
PY
finch run --rm -v "${PWD}/out/aws:/poc/out/aws:ro" -v "${PWD}/app:/poc/app:ro" ecu-time-sync-poc:latest python3 /poc/app/aws_vehicle.py "$@"
