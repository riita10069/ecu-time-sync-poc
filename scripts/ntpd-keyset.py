"""ntpd-rs 1.9.0 の cookie マスター鍵ファイル (key-storage-path) を作る・更新する。

全タスクに同じファイルを配れば、どのタスクが出した cookie もどのタスクで検証できる。
形式は ntp-proto/src/keyset.rs の store/load に合わせた非公開の内部形式なので、ntpd-rs の版を固定して使う。
  ヘッダー 20 バイト: 保存時刻 u64, id_offset u32, primary u32, 鍵の数 u32 (すべて big-endian)
  続いて 64 バイトの AES-SIV-CMAC-512 鍵を鍵の数だけ

使い方 (本番では出力を Secrets Manager に入れる)
  new     PATH            鍵 1 本で新規作成
  add     PATH            新しい鍵を末尾に足す。primary は変えない (ローテーション段階 1)
  promote PATH            末尾の鍵を primary にする (段階 2)
  prune   PATH            primary より前の鍵を捨てる (段階 3)
  show    PATH
"""
import os
import struct
import sys
import time

HDR = "!QIII"


def load(path):
    b = open(path, "rb").read()
    ts, off, primary, n = struct.unpack_from(HDR, b)
    keys = [b[20 + i * 64:20 + (i + 1) * 64] for i in range(n)]
    return off, primary, keys


def store(path, off, primary, keys):
    with open(path, "wb") as f:
        f.write(struct.pack(HDR, int(time.time()), off, primary, len(keys)) + b"".join(keys))


cmd, path = sys.argv[1], sys.argv[2]
if cmd == "new":
    store(path, 0, 0, [os.urandom(64)])
else:
    off, primary, keys = load(path)
    if cmd == "add":
        keys.append(os.urandom(64))
    elif cmd == "promote":
        primary = len(keys) - 1
    elif cmd == "prune":
        off, keys, primary = off + primary, keys[primary:], 0
    if cmd != "show":
        store(path, off, primary, keys)
off, primary, keys = load(path)
print(f"id_offset={off} primary={primary} key_ids={[off + i for i in range(len(keys))]} primary_id={off + primary}")
