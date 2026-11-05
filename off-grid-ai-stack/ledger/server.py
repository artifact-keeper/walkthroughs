#!/usr/bin/env python3
"""The egress ledger: a logging forward proxy (Python standard library only).

Every Remote repository of the walkthrough has its egress proxy set to this server
(PUT /api/v1/repositories/{key}/egress-proxy, mode explicit), so every request Artifact
Keeper sends to an upstream passes through here and is written down, one JSON line per
request, to the ledger file. It does not filter anything and it never decrypts TLS:

  - CONNECT host:port (an https upstream): an `open` line when the request arrives, before the
    proxy tries to connect, and a `close` line when the tunnel ends, with the bytes each way.
    The URL path inside the tunnel is not visible, and one tunnel can carry many requests
    (clients keep connections open), so the ledger counts connections, not requests; the
    UPSTREAM_FETCHED audit rows count requests.
  - GET http://host/path (a plain-http upstream, such as this instance's own marketplace for
    the plugins Remote): an `open` line with the method, host, port and path, then a `close`
    line once the response is relayed.

The ledger is the evidence for gate G7b: the `open` line is written before the proxy tries to
connect, so an attempt that cannot get out (the site network has no route) is a line too. A
ledger that gains no `open` line while the site works is a site that asked for nothing.

    server.py [--listen 0.0.0.0:3128] [--ledger /out/ledger.jsonl]
"""
import argparse
import http.server
import json
import select
import socket
import socketserver
import sys
import threading
import time
import urllib.parse

LOCK = threading.Lock()
LEDGER = None


def record(entry):
    entry = {"t": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), **entry}
    line = json.dumps(entry, sort_keys=True)
    with LOCK:
        with open(LEDGER, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    print(line, flush=True)


class Proxy(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    timeout = 300

    def log_message(self, fmt, *args):  # the ledger is the log
        pass

    def do_CONNECT(self):
        host, _, port = self.path.rpartition(":")
        port = int(port or 443)
        entry = {"kind": "connect", "client": self.client_address[0], "method": "CONNECT",
                 "host": host.strip("[]"), "port": port}
        t0 = time.monotonic()
        record({**entry, "event": "open"})
        try:
            upstream = socket.create_connection((entry["host"], port), timeout=15)
        except OSError as e:
            self.send_error(502, "cannot connect")
            record({**entry, "event": "close", "result": "connect_failed", "error": type(e).__name__,
                    "ms": int((time.monotonic() - t0) * 1000)})
            return
        self.send_response(200, "Connection established")
        self.end_headers()
        up = down = 0
        conns = [self.connection, upstream]
        try:
            while True:
                r, _, x = select.select(conns, [], conns, 300)
                if x or not r:
                    break
                done = False
                for s in r:
                    data = s.recv(65536)
                    if not data:
                        done = True
                        break
                    if s is self.connection:
                        upstream.sendall(data); up += len(data)
                    else:
                        self.connection.sendall(data); down += len(data)
                if done:
                    break
        except OSError:
            pass
        finally:
            upstream.close()
        self.close_connection = True
        record({**entry, "event": "close", "result": "tunnel", "bytes_up": up, "bytes_down": down,
                "ms": int((time.monotonic() - t0) * 1000)})

    def _relay(self):
        u = urllib.parse.urlsplit(self.path)
        entry = {"kind": "http", "client": self.client_address[0], "method": self.command,
                 "host": u.hostname or "", "port": u.port or 80, "path": u.path}
        t0 = time.monotonic()
        record({**entry, "event": "open"})
        if u.scheme != "http" or not u.hostname:
            self.send_error(400, "absolute http:// URL expected")
            record({**entry, "event": "close", "result": "bad_request"})
            return
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else b""
        try:
            upstream = socket.create_connection((u.hostname, entry["port"]), timeout=15)
        except OSError as e:
            self.send_error(502, "cannot connect")
            record({**entry, "event": "close", "result": "connect_failed", "error": type(e).__name__,
                    "ms": int((time.monotonic() - t0) * 1000)})
            return
        target = u.path + ("?" + u.query if u.query else "")
        head = [f"{self.command} {target or '/'} HTTP/1.1"]
        for k, v in self.headers.items():
            if k.lower() in ("proxy-connection", "proxy-authorization", "connection", "keep-alive"):
                continue
            head.append(f"{k}: {v}")
        head.append("Connection: close")
        upstream.sendall(("\r\n".join(head) + "\r\n\r\n").encode("latin-1") + body)
        down = 0
        status = None
        try:
            while True:
                data = upstream.recv(65536)
                if not data:
                    break
                if status is None:
                    try:
                        status = int(data.split(b" ", 2)[1])
                    except (IndexError, ValueError):
                        status = 0
                self.connection.sendall(data); down += len(data)
        except OSError:
            pass
        finally:
            upstream.close()
        self.close_connection = True
        record({**entry, "event": "close", "result": "relayed", "status": status, "bytes_up": len(body),
                "bytes_down": down, "ms": int((time.monotonic() - t0) * 1000)})

    do_GET = do_HEAD = do_POST = do_PUT = do_DELETE = do_PATCH = do_OPTIONS = _relay


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    global LEDGER
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen", default="0.0.0.0:3128")
    ap.add_argument("--ledger", default="/out/ledger.jsonl")
    a = ap.parse_args()
    LEDGER = a.ledger
    host, _, port = a.listen.rpartition(":")
    open(LEDGER, "a").close()
    print(f"egress ledger on {a.listen}, writing {LEDGER}", file=sys.stderr, flush=True)
    Server((host, int(port)), Proxy).serve_forever()


if __name__ == "__main__":
    main()
