#!/usr/bin/env bash
# 全シナリオを実行して results.txt に保存する
set -uo pipefail
cd "$(dirname "$0")"
[ -f out/certs/time-ca.pem ] || ./scripts/gen-certs.sh
finch compose up -d --build >/dev/null 2>&1 || { finch compose up -d --build; exit 1; }
sleep 3

ex() { finch compose exec -T client "$@"; }
py() { ex python3 /poc/app/scenario.py "$@"; }

# chronyd -Q で 1 回だけ測定する。時計は変更しない。
# $1 ラベル、$2 以降 chrony.conf の行
chrony_q() {
  local label=$1; shift
  local conf; conf=$(printf '%s\n' "cmdport 0" "pidfile /tmp/q.pid" "ntstrustedcerts /poc/out/certs/time-ca.pem" "ntsdumpdir /tmp/ntsq" "$@")
  local out
  out=$(ex bash -c "rm -rf /tmp/ntsq; printf '%s\n' \"\$0\" > /tmp/q.conf; timeout 25 chronyd -Q -t 15 -u root -f /tmp/q.conf 2>&1" "${conf}")
  local line
  line=$(printf '%s\n' "${out}" | grep -E 'System clock wrong|No suitable source|Timeout|NTS-KE|certificate|Could not' | tail -3 | tr '\n' ' ')
  printf '%-44s %s\n' "${label}" "${line:-$(printf '%s' "${out}" | tail -1)}"
}

{
echo "# run at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo
echo "## 0. 事実確認: public endpoint の NTS-KE"
py ntske-probe time.aws.com time.cloudflare.com

echo
echo "## A. 平文 NTP"
py sntp time.aws.com
chrony_q "A  time.aws.com plain"                     "server time.aws.com iburst"
chrony_q "A  time.aws.com nts"                       "server time.aws.com iburst nts"
chrony_q "ref time.cloudflare.com nts"               "server time.cloudflare.com iburst nts"
chrony_q "A  local plain direct"                     "server timesrv iburst"
chrony_q "A  local plain via MITM(+3600s)"           "server mitm iburst"

echo
echo "## B. NTS (自前 chrony サーバー)"
chrony_q "B  nts direct"                             "server timesrv iburst nts"
chrony_q "B  nts via MITM(+3600s)"                   "server mitm iburst nts"
chrony_q "B  nts rogue server (untrusted CA)"        "server rogue iburst nts"

echo
echo "## C. 対称鍵 NTP (鍵は mTLS API から取得)"
KEYID=$(py fetch-key | tr -d '\r')
echo "fetched key id over mTLS: ${KEYID}"
chrony_q "C  key direct"                             "keyfile /tmp/vehicle.keys" "server timesrv iburst key ${KEYID}"
chrony_q "C  key via MITM(+3600s)"                   "keyfile /tmp/vehicle.keys" "server mitm iburst key ${KEYID}"

echo
echo "## D. mTLS API で時刻取得"
py mtls-time VIN001
py mtls-time VIN999
py mtls-time none
py mtls-time rogue-vehicle
ex python3 -c "
import sys; sys.path.insert(0,'/poc/app')
from timelib import mtls_get
for c in ('VIN001','VIN999'):
    print('/ntp-key', c, mtls_get('/ntp-key', cert=c)[0])"

echo
echo "## E. ハイブリッド (NTP の値を mTLS 時刻で検証)"
py hybrid timesrv
py hybrid mitm
} 2>&1 | grep -v -e "msg=\"Ignoring: \[Extensions\]\"" -e "msg=\"exec failed with exit code" | tee results.txt
