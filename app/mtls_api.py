"""API Gateway (mTLS) + Lambda の代役。

GET /time     NTP と同じ 4 タイムスタンプ方式で使う t2 (受信) と t3 (送信) を返す
GET /ntp-key  認証された車両に、その車両の対称鍵 NTP の鍵を返す
GET /nts-credentials  認証された車両の代わりに ntpd-rs と NTS-KE を行い、鍵と cookie を返す

クライアント証明書の検証 (認証) は TLS 層で行い、車両台帳に CN があるかの確認 (認可) は
ハンドラーで行う。API Gateway では truststore による mTLS と Lambda authorizer の分担に相当する。
"""
import base64
import json
import os
import socket
import ssl
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from nts import ke_fixed_key

BIND = os.environ.get("BIND", "127.0.0.1")
PORT = int(os.environ.get("PORT", "8443"))
CERTS = "/poc/out/certs"
REGISTRY = json.load(open("/poc/out/keys/registry.json"))
REGISTERED_VEHICLES = set(REGISTRY)  # 台帳。VIN999 は証明書は正規だが未登録
NTS_KE_HOST = os.environ.get("NTS_KE_HOST", "ntpdrs")
NTS_NTP_HOST = os.environ.get("NTS_NTP_HOST", "ntpdrs")  # 本番は NLB の AZ ごとの EIP
POOL_TOKEN_FILE = "/poc/out/keys/pool-token"  # 本番は Secrets Manager


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"  # keep-alive で TLS ハンドシェイクを 1 回にする

    def setup(self):
        super().setup()
        # ヘッダーと本文が別セグメントになるため、Nagle と遅延 ACK で応答が約 40 ms 遅れる。
        # 片道だけの遅延はオフセット誤差になるので無効にする
        self.connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

    def _cn(self):
        cert = self.connection.getpeercert()
        for rdn in cert.get("subject", ()):
            for k, v in rdn:
                if k == "commonName":
                    return v
        return None

    def _send(self, code, body):
        raw = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        t2 = time.time_ns()
        cn = self._cn()
        if cn not in REGISTERED_VEHICLES:
            return self._send(403, {"error": "vehicle not registered", "cn": cn})
        if self.path == "/time":
            return self._send(200, {"t2_ns": t2, "t3_ns": time.time_ns()})
        if self.path == "/ntp-key":
            return self._send(200, REGISTRY[cn])
        if self.path == "/nts-credentials":
            token = open(POOL_TOKEN_FILE).read().strip()
            r = ke_fixed_key(NTS_KE_HOST, 4460, f"{CERTS}/time-ca.pem", token)
            b64 = lambda b: base64.b64encode(b).decode()
            return self._send(200, {
                "ntp_server": r["server"] or NTS_NTP_HOST, "ntp_port": r["port"] or 123,
                "aead": r["aead"], "c2s": b64(r["c2s"]), "s2c": b64(r["s2c"]),
                "cookies": [b64(c) for c in r["cookies"]],
            })
        return self._send(404, {"error": "not found"})

    def log_message(self, fmt, *args):
        pass


ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.minimum_version = ssl.TLSVersion.TLSv1_2
ctx.load_cert_chain(f"{CERTS}/api.pem", f"{CERTS}/api.key")
ctx.load_verify_locations(f"{CERTS}/vehicle-ca.pem")
ctx.verify_mode = ssl.CERT_REQUIRED  # クライアント証明書なしは TLS ハンドシェイクで拒否

srv = ThreadingHTTPServer((BIND, PORT), Handler)
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
print(f"mtls api listening on {BIND}:{PORT}", flush=True)
srv.serve_forever()
