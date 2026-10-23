#!/usr/bin/env bash
# PoC 用の CA と証明書、対称鍵を out/ に生成する。本番では車両 PKI と Secrets Manager 等を使う。
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=out/certs
mkdir -p "${OUT}" out/keys
cd "${OUT}"

ca() { # name subject
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout "$1.key" -out "$1.pem" -days 30 -subj "/CN=$2" 2>/dev/null
}
leaf() { # name ca cn san eku
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout "$1.key" -out "$1.csr" -subj "/CN=$3" 2>/dev/null
  printf 'subjectAltName=%s\nextendedKeyUsage=%s\n' "$4" "$5" > "$1.ext"
  openssl x509 -req -in "$1.csr" -CA "$2.pem" -CAkey "$2.key" -CAcreateserial \
    -out "$1.pem" -days 7 -extfile "$1.ext" 2>/dev/null
  rm -f "$1.csr" "$1.ext"
}

# サーバー側 CA。NTS-KE と API のサーバー証明書を発行する
ca time-ca "PoC Time Server CA"
# 経路上の攻撃者は IP レベルで透過的という想定なので、mitm 経由の名前も SAN に含める
leaf timesrv time-ca timesrv "DNS:timesrv,DNS:mitm" serverAuth
leaf api time-ca api "DNS:api" serverAuth
leaf ntpdrs time-ca ntpdrs "DNS:ntpdrs" serverAuth

# 車両 CA。既存の車両証明書の代役
ca vehicle-ca "PoC Vehicle CA"
leaf VIN001 vehicle-ca VIN001 "DNS:VIN001" clientAuth
leaf VIN999 vehicle-ca VIN999 "DNS:VIN999" clientAuth   # 証明書は正規だが登録台帳にない車両

# 攻撃者の CA と、それで発行した偽サーバー証明書と偽車両証明書
ca rogue-ca "Rogue CA"
leaf rogue rogue-ca rogue "DNS:rogue" serverAuth
leaf rogue-vehicle rogue-ca VIN001 "DNS:VIN001" clientAuth

# コンテナ内の chronyd が読めるように緩める。PoC 限定
chmod 644 ./*.key
cd ../..

# 対称鍵 NTP の鍵。車両ごとに鍵 ID と鍵を払い出し、chrony の keyfile と API の台帳に書く
python3 - <<'PY'
import json, secrets
registry = {"VIN001": {"key_id": 1001, "algo": "SHA256", "key_hex": secrets.token_hex(32)}}
with open("out/keys/registry.json", "w") as f:
    json.dump(registry, f, indent=2)
with open("out/keys/chrony.keys", "w") as f:
    for v in registry.values():
        f.write(f'{v["key_id"]} {v["algo"]} HEX:{v["key_hex"]}\n')
PY
# NTS pool 拡張の認証トークン。Lambda と ntpd-rs だけが知る。本番は Secrets Manager に置く
python3 -c "import secrets; print(secrets.token_urlsafe(32))" > out/keys/pool-token
# ntpd-rs の全タスクで共有する cookie のマスター鍵
python3 scripts/ntpd-keyset.py new out/keys/ntpd-keyset >/dev/null
chmod 644 out/keys/*
echo "generated: $(ls out/certs | wc -l | tr -d ' ') cert files, $(wc -l < out/keys/chrony.keys | tr -d ' ') ntp keys"
