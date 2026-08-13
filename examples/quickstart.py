"""moonredis quick-start demo.

Talks to the server with plain RESP over TCP so no third-party Redis client
is required.

Usage:
    moon run cmd/server -- --port 6399
    python examples/quickstart.py
"""

import socket

HOST = "127.0.0.1"
PORT = 6399


def command(sock, *parts):
    payload = b"*%d\r\n" % len(parts)
    for part in parts:
        data = part.encode()
        payload += b"$%d\r\n" % len(data) + data + b"\r\n"
    sock.sendall(payload)
    return read_reply(sock)


def read_reply(sock):
    def read_line():
        line = b""
        while not line.endswith(b"\r\n"):
            line += sock.recv(1)
        return line[:-2]

    prefix = sock.recv(1)
    if prefix in (b"+", b"-", b":", b","):
        return prefix + read_line()
    if prefix == b"$":
        size = int(read_line())
        if size < 0:
            return b"(nil)"
        data = b""
        while len(data) < size + 2:
            data += sock.recv(size + 2 - len(data))
        return data[:-2]
    if prefix == b"*":
        count = int(read_line())
        if count < 0:
            return b"(nil)"
        items = [read_reply(sock) for _ in range(count)]
        return items
    return prefix + read_line()


def show(label, value):
    print(f"{label}: {value}")


def main():
    sock = socket.create_connection((HOST, PORT), timeout=3)
    show("PING", command(sock, "PING"))
    show("SET", command(sock, "SET", "name", "moonbit"))
    show("GET", command(sock, "GET", "name"))
    show("RPUSH", command(sock, "RPUSH", "list", "a", "b", "c"))
    show("LRANGE", command(sock, "LRANGE", "list", "0", "-1"))
    show("HSET", command(sock, "HSET", "user", "lang", "moon"))
    show("HGETALL", command(sock, "HGETALL", "user"))
    show("ZADD", command(sock, "ZADD", "rank", "3", "c", "1", "a"))
    show("ZRANGE", command(sock, "ZRANGE", "rank", "0", "-1", "WITHSCORES"))
    show("INCR", command(sock, "INCR", "counter"))
    show("KEYS", command(sock, "KEYS", "*"))
    sock.close()


if __name__ == "__main__":
    main()
