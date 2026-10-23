"""NTS (RFC 8915) と NTS pool 拡張 (draft-ietf-ntp-nts-keyexchange-pool-01) の最小実装。

ke_fixed_key()  Lambda 側。トークンと、自分で生成した C2S/S2C 鍵を Fixed Key Request で送り、cookie を受け取る
ke_standard()   トークンなしの通常の NTS-KE (4460 を公開してはいけない理由の確認用)
nts_query()     車両側。受け取った鍵と cookie で NTS 付き NTP を 1 往復する
"""
import os
import socket
import ssl
import struct
import time


AEAD_AES_SIV_CMAC_256 = 15
KEY_LEN = 32
CRIT = 0x8000
REC_EOM, REC_NEXT_PROTO, REC_ERROR, REC_WARNING, REC_AEAD, REC_COOKIE, REC_SERVER, REC_PORT = 0, 1, 2, 3, 4, 5, 6, 7
REC_FIXED_KEY, REC_AUTH_TOKEN = 12, 14
EF_UID, EF_COOKIE, EF_PLACEHOLDER, EF_AUTH = 0x0104, 0x0204, 0x0304, 0x0404
NTP_EPOCH = 2208988800


class AESSIV:
    """AES-SIV (RFC 5297)。Debian bookworm の cryptography 38 は平文が空の暗号化に失敗するので自前で持つ。
    NTS のリクエストは暗号化する拡張フィールドがなく、平文が空になる。"""

    def __init__(self, key):
        # Lambda (鍵交換だけを行う) では cryptography を使わないので、ここで import する
        global Cipher, algorithms, modes, CMAC
        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
        from cryptography.hazmat.primitives.cmac import CMAC
        n = len(key) // 2
        self.k1, self.k2 = key[:n], key[n:]

    def _cmac(self, data):
        c = CMAC(algorithms.AES(self.k1))
        c.update(data)
        return c.finalize()

    @staticmethod
    def _dbl(b):
        v = int.from_bytes(b, "big") << 1
        if v >> 128:
            v = (v ^ 0x87) & ((1 << 128) - 1)
        return v.to_bytes(16, "big")

    @staticmethod
    def _xor(a, b):
        return bytes(x ^ y for x, y in zip(a, b))

    def _s2v(self, ads, p):
        d = self._cmac(b"\x00" * 16)
        for ad in ads:
            d = self._xor(self._dbl(d), self._cmac(ad))
        if len(p) >= 16:
            t = p[:-16] + self._xor(p[-16:], d)
        else:
            padded = p + b"\x80" + b"\x00" * (15 - len(p))
            t = self._xor(self._dbl(d), padded)
        return self._cmac(t)

    def _ctr(self, v, data):
        q = (int.from_bytes(v, "big") & ~((1 << 63) | (1 << 31))).to_bytes(16, "big")
        e = Cipher(algorithms.AES(self.k2), modes.CTR(q)).encryptor()
        return e.update(data) + e.finalize()

    def encrypt(self, plaintext, ads):
        v = self._s2v(ads, plaintext)
        return v + self._ctr(v, plaintext)

    def decrypt(self, ciphertext, ads):
        v, c = ciphertext[:16], ciphertext[16:]
        p = self._ctr(v, c)
        if self._s2v(ads, p) != v:
            raise ValueError("AES-SIV authentication failed")
        return p


def _rec(rtype, body=b"", critical=False):
    return struct.pack("!HH", rtype | (CRIT if critical else 0), len(body)) + body


def _ke_request(extra=b""):
    return (_rec(REC_NEXT_PROTO, struct.pack("!H", 0), True)
            + _rec(REC_AEAD, struct.pack("!H", AEAD_AES_SIV_CMAC_256))
            + extra
            + _rec(REC_EOM, critical=True))


def _ke_exchange(host, port, cafile, payload, sni=None):
    ctx = ssl.create_default_context(cafile=cafile)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_3
    ctx.set_alpn_protocols(["ntske/1"])
    with socket.create_connection((host, port), timeout=5) as s, ctx.wrap_socket(s, server_hostname=sni or host) as t:
        t.sendall(payload)
        buf = b""
        while True:
            chunk = t.recv(65536)
            if not chunk:
                break
            buf += chunk
            if _has_eom(buf):
                break
        return _parse_records(buf)


def _has_eom(buf):
    try:
        return any(r[0] == REC_EOM for r in _parse_records(buf))
    except ValueError:
        return False


def _parse_records(buf):
    out, i = [], 0
    while i < len(buf):
        if i + 4 > len(buf):
            raise ValueError("truncated")
        rtype, ln = struct.unpack_from("!HH", buf, i)
        if i + 4 + ln > len(buf):
            raise ValueError("truncated")
        out.append((rtype & ~CRIT, buf[i + 4:i + 4 + ln]))
        i += 4 + ln
    return out


