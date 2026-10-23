"""AWS 上の環境に対する車両役のクライアント。finch のコンテナ内で動かす (out/aws の証明書をマウント)。

  check                 認証の拒否確認と、NTS 付き NTP の精度・タスク間の cookie 互換性の確認
  loop SECONDS INTERVAL 一定間隔で NTS 付き NTP を送り続け、失敗を記録する (ローテーションや障害試験の最中に回す)
"""
import base64
import http.client
import json
import socket
import ssl
import sys
import os
import time

POC = os.environ.get("POC_DIR", "/poc")
sys.path.insert(0, f"{POC}/app")
from nts import nts_query  # noqa: E402
from timelib import sntp  # noqa: E402

API_HOST = sys.argv[2] if len(sys.argv) > 2 and sys.argv[1] == "check" else None
CERTS = f"{POC}/out/aws"
CFG = json.load(open(f"{CERTS}/endpoints.json"))


def api_get(cert):
    ctx = ssl.create_default_context()
    if cert:
        ctx.load_cert_chain(f"{CERTS}/{cert}.pem", f"{CERTS}/{cert}.key")
    conn = http.client.HTTPSConnection(CFG["api_host"], 443, context=ctx, timeout=10)
    conn.request("GET", "/nts-credentials")
    r = conn.getresponse()
    return r.status, json.loads(r.read() or b"{}")


def fetch():
    status, b = api_get("VIN001")
    if status != 200:
        raise RuntimeError(f"API {status} {b}")
    d = base64.b64decode
    return {"c2s": d(b["c2s"]), "s2c": d(b["s2c"]), "cookies": [d(c) for c in b["cookies"]],
            "server": b["ntp_server"], "refetched": 0}


def robust_query(creds):
    """NTSN ならその cookie を捨てて次で再送し、尽きたら API から取り直す。"""
    for _ in range(10):
        if not creds["cookies"]:
            creds.update(fetch(), refetched=creds["refetched"] + 1)
        try:
            r = nts_query(creds["server"], 123, creds, timeout=1.0)
        except OSError as e:
            r = {"ok": False, "error": type(e).__name__}
        if r["ok"] or r.get("kiss") != "NTSN":
            return r
    return r


def show(label, value):
    print(f"{label:<46} {value}", flush=True)


def check():
    for cert in (None, "VIN999"):
        try:
            show(f"API 証明書={cert}", api_get(cert))
        except Exception as e:
            show(f"API 証明書={cert}", f"REJECTED {type(e).__name__}: {e}")
    try:
        show("平文 NTP -> 公開 NLB", sntp(CFG["ntp_host"], samples=1))
    except Exception as e:
        show("平文 NTP -> 公開 NLB", f"{type(e).__name__}: {e}")
    try:
        socket.create_connection((CFG["ntp_host"], 4460), timeout=3).close()
        show("NTS-KE TCP 4460 -> 公開 NLB", "REACHABLE (unexpected)")
    except OSError as e:
        show("NTS-KE TCP 4460 -> 公開 NLB", f"unreachable ({type(e).__name__})")
    fake = {"c2s": b"\0" * 32, "s2c": b"\0" * 32, "cookies": [b"\0" * 100]}
    show("でたらめな cookie -> 公開 NLB", nts_query(CFG["ntp_host"], 123, fake))

    creds = fetch()
    show("VIN001 で API から取得", f"cookies={len(creds['cookies'])} server={creds['server']}")
    res = []
    for _ in range(60):  # 毎回新しいソケット (送信元ポート) なので NLB は別のタスクに振り分けうる
        res.append(robust_query(creds))
        time.sleep(0.1)
    ok = [r for r in res if r["ok"]]
    show("NTS 付き NTP 60 回", f"ok={len(ok)}/60 refetched_from_api={creds['refetched']} "
         f"errors={[r.get('kiss') or r.get('error') for r in res if not r['ok']]}")
    best = min(ok, key=lambda r: r["delay_ms"])
    show("  遅延最小のサンプル", f"offset={best['offset_ms']:+.3f} ms delay={best['delay_ms']:.3f} ms stratum={best['stratum']}")
    a = sntp("time.aws.com", samples=8)
    show("比較: time.aws.com (平文 SNTP 8 回の最良)", f"offset={a[0]:+.3f} ms delay={a[1]:.3f} ms")
    show("  差 (自前サーバー - time.aws.com)", f"{best['offset_ms'] - a[0]:+.3f} ms")


def loop(seconds, interval):
    creds = fetch()
    end = time.time() + seconds
    n = fails = 0
    while time.time() < end:
        r = robust_query(creds)
        n += 1
        if not r["ok"]:
            fails += 1
            print(f"{time.strftime('%H:%M:%S')} FAIL {r}", flush=True)
        if n % 50 == 0:
            print(f"{time.strftime('%H:%M:%S')} sent={n} fails={fails} refetched={creds['refetched']} "
                  f"last_offset={r.get('offset_ms', float('nan')):+.3f} ms", flush=True)
        time.sleep(interval)
    print(f"DONE sent={n} fails={fails} refetched={creds['refetched']}", flush=True)


if __name__ == "__main__":
    if sys.argv[1] == "check":
        check()
    else:
        loop(float(sys.argv[2]), float(sys.argv[3]))
