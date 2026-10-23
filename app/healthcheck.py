"""中継 chrony のディープヘルスチェック。NLB のヘルスチェック (HTTP) から呼ばれる。

200 を返す条件は次をすべて満たすこと。
1. chrony が同期している (Leap status が Not synchronised でない、システム時計のずれ |offset| が閾値以下)
2. インターネットに出られる。NAT Gateway 経由で time.aws.com か time.cloudflare.com の
   どちらかに実際に問い合わせて応答がある。どちらか一方の障害で全タスクが落ちないよう OR にする

3. NTPD_CHECK を指定したとき、その NTP サーバー (同じタスクの ntpd-rs) が応答する。
   ntpd-rs は NTS のない要求に DENY を返すので、平文で送って DENY が返れば生きていると判断する

NLB はヘルスチェックを複数ノードから送るので、外部への問い合わせ結果は CACHE_SEC 秒キャッシュする。
"""
import json
import os
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(__file__))
from timelib import sntp  # noqa: E402

BIND = os.environ.get("BIND", "127.0.0.1")
PORT = int(os.environ.get("PORT", "8080"))
MAX_OFFSET_MS = float(os.environ.get("MAX_OFFSET_MS", "10"))
CACHE_SEC = float(os.environ.get("CACHE_SEC", "5"))
PROBE_TIMEOUT = float(os.environ.get("PROBE_TIMEOUT", "1.0"))
NTPD_CHECK = os.environ.get("NTPD_CHECK")  # 例: 127.0.0.1
LOG_INTERVAL = float(os.environ.get("LOG_INTERVAL", "0"))  # 0 より大きければ状態を定期的に標準出力へ
INTERNET_PROBES = os.environ.get("INTERNET_PROBES", "ntp:time.aws.com,tcp:time.cloudflare.com:4460").split(",")

_lock = threading.Lock()
_cache = {"at": 0.0, "result": None}


def probe(target):
    kind, _, rest = target.partition(":")
    try:
        if kind == "ntp":
            return sntp(rest, samples=1, timeout=PROBE_TIMEOUT) is not None
        if kind == "tcp":
            host, port = rest.rsplit(":", 1)
            with socket.create_connection((host, int(port)), timeout=PROBE_TIMEOUT):
                return True
    except OSError:
        return False
    return False


def internet_ok():
    with _lock:
        if _cache["result"] is not None and time.monotonic() - _cache["at"] < CACHE_SEC:
            return _cache["result"]
        results = {t: probe(t) for t in INTERNET_PROBES}
        _cache.update(at=time.monotonic(), result=results)
        return results


def ntpd_alive():
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.settimeout(PROBE_TIMEOUT)
            s.sendto(b"\x23" + b"\x00" * 47, (NTPD_CHECK, 123))
            data, _ = s.recvfrom(512)
        return data[1] == 0 and data[12:16] == b"DENY"
    except OSError:
        return False


def chrony_tracking():
    out = subprocess.run(["chronyc", "-h", "127.0.0.1", "-c", "tracking"],
                         capture_output=True, text=True, timeout=2)
    f = out.stdout.strip().split(",")
    if out.returncode != 0 or len(f) < 14:
        return None
    # -c tracking: ref_id, ref_name, stratum, ref_time, system_offset(s), last_offset, rms, freq,
    #              resid_freq, skew, root_delay, root_dispersion, update_interval, leap_status
    return {"ref": f[1], "stratum": int(f[2]), "offset_ms": float(f[4]) * 1000, "leap": f[13]}


def evaluate():
    reasons = []
    tr = chrony_tracking()
    if tr is None:
        reasons.append("chronyc unavailable")
    else:
        if tr["leap"] == "Not synchronised":
            reasons.append("chrony not synchronised")
        if abs(tr["offset_ms"]) > MAX_OFFSET_MS:
            reasons.append(f"offset {tr['offset_ms']:.3f} ms > {MAX_OFFSET_MS} ms")
    if NTPD_CHECK and not ntpd_alive():
        reasons.append("ntpd-rs not responding")
    inet = internet_ok()
    if not any(inet.values()):
        reasons.append("internet unreachable (NAT Gateway path down?)")
    return (not reasons), {"healthy": not reasons, "reasons": reasons, "tracking": tr, "internet": inet}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/health":
            self.send_response(404)
            self.end_headers()
            return
        ok, body = evaluate()
        raw = json.dumps(body).encode()
        self.send_response(200 if ok else 503)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def log_message(self, fmt, *args):
        pass


def log_loop():
    while True:
        ok, body = evaluate()
        src = subprocess.run(["chronyc", "-h", "127.0.0.1", "sources"], capture_output=True, text=True).stdout
        print(json.dumps({"health": body}), flush=True)
        print(src, flush=True)
        time.sleep(LOG_INTERVAL)


if LOG_INTERVAL > 0:
    threading.Thread(target=log_loop, daemon=True).start()
print(f"healthcheck listening on {BIND}:{PORT}", flush=True)
ThreadingHTTPServer((BIND, PORT), Handler).serve_forever()