def _result(records, c2s, s2c):
    errors = [struct.unpack("!H", b)[0] for t, b in records if t == REC_ERROR]
    if errors:
        raise RuntimeError(f"NTS-KE error code {errors}")
    cookies = [b for t, b in records if t == REC_COOKIE]
    server = next((b.decode() for t, b in records if t == REC_SERVER), None)
    port = next((struct.unpack("!H", b)[0] for t, b in records if t == REC_PORT), None)
    return {"aead": AEAD_AES_SIV_CMAC_256, "c2s": c2s, "s2c": s2c, "cookies": cookies, "server": server, "port": port}


def ke_fixed_key(host, port, cafile, token, sni=None):
    """Lambda の役。鍵を自分で作り、トークン付きの Fixed Key Request で cookie を受け取る。"""
    c2s, s2c = os.urandom(KEY_LEN), os.urandom(KEY_LEN)
    extra = _rec(REC_AUTH_TOKEN, token.encode()) + _rec(REC_FIXED_KEY, c2s + s2c, True)
    records = _ke_exchange(host, port, cafile, _ke_request(extra), sni)
    return _result(records, c2s, s2c)


def ke_standard(host, port, cafile):
    """RFC 8915 どおりの、トークンなしの NTS-KE。発行された cookie の数だけ返す。
    鍵は TLS exporter から導出するが、Python 3.11 の ssl には exporter がないのでここでは導出しない。"""
    records = _ke_exchange(host, port, cafile, _ke_request())
    return len([b for t, b in records if t == REC_COOKIE])


def _ef(etype, body):
    pad = (-len(body)) % 4
    return struct.pack("!HH", etype, 4 + len(body) + pad) + body + b"\x00" * pad


def _parse_efs(buf):
    out, i = [], 0
    while i + 4 <= len(buf):
        etype, ln = struct.unpack_from("!HH", buf, i)
        if ln < 4 or i + ln > len(buf):
            break
        out.append((etype, buf[i + 4:i + ln], i))
        i += ln
    return out


def _ntp_ts(ns):
    s, frac = divmod(ns, 1_000_000_000)
    return struct.pack("!II", s + NTP_EPOCH, frac * (1 << 32) // 1_000_000_000)


def _from_ntp(b):
    s, f = struct.unpack("!II", b)
    return (s - NTP_EPOCH) * 1_000_000_000 + f * 1_000_000_000 // (1 << 32)


def nts_query(host, port, creds, want_cookies=1, timeout=2.0):
    """NTS 付き NTP を 1 往復する。戻り値は dict。creds["cookies"] から 1 個使い、新しい cookie を足す。"""
    cookie = creds["cookies"].pop(0)
    uid = os.urandom(32)
    t1 = time.time_ns()
    header = b"\x23" + b"\x00" * 39 + _ntp_ts(t1)
    efs = _ef(EF_UID, uid) + _ef(EF_COOKIE, cookie)
    for _ in range(want_cookies - 1):
        efs += _ef(EF_PLACEHOLDER, b"\x00" * len(cookie))
    nonce = os.urandom(16)
    ad = header + efs
    ct = AESSIV(creds["c2s"]).encrypt(b"", [ad, nonce])
    auth_body = struct.pack("!HH", len(nonce), len(ct)) + nonce + ct
    pkt = ad + _ef(EF_AUTH, auth_body)

    addr = socket.getaddrinfo(host, port, socket.AF_INET, socket.SOCK_DGRAM)[0][4]
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.settimeout(timeout)
        s.sendto(pkt, addr)
        data, _ = s.recvfrom(4096)
    t4 = time.time_ns()

    stratum = data[1]
    if stratum == 0:  # kiss-o'-death
        return {"ok": False, "kiss": data[12:16].decode(errors="replace")}
    efs_in = _parse_efs(data[48:])
    got_uid = next((b for t, b, _ in efs_in if t == EF_UID), None)
    auth = next(((b, off) for t, b, off in efs_in if t == EF_AUTH), None)
    if got_uid != uid or auth is None:
        return {"ok": False, "error": "uid mismatch or no authenticator"}
    body, off = auth
    nlen, clen = struct.unpack_from("!HH", body, 0)
    n_in = body[4:4 + nlen]
    c_start = 4 + nlen + ((-nlen) % 4)
    c_in = body[c_start:c_start + clen]
    try:
        plain = AESSIV(creds["s2c"]).decrypt(c_in, [data[:48 + off], n_in])
    except Exception:
        return {"ok": False, "error": "authentication failed (packet tampered or wrong key)"}
    new = [b for t, b, _ in _parse_efs(plain) if t == EF_COOKIE]
    creds["cookies"].extend(new)
    t2, t3 = _from_ntp(data[32:40]), _from_ntp(data[40:48])
    return {"ok": True, "offset_ms": ((t2 - t1) + (t3 - t4)) / 2e6, "delay_ms": ((t4 - t1) - (t3 - t2)) / 1e6,
            "stratum": stratum, "new_cookies": len(new)}
