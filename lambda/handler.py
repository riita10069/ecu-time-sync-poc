"""API Gateway (HTTP API, mTLS) から呼ばれる。認証済みの車両に NTS の鍵と cookie を払い出す。

認証は API Gateway のカスタムドメインの mTLS で済んでいる (truststore の車両 CA で検証)。
ここでは証明書の CN が台帳にあるかを確かめ (認可)、ntpd-rs と NTS pool 拡張の Fixed Key Request で cookie を得る。
"""
import base64
import json
import os
import re

import boto3

from nts import ke_fixed_key

KE_HOST = os.environ["KE_HOST"]          # 内部 NLB の DNS 名
KE_SNI = os.environ["KE_SNI"]            # ntpd-rs の NTS-KE 証明書の SAN
NTP_HOST = os.environ["NTP_HOST"]        # 車両が NTS 付き NTP を送る先 (公開 NLB)
TOKEN_SECRET_ARN = os.environ["TOKEN_SECRET_ARN"]
ALLOWED = set(filter(None, os.environ.get("ALLOWED_VEHICLES", "").split(",")))
CAFILE = os.path.join(os.path.dirname(__file__), "nts-ke-ca.pem")

_sm = boto3.client("secretsmanager")
_token = None


def _pool_token():
    global _token
    if _token is None:
        _token = _sm.get_secret_value(SecretId=TOKEN_SECRET_ARN)["SecretString"]
    return _token


def _resp(code, body):
    return {"statusCode": code, "headers": {"content-type": "application/json"}, "body": json.dumps(body)}


def handler(event, context):
    cert = event.get("requestContext", {}).get("authentication", {}).get("clientCert")
    if not cert:
        return _resp(403, {"error": "client certificate required"})
    m = re.search(r"CN=([^,]+)", cert.get("subjectDN", ""))
    cn = m.group(1) if m else None
    if cn not in ALLOWED:
        return _resp(403, {"error": "vehicle not registered", "cn": cn})
    if event.get("rawPath") != "/nts-credentials":
        return _resp(404, {"error": "not found"})
    r = ke_fixed_key(KE_HOST, 4460, CAFILE, _pool_token(), sni=KE_SNI)
    b64 = lambda b: base64.b64encode(b).decode()
    return _resp(200, {
        "vehicle": cn,
        "ntp_server": NTP_HOST, "ntp_port": 123,
        "aead": r["aead"], "c2s": b64(r["c2s"]), "s2c": b64(r["s2c"]),
        "cookies": [b64(c) for c in r["cookies"]],
    })
