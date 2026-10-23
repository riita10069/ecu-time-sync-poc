"""Python で実装したシナリオ。run-all.sh から呼ぶ。"""
import socket
import ssl
import sys

from timelib import mtls_get, mtls_time, sntp

THRESHOLD_MS = 1000  # ハイブリッド方式で許容する NTP と mTLS 時刻のずれ


def ntske_probe(host):
    """NTS-KE (TCP 4460, ALPN ntske/1) に TLS で接続できるかだけを見る。"""
    ctx = ssl.create_default_context()
    ctx.set_alpn_protocols(["ntske/1"])
    try:
        with socket.create_connection((host, 4460), timeout=5) as s:
            with ctx.wrap_socket(s, server_hostname=host) as t:
                return f"OK tls={t.version()} alpn={t.selected_alpn_protocol()}"
    except Exception as e:
        return f"NG {type(e).__name__}: {e}"


def main(cmd, *args):
    if cmd == "ntske-probe":
        for h in args:
            print(f"{h}:4460 -> {ntske_probe(h)}")
    elif cmd == "sntp":
        off, dly = sntp(args[0])
        print(f"sntp {args[0]}: offset={off:+.3f} ms delay={dly:.3f} ms")
    elif cmd == "mtls-time":
        cert = args[0] if args else "VIN001"
        try:
            f_off, f_dly, b_off, b_dly = mtls_time(cert=None if cert == "none" else cert)
            print(f"mtls /time cert={cert}: first(offset={f_off:+.3f} ms delay={f_dly:.3f} ms) "
                  f"best(offset={b_off:+.3f} ms delay={b_dly:.3f} ms)")
        except Exception as e:
            print(f"mtls /time cert={cert}: REJECTED {type(e).__name__}: {e}")
    elif cmd == "fetch-key":
        status, body = mtls_get("/ntp-key")
        if status != 200:
            sys.exit(f"fetch-key failed {status} {body}")
        with open("/tmp/vehicle.keys", "w") as f:
            f.write(f'{body["key_id"]} {body["algo"]} HEX:{body["key_hex"]}\n')
        print(body["key_id"])
    elif cmd == "hybrid":
        # 精度は NTP から、正しさの担保は mTLS 時刻から取る
        ntp_host = args[0]
        n_off, n_dly = sntp(ntp_host)
        _, _, m_off, m_dly = mtls_time()
        diff = abs(n_off - m_off)
        verdict = "ACCEPT ntp" if diff <= THRESHOLD_MS else "REJECT ntp, fallback to mtls time"
        print(f"hybrid ntp={ntp_host} ntp_offset={n_off:+.3f} ms mtls_offset={m_off:+.3f} ms "
              f"diff={diff:.3f} ms -> {verdict}")


if __name__ == "__main__":
    main(*sys.argv[1:])
