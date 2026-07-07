"""End-to-end local test: echo server <- function <- SOCKS5 client <- raw SOCKS5.

Runs everything in one process (no deploy):
  - a TCP echo server
  - the Cloud Function handler behind a local threaded HTTP server (ALLOW_ALL=1)
  - the client's SOCKS5 server
  - a tiny blocking SOCKS5 client that connects through it and checks the echo

    python test_e2e.py            # no-auth
    python test_e2e.py --auth     # user/pass

Exit code 0 on success.
"""

import argparse
import asyncio
import os
import socket
import struct
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "function"))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "client"))

os.environ["ALLOW_ALL"] = "1"       # echo server is not a Telegram IP
os.environ["DOWN_TIMEOUT"] = "5"    # keep the test snappy

import handler as fn          # noqa: E402
import client as cl           # noqa: E402

USER, PASS = "u", "p"


def start_echo():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", 0))
    srv.listen(8)

    def loop():
        while True:
            try:
                conn, _ = srv.accept()
            except OSError:
                return
            threading.Thread(target=_echo_conn, args=(conn,), daemon=True).start()

    def _echo_conn(conn):
        with conn:
            while True:
                data = conn.recv(65536)
                if not data:
                    return
                conn.sendall(data)

    threading.Thread(target=loop, daemon=True).start()
    return srv.getsockname()[1]


def start_function():
    class H(BaseHTTPRequestHandler):
        def do_POST(self):
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length).decode()
            resp = fn.handler({"body": body, "isBase64Encoded": False}, None)
            data = resp["body"].encode()
            self.send_response(resp["statusCode"])
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *_):
            pass

    httpd = ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd.server_address[1]


def socks5_roundtrip(socks_port, dst_port, payload, auth=False):
    """Minimal blocking SOCKS5 client. Returns echoed bytes."""
    s = socket.create_connection(("127.0.0.1", socks_port), timeout=10)
    s.settimeout(15)
    if auth:
        s.sendall(bytes([0x05, 0x01, 0x02]))
        assert s.recv(2) == bytes([0x05, 0x02]), "server did not pick user/pass"
        s.sendall(bytes([0x01, len(USER)]) + USER.encode() + bytes([len(PASS)]) + PASS.encode())
        assert s.recv(2) == bytes([0x01, 0x00]), "auth rejected"
    else:
        s.sendall(bytes([0x05, 0x01, 0x00]))
        assert s.recv(2) == bytes([0x05, 0x00]), "server did not pick no-auth"
    # CONNECT 127.0.0.1:dst_port
    s.sendall(bytes([0x05, 0x01, 0x00, 0x01]) + socket.inet_aton("127.0.0.1") + struct.pack("!H", dst_port))
    rep = s.recv(10)
    assert rep[1] == 0x00, f"CONNECT failed rep={rep[1]}"
    s.sendall(payload)
    got = b""
    while len(got) < len(payload):
        chunk = s.recv(65536)
        if not chunk:
            break
        got += chunk
    s.close()
    return got


async def _amain(auth):
    echo_port = start_echo()
    fn_port = start_function()
    cfg = cl.Config(
        url=f"http://127.0.0.1:{fn_port}",
        token="",
        listen_host="127.0.0.1",
        listen_port=0,
        user=USER if auth else None,
        password=PASS if auth else None,
    )
    server = await asyncio.start_server(
        lambda r, w: cl.handle(r, w, cfg), cfg.listen_host, cfg.listen_port
    )
    socks_port = server.sockets[0].getsockname()[1]

    async with server:
        payload = b"the quick brown fox " * 500  # ~10 KB, forces multiple chunks
        got = await asyncio.get_event_loop().run_in_executor(
            None, socks5_roundtrip, socks_port, echo_port, payload, auth
        )
    assert got == payload, f"echo mismatch: sent {len(payload)} got {len(got)}"
    print(f"OK  auth={auth}  round-tripped {len(payload)} bytes through SOCKS5 -> function -> echo")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--auth", action="store_true")
    args = ap.parse_args()
    asyncio.run(_amain(args.auth))


if __name__ == "__main__":
    main()
