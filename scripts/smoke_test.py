"""End-to-end smoke test for moonredis.

Spawns the native server, speaks RESP over TCP, and asserts the core
behaviour: strings, lists, hashes, sorted sets, expiry, transactions,
Pub/Sub and shutdown.

Usage:
    python scripts/smoke_test.py
"""

import os
import socket
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PORT = 16379


class Client:
    def __init__(self, port):
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=5)

    def cmd(self, *parts):
        payload = b"*%d\r\n" % len(parts)
        for part in parts:
            data = part.encode()
            payload += b"$%d\r\n" % len(data) + data + b"\r\n"
        self.sock.sendall(payload)
        return self.read()

    def read(self):
        def read_line():
            line = b""
            while not line.endswith(b"\r\n"):
                chunk = self.sock.recv(1)
                if not chunk:
                    raise ConnectionError("connection closed")
                line += chunk
            return line[:-2]

        prefix = self.sock.recv(1)
        if not prefix:
            raise ConnectionError("connection closed")
        if prefix in (b"+", b"-", b":", b","):
            return prefix + read_line()
        if prefix == b"$":
            size = int(read_line())
            if size < 0:
                return None
            data = b""
            while len(data) < size + 2:
                data += self.sock.recv(size + 2 - len(data))
            return data[:-2]
        if prefix in (b"*", b">"):
            count = int(read_line())
            return [self.read() for _ in range(max(count, 0))]
        return prefix + read_line()

    def close(self):
        self.sock.close()


def wait_for_server(port, timeout=20):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            s = socket.create_connection(("127.0.0.1", port), timeout=1)
            s.close()
            return True
        except OSError:
            time.sleep(0.2)
    return False


def expect(actual, expected, label):
    if actual != expected:
        raise AssertionError(f"{label}: expected {expected!r}, got {actual!r}")
    print(f"  ok {label}")


def main():
    proc = subprocess.Popen(
        [
            "moon",
            "run",
            "cmd/server",
            "--target",
            "native",
            "--",
            "--port",
            str(PORT),
        ],
        cwd=ROOT,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        if not wait_for_server(PORT):
            raise SystemExit("server did not start in time")

        c = Client(PORT)
        expect(c.cmd("PING"), b"+PONG", "PING")
        expect(c.cmd("SET", "name", "moonbit"), b"+OK", "SET")
        expect(c.cmd("GET", "name"), b"moonbit", "GET")
        expect(c.cmd("RPUSH", "list", "a", "b", "c"), b":3", "RPUSH")
        expect(c.cmd("LRANGE", "list", "0", "-1"), [b"a", b"b", b"c"], "LRANGE")
        expect(c.cmd("HSET", "user", "lang", "moon"), b":1", "HSET")
        expect(
            c.cmd("HGETALL", "user"), [b"lang", b"moon"], "HGETALL"
        )
        expect(c.cmd("ZADD", "rank", "3", "c", "1", "a"), b":2", "ZADD")
        expect(
            c.cmd("ZRANGE", "rank", "0", "-1", "WITHSCORES"),
            [b"a", b",1", b"c", b",3"],
            "ZRANGE WITHSCORES",
        )
        expect(c.cmd("INCR", "counter"), b":1", "INCR")
        expect(c.cmd("EXPIRE", "name", "100"), b":1", "EXPIRE")
        expect(c.cmd("MULTI"), b"+OK", "MULTI")
        expect(c.cmd("SET", "tx", "1"), b"+QUEUED", "QUEUED")
        exec_reply = c.cmd("EXEC")
        expect(len(exec_reply) == 1 and exec_reply[0] == b"+OK", True, "EXEC")
        c.close()

        sub = Client(PORT)
        pub = Client(PORT)
        expect(
            sub.cmd("SUBSCRIBE", "news")[0][0] == b"subscribe", True, "SUBSCRIBE"
        )
        expect(pub.cmd("PUBLISH", "news", "hello"), b":1", "PUBLISH")
        sub.sock.settimeout(3)
        message = sub.read()
        expect(message[0] == b"message", True, "message delivered")
        sub.close()
        pub.close()

        sh = Client(PORT)
        try:
            sh.cmd("SHUTDOWN")
        except (ConnectionError, OSError):
            pass  # the server closes the connection on shutdown
        sh.close()
        proc.wait(timeout=10)
        print("SMOKE TEST PASSED")
    finally:
        if proc.poll() is None:
            proc.kill()


if __name__ == "__main__":
    sys.exit(main())
