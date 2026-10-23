"""車両側のクライアント処理。SNTP 問い合わせと、mTLS API による時刻取得。"""
import http.client
import json
import os
import socket
import ssl
import struct
import time

NTP_EPOCH = 2208988800
CERTS = "/poc/out/certs"


def _to_ntp(ns):
    s, frac = divmod(ns, 1_000_000_000)
    return struct.pack("!II", s + NTP_EPOCH, frac * (1 << 32) // 1_000_000_000)


def _from_ntp(b):
    s, f = struct.unpack("!II", b)
    return (s - NTP_EPOCH) * 1_000_000_000 + f * 1_000_000_000 // (1 << 32)


def sntp(host, samples=8, timeout=2.0):
    """平文 SNTP。戻り値は遅延が最小のサンプルの (offset_ms, delay_ms)。"""
    addr = socket.getaddrinfo(host, 123, socket.AF_INET, socket.SOCK_DGRAM)[0][4]
    best = None
    for _ in range(samples):
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.settimeout(timeout)
            t1 = time.time_ns()
            tx = _to_ntp(t1)
            s.sendto(b"\x23" + b"\x00" * 39 + tx, addr)  # LI=0 VN=4 Mode=3
            data, _ = s.recvfrom(512)
            t4 = time.time_ns()
        if data[1] == 0:  # stratum 0 は kiss-o'-death。時刻として使わない
            raise RuntimeError(f"kiss code {data[12:16].decode(errors='replace')}")
        if data[24:32] != tx:  # origin timestamp が自分の送信時刻と一致しない応答は捨てる
            continue
        t2, t3 = _from_ntp(data[32:40]), _from_ntp(data[40:48])
        off = ((t2 - t1) + (t3 - t4)) / 2e6
        dly = ((t4 - t1) - (t3 - t2)) / 1e6
        if best is None or dly < best[1]:
            best = (off, dly)
        time.sleep(0.2)
    return best


def mtls_context(cert="VIN001"):
    ctx = ssl.create_default_context(cafile=f"{CERTS}/time-ca.pem")
    if cert:
        ctx.load_cert_chain(f"{CERTS}/{cert}.pem", f"{CERTS}/{cert}.key")
    return ctx


def mtls_get(path, cert="VIN001", host="api", port=8443):
    conn = http.client.HTTPSConnection(host, port, context=mtls_context(cert), timeout=5)
    conn.request("GET", path)
    r = conn.getresponse()
    return r.status, json.loads(r.read())


def mtls_time(cert="VIN001", host="api", port=8443, samples=8):
    """mTLS API で 4 タイムスタンプ方式のオフセットを測る。

    戻り値は (初回 offset_ms, 初回 delay_ms, 最良 offset_ms, 最良 delay_ms)。
    初回は TLS ハンドシェイクを含む。2 回目以降は keep-alive 上で測る。
    """
    conn = http.client.HTTPSConnection(host, port, context=mtls_context(cert), timeout=5)
    results = []
    for _ in range(samples):
        t1 = time.time_ns()
        conn.request("GET", "/time")
        r = conn.getresponse()
        body = json.loads(r.read())
        t4 = time.time_ns()
        if r.status != 200:
            raise RuntimeError(f"HTTP {r.status} {body}")
        t2, t3 = body["t2_ns"], body["t3_ns"]
        results.append((((t2 - t1) + (t3 - t4)) / 2e6, ((t4 - t1) - (t3 - t2)) / 1e6))
    first = results[0]
    best = min(results[1:] or results, key=lambda x: x[1])
    return first + best
