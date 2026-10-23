#!/usr/bin/env bash
# ntpd-rs の起動。トークン、cookie のマスター鍵、NTS-KE の証明書を用意してから exec する。
#   AWS:    ECS の secrets で POOL_TOKEN, NTPD_KEYSET_B64, NTS_CERT_PEM, NTS_KEY_PEM を受け取る (Secrets Manager)
#   ローカル: /poc/out 以下のファイルを使う
set -euo pipefail
umask 077
if [ -n "${POOL_TOKEN:-}" ]; then
  TOKEN="${POOL_TOKEN}"
  printf '%s' "${NTPD_KEYSET_B64:?}" | base64 -d > /tmp/ntpd-keyset
  printf '%s\n' "${NTS_CERT_PEM:?}" > /tmp/nts-cert.pem
  printf '%s\n' "${NTS_KEY_PEM:?}" > /tmp/nts-key.pem
else
  TOKEN=$(cat /poc/out/keys/pool-token)
  install -m 600 /poc/out/keys/ntpd-keyset /tmp/ntpd-keyset
  cp /poc/out/certs/ntpdrs.pem /tmp/nts-cert.pem
  cp /poc/out/certs/ntpdrs.key /tmp/nts-key.pem
fi
sed -e "s|__POOL_TOKEN__|${TOKEN}|" \
    -e "s|/poc/out/certs/ntpdrs.pem|/tmp/nts-cert.pem|" \
    -e "s|/poc/out/certs/ntpdrs.key|/tmp/nts-key.pem|" \
    /poc/config/ntpd-rs.toml.tmpl > /tmp/ntp.toml
python3 /poc/scripts/ntpd-keyset.py show /tmp/ntpd-keyset
exec ntp-daemon -c /tmp/ntp.toml
