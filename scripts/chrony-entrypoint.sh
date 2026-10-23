#!/usr/bin/env bash
# タスク内の chrony。時計は動かさず (-x)、システム時計と真の時刻のずれを測る。
# ntpd-rs はシステム時計をそのまま配るので、ヘルスチェックはこのずれで判定する。
set -euo pipefail
CONF=/tmp/chrony.conf
: > "${CONF}"
for dev in /dev/ptp_ena /dev/ptp0; do
  if [ -e "${dev}" ]; then
    name=$(cat "/sys/class/ptp/$(basename "$(readlink -f "${dev}")")/clock_name" 2>/dev/null || echo unknown)
    echo "PHC device ${dev} found (clock_name=${name})"
    case "${name}" in
      ena-ptp-*) echo "refclock PHC ${dev} poll 0 delay 0.000010 prefer" >> "${CONF}" ;;
      *) echo "skip ${dev}: not an ENA PHC" ;;
    esac
    break
  fi
done
grep -q refclock "${CONF}" || echo "PHC not available, using link-local NTP only"
cat >> "${CONF}" <<'CONF'
# Local Amazon Time Sync Service
server 169.254.169.123 prefer iburst minpoll 4 maxpoll 4
# Public Amazon Time Sync Service (NAT Gateway 経由)
pool time.aws.com iburst maxsources 2
# 認証付きの外部時刻源 (NAT Gateway 経由)
server time.cloudflare.com iburst nts
minsources 2
bindcmdaddress 127.0.0.1
cmdallow 127.0.0.1
# NTP サーバーとしては動かさない (配信は ntpd-rs)
port 0
ntsdumpdir /tmp/chrony-nts
CONF
cat "${CONF}"
exec chronyd -d -x -u root -f "${CONF}"
