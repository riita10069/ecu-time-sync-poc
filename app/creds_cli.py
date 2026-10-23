"""車両役の補助。API から取得した鍵と cookie を /tmp に保存し、指定のサーバーに NTS で問い合わせる。

  fetch NAME            API から取得して保存
  query NAME HOST [N]   HOST に N 回問い合わせ (NTSN なら次の cookie で再送、尽きたら API から取り直す)
  ids NAME              手持ち cookie の鍵 ID
"""
import base64
import pickle
import struct
import sys

sys.path.insert(0, "/poc/app")
from nts import nts_query  # noqa: E402
from timelib import mtls_get  # noqa: E402



def fetch():
    status, b = mtls_get("/nts-credentials")
    d = base64.b64decode
    return status, {"c2s": d(b["c2s"]), "s2c": d(b["s2c"]), "cookies": [d(c) for c in b["cookies"]], "refetched": 0}


def robust_query(host, creds):
    """車両側の作法。NTSN を受けたらその cookie を捨てて次で再送し、尽きたら API から取り直す。"""
    while True:
        if not creds["cookies"]:
            _, fresh = fetch()
            creds.update(fresh, refetched=creds["refetched"] + 1)
        r = nts_query(host, 123, creds)
        if r["ok"] or r.get("kiss") != "NTSN":
            return r


cmd, name = sys.argv[1], sys.argv[2]
path = f"/tmp/creds-{name}.pkl"
if cmd == "fetch":
    status, creds = fetch()
    pickle.dump(creds, open(path, "wb"))
    print(f"fetch {name}: HTTP {status} cookie_key_ids={sorted({struct.unpack('!I', c[:4])[0] for c in creds['cookies']})}")
else:
    creds = pickle.load(open(path, "rb"))
    if cmd == "query":
        host, n = sys.argv[3], int(sys.argv[4]) if len(sys.argv) > 4 else 4
        res = [robust_query(host, creds) for _ in range(n)]
        ok = sum(r["ok"] for r in res)
        bad = [r.get("kiss") or r.get("error") for r in res if not r["ok"]]
        pickle.dump(creds, open(path, "wb"))
        print(f"query {name} -> {host}: ok={ok}/{n} {bad if bad else ''}refetched_from_api={creds['refetched']} "
              f"cookie_key_ids={sorted({struct.unpack('!I', c[:4])[0] for c in creds['cookies']})}")
