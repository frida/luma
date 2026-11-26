import asyncio
import time
import json
import os
import re
import sys

UPSTREAM = ("127.0.0.1", 29442)
CONTROL_PORT = int(sys.argv[1])
PORTS = [int(p) for p in sys.argv[2:]]

PATTERNS = {
    "op": re.compile(rb'"\+op"'),
    "snapshot": re.compile(rb'"\.snapshot"'),
    "join": re.compile(rb'"\.join"'),
    "create": re.compile(rb'"\.create"'),
    "hello": re.compile(rb'"\.hello"'),
    "session_path": re.compile(rb'/sessions/[0-9A-Fa-f-]{36}'),
    "object_chat_op": re.compile(rb'/object-chats'),
}
KIND = re.compile(rb'"kind":\s*"([a-z_]+)"')

counts = {p: {} for p in PORTS}
blocked = set()
live = {p: set() for p in PORTS}
log = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "run", "proxy.log"), "a", buffering=1)


def bump(port, key, n=1):
    counts[port][key] = counts[port].get(key, 0) + n


class Unmasker:
    def __init__(self, port):
        self.port = port
        self.buf = b""
        self.upgraded = False
        self.stream = b""

    def feed(self, data):
        self.buf += data
        if not self.upgraded:
            end = self.buf.find(b"\r\n\r\n")
            if end < 0:
                return
            head = self.buf[:end]
            log.write(f"[{self.port}] handshake {head[:400]!r}\n")
            self.buf = self.buf[end + 4:]
            self.upgraded = True
        while True:
            b = self.buf
            if len(b) < 2:
                return
            masked = b[1] & 0x80
            length = b[1] & 0x7F
            pos = 2
            if length == 126:
                if len(b) < 4:
                    return
                length = int.from_bytes(b[2:4], "big")
                pos = 4
            elif length == 127:
                if len(b) < 10:
                    return
                length = int.from_bytes(b[2:10], "big")
                pos = 10
            mask = b""
            if masked:
                if len(b) < pos + 4:
                    return
                mask = b[pos:pos + 4]
                pos += 4
            if len(b) < pos + length:
                return
            payload = b[pos:pos + length]
            if masked:
                payload = bytes(c ^ mask[i % 4] for i, c in enumerate(payload))
            self.buf = b[pos + length:]
            self.scan(payload)

    def scan(self, payload):
        self.stream = (self.stream + payload)[-200000:]
        for key, pattern in PATTERNS.items():
            n = len(pattern.findall(payload))
            if n:
                bump(self.port, key, n)
        if PATTERNS["op"].search(payload):
            for kind in KIND.findall(payload):
                bump(self.port, "op:" + kind.decode())
            if b"object_chat_" in payload:
                fields = [m.decode() for m in re.findall(rb'"(?:kind|op_id|object_id|produced_by|status|tool)":\s*"([^"]+)"', payload)]
                ids = [m.decode()[:8] for m in re.findall(rb'"id":\s*"([0-9A-F-]{36})"', payload)]
                log.write(f"{time.time():.3f} [{self.port}] op {fields} ids={ids}\n")
        elif b'".snapshot"' in payload or b'".join"' in payload:
            log.write(f"{time.time():.3f} [{self.port}] request {'snapshot' if b'.snapshot' in payload else 'join'}\n")


held = {}


async def pipe(reader, writer, unmasker=None, port=None):
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            if unmasker:
                unmasker.feed(data)
            if port is not None and port in held:
                held[port].append((writer, data))
                bump(port, "held_chunks")
                continue
            writer.write(data)
            await writer.drain()
    except Exception:
        pass
    finally:
        try:
            writer.close()
        except Exception:
            pass


def serve(port):
    async def handle(reader, writer):
        if port in blocked:
            writer.close()
            return
        try:
            up_reader, up_writer = await asyncio.open_connection(*UPSTREAM)
        except Exception:
            writer.close()
            return
        bump(port, "connections")
        pair = (writer, up_writer)
        live[port].add(pair)
        await asyncio.gather(pipe(reader, up_writer, Unmasker(port), port), pipe(up_reader, writer))
        live[port].discard(pair)
    return handle


async def control(reader, writer):
    while True:
        line = await reader.readline()
        if not line:
            break
        words = line.decode().split()
        if not words:
            continue
        if words[0] == "counts":
            writer.write((json.dumps(counts) + "\n").encode())
        elif words[0] == "reset":
            for p in counts:
                counts[p] = {}
            writer.write(b"ok\n")
        elif words[0] == "block":
            port = int(words[1])
            blocked.add(port)
            for a, b in list(live[port]):
                for w in (a, b):
                    try:
                        w.transport.abort()
                    except Exception:
                        pass
            writer.write(b"ok\n")
        elif words[0] == "hold":
            held.setdefault(int(words[1]), [])
            writer.write(b"ok\n")
        elif words[0] == "release":
            for w, data in held.pop(int(words[1]), []):
                w.write(data)
                await w.drain()
            writer.write(b"ok\n")
        elif words[0] == "unblock":
            blocked.discard(int(words[1]))
            writer.write(b"ok\n")
        await writer.drain()


async def main():
    for port in PORTS:
        await asyncio.start_server(serve(port), "127.0.0.1", port)
    await asyncio.start_server(control, "127.0.0.1", CONTROL_PORT)
    print("proxy ready", flush=True)
    await asyncio.Event().wait()


asyncio.run(main())
