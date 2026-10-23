"""API Gateway (mTLS) で払い出した鍵と cookie がないと NTS の時刻を得られないことを確かめる。"""
import base64
import sys

sys.path.insert(0, "/poc/app")
from nts import ke_fixed_key, ke_standard, nts_query  # noqa: E402
from timelib import mtls_get, sntp  # noqa: E402

CA = "/poc/out/certs/time-ca.pem"


def creds_from_api(cert="VIN001"):
    status, body = mtls_get("/nts-credentials", cert=cert)
    if status != 200:
        return status, None
    d = lambda s: base64.b64decode(s)
    return status, {"server": body["ntp_server"], "port": body["ntp_port"], "c2s": d(body["c2s"]),
                    "s2c": d(body["s2c"]), "cookies": [d(c) for c in body["cookies"]]}


def show(label, value):
    print(f"{label:<52} {value}")


status, creds = creds_from_api()
show("1. VIN001 が API から鍵と cookie を取得", f"HTTP {status}, cookies={len(creds['cookies'])}, ntp={creds['server']}:{creds['port']}")
r = nts_query(creds["server"], creds["port"], creds)
show("2. その cookie で NTS 付き NTP", r)
offsets = []
for _ in range(20):
    r = nts_query(creds["server"], creds["port"], creds)
    offsets.append((r["delay_ms"], r["offset_ms"]))
best = min(offsets)
show("   20 回続けて問い合わせ (cookie は毎回補充)", f"cookies left={len(creds['cookies'])} best delay={best[0]:.3f} ms offset={best[1]:+.3f} ms")

for cert in ("VIN999", "rogue-vehicle", None):
    try:
        st, _ = creds_from_api(cert)
        show(f"3. 証明書 {cert} で API から取得", f"HTTP {st}")
    except Exception as e:
        show(f"3. 証明書 {cert} で API から取得", f"REJECTED {type(e).__name__}")

try:
    show("4. 平文 NTP (SNTP) を ntpd-rs へ", sntp("ntpdrs", samples=1))
except Exception as e:
    show("4. 平文 NTP (SNTP) を ntpd-rs へ", f"{type(e).__name__}: {e}")
import socket, struct  # noqa: E401,E402
with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
    s.settimeout(2)
    s.sendto(b"\x23" + b"\x00" * 47, ("ntpdrs", 123))
    data, _ = s.recvfrom(512)
    show("   応答の stratum と kiss code", f"stratum={data[1]} refid={data[12:16]!r}")

fake = {"c2s": b"\x00" * 32, "s2c": b"\x00" * 32, "cookies": [b"\x00" * len(creds["cookies"][0])]}
show("5. でたらめな cookie で NTS 付き NTP", nts_query("ntpdrs", 123, fake))

try:
    ke_fixed_key("ntpdrs", 4460, CA, "wrong-token")
    show("6. 誤ったトークンで Fixed Key Request", "ACCEPTED (unexpected)")
except Exception as e:
    show("6. 誤ったトークンで Fixed Key Request", f"REJECTED {e}")

show("7. 経路上で時刻を +3600 秒書き換え", nts_query("mitm-nts", 123, creds))

show("8. トークンなしの通常 NTS-KE (4460 に届く場合)", f"cookies issued={ke_standard('ntpdrs', 4460, CA)}")
