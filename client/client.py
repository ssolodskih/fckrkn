"""yacfsocks local client — a minimal SOCKS5 server that tunnels each TCP
connection to a Yandex Cloud Function over HTTPS.

Telegram points its SOCKS5 proxy at this. YC spreads invocations across one
instance per availability zone with no session stickiness, BUT a single HTTP
keep-alive connection pins to one instance. So each SOCKS session gets its own
keep-alive connection and drives it serially with one `exchange` call
(send-upstream + return-downstream) — all its calls reach the instance that
holds its socket.

    FUNCTION_URL=https://functions.yandexcloud.net/<id> TOKEN=secret python client.py

Env / flags: FUNCTION_URL, TOKEN, LISTEN (host:port, default 127.0.0.1:1080),
SOCKS_USER, SOCKS_PASS, MAX_INFLIGHT (default 9), INSECURE=1, DEBUG=1.
"""

import argparse
import asyncio
import base64
import http.client
import json
import os
import socket
import ssl
import struct
import urllib.parse
from concurrent.futures import ThreadPoolExecutor

# SOCKS5 constants
VER = 0x05
M_NOAUTH = 0x00
M_USERPASS = 0x02
M_NONE = 0xFF
CMD_CONNECT = 0x01
ATYP_IPV4 = 0x01
ATYP_DOMAIN = 0x03
ATYP_IPV6 = 0x04

DEBUG = os.environ.get("DEBUG") == "1"
UP_POLL = 0.02  # seconds to wait for upstream bytes before each exchange


def _ssl_ctx():
    """TLS context that works even when the system CA store is missing (common
    on macOS python.org builds). Prefers certifi; INSECURE=1 disables checks."""
    ctx = ssl.create_default_context()
    if os.environ.get("INSECURE") == "1":
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        return ctx
    try:
        import certifi
        ctx.load_verify_locations(certifi.where())
    except Exception:
        pass
    return ctx


class Config:
    def __init__(self, url, token, listen_host, listen_port, user, password, max_inflight=9):
        u = urllib.parse.urlsplit(url)
        self.scheme = u.scheme or "https"
        self.host = u.netloc            # host[:port]
        self.path = u.path or "/"
        self.token = token
        self.listen_host = listen_host
        self.listen_port = listen_port
        self.user = user
        self.password = password
        self.executor = ThreadPoolExecutor(max_workers=128)
        self.ctx = _ssl_ctx()
        # YC default quota: 10 concurrent function calls per zone. Stay under it.
        self.sem = asyncio.Semaphore(max_inflight)

    def new_conn(self):
        if self.scheme == "https":
            return http.client.HTTPSConnection(self.host, timeout=70, context=self.ctx)
        return http.client.HTTPConnection(self.host, timeout=70)


def _rpc_sync(conn, path, obj):
    body = json.dumps(obj).encode()
    conn.request("POST", path, body, {"Content-Type": "application/json"})
    resp = conn.getresponse()
    data = resp.read()  # must fully read to reuse the keep-alive connection
    if resp.status == 429:
        return {"error": "rate_limited"}
    if resp.status != 200:
        return {"error": "http", "detail": str(resp.status)}
    return json.loads(data)


async def rpc(cfg, conn, obj):
    """One request/response over the session's pinned keep-alive connection."""
    if cfg.token:
        obj = {**obj, "token": cfg.token}
    loop = asyncio.get_event_loop()
    delay = 0.2
    for _ in range(6):
        try:
            async with cfg.sem:
                r = await loop.run_in_executor(cfg.executor, _rpc_sync, conn, cfg.path, obj)
        except (http.client.HTTPException, OSError, ValueError) as e:
            return {"error": "call_failed", "detail": str(e)}
        if r.get("error") == "rate_limited":
            await asyncio.sleep(delay)
            delay = min(delay * 2, 2.0)
            continue
        return r
    return {"error": "rate_limited"}


def _reply(rep, host="0.0.0.0", port=0):
    return bytes([VER, rep, 0x00, ATYP_IPV4]) + socket.inet_aton(host) + struct.pack("!H", port)


async def _negotiate(reader, writer, cfg):
    """Run SOCKS5 greeting + optional auth. Return True to proceed."""
    hdr = await reader.readexactly(2)
    if hdr[0] != VER:
        return False
    methods = await reader.readexactly(hdr[1])
    want_auth = cfg.user is not None
    method = M_USERPASS if (want_auth and M_USERPASS in methods) else (
        M_NOAUTH if (not want_auth and M_NOAUTH in methods) else M_NONE
    )
    writer.write(bytes([VER, method]))
    await writer.drain()
    if method == M_NONE:
        return False
    if method == M_USERPASS:
        if (await reader.readexactly(1))[0] != 0x01:
            return False
        ulen = (await reader.readexactly(1))[0]
        uname = await reader.readexactly(ulen)
        plen = (await reader.readexactly(1))[0]
        passwd = await reader.readexactly(plen)
        ok = uname == cfg.user.encode() and passwd == cfg.password.encode()
        writer.write(bytes([0x01, 0x00 if ok else 0x01]))
        await writer.drain()
        return ok
    return True


async def _read_request(reader):
    """Parse a SOCKS5 CONNECT request. Return 'host:port' or None."""
    hdr = await reader.readexactly(4)  # ver, cmd, rsv, atyp
    if hdr[0] != VER or hdr[1] != CMD_CONNECT:
        return None
    atyp = hdr[3]
    if atyp == ATYP_IPV4:
        host = socket.inet_ntoa(await reader.readexactly(4))
    elif atyp == ATYP_IPV6:
        host = socket.inet_ntop(socket.AF_INET6, await reader.readexactly(16))
    elif atyp == ATYP_DOMAIN:
        length = (await reader.readexactly(1))[0]
        host = (await reader.readexactly(length)).decode()
    else:
        return None
    port = struct.unpack("!H", await reader.readexactly(2))[0]
    return f"{host}:{port}"


async def _bridge(reader, writer, cfg, conn, sid):
    """Serial exchange loop over the pinned connection."""
    while True:
        try:
            up = await asyncio.wait_for(reader.read(65536), timeout=UP_POLL)
            if up == b"":
                return  # local side closed (EOF)
        except asyncio.TimeoutError:
            up = b""
        except (ConnectionError, OSError):
            return
        obj = {"action": "exchange", "sid": sid}
        if up:
            obj["data"] = base64.b64encode(up).decode()
        r = await rpc(cfg, conn, obj)
        if DEBUG and (up or r.get("data") or r.get("error") or r.get("closed")):
            n = len(base64.b64decode(r["data"])) if r.get("data") else 0
            print(f"ex {sid[:6]} up={len(up)} down={n} err={r.get('error')} closed={r.get('closed')}", flush=True)
        if r.get("error") or r.get("closed"):
            return
        data = r.get("data")
        if data:
            try:
                writer.write(base64.b64decode(data))
                await writer.drain()
            except (ConnectionError, OSError):
                return


async def handle(reader, writer, cfg):
    sid = None
    conn = None
    try:
        if not await _negotiate(reader, writer, cfg):
            return
        dst = await _read_request(reader)
        if dst is None:
            writer.write(_reply(0x07))  # command not supported
            await writer.drain()
            return
        conn = cfg.new_conn()  # pinned keep-alive connection for this session
        r = await rpc(cfg, conn, {"action": "open", "dst": dst})
        sid = r.get("sid")
        if not sid:
            print(f"open {dst} FAILED: {r}", flush=True)
            writer.write(_reply(0x05))  # connection refused
            await writer.drain()
            return
        print(f"open {dst} -> {sid} (port {r.get('port')})", flush=True)
        writer.write(_reply(0x00))
        await writer.drain()
        await _bridge(reader, writer, cfg, conn, sid)
    except (asyncio.IncompleteReadError, ConnectionError, OSError):
        pass
    finally:
        if sid and conn is not None:
            try:
                await rpc(cfg, conn, {"action": "close", "sid": sid})
            except Exception:
                pass
        if conn is not None:
            try:
                conn.close()
            except Exception:
                pass
        try:
            writer.close()
        except OSError:
            pass


async def serve(cfg):
    server = await asyncio.start_server(
        lambda r, w: handle(r, w, cfg), cfg.listen_host, cfg.listen_port
    )
    addr = f"{cfg.listen_host}:{cfg.listen_port}"
    auth = "user/pass" if cfg.user else "no-auth"
    print(f"yacfsocks SOCKS5 on {addr} ({auth}) -> {cfg.scheme}://{cfg.host}{cfg.path}")
    async with server:
        await server.serve_forever()


def _parse_listen(s):
    host, _, port = s.rpartition(":")
    return host or "127.0.0.1", int(port)


def main():
    p = argparse.ArgumentParser(description="yacfsocks local SOCKS5 client")
    p.add_argument("--url", default=os.environ.get("FUNCTION_URL"), help="function URL")
    p.add_argument("--token", default=os.environ.get("TOKEN", ""))
    p.add_argument("--listen", default=os.environ.get("LISTEN", "127.0.0.1:1080"))
    p.add_argument("--user", default=os.environ.get("SOCKS_USER"))
    p.add_argument("--password", default=os.environ.get("SOCKS_PASS"))
    p.add_argument("--max-inflight", type=int, default=int(os.environ.get("MAX_INFLIGHT", "9")),
                   help="cap concurrent function calls (YC zone quota is 10)")
    args = p.parse_args()
    if not args.url:
        p.error("FUNCTION_URL / --url is required")
    host, port = _parse_listen(args.listen)
    cfg = Config(args.url, args.token, host, port, args.user, args.password, args.max_inflight)
    try:
        asyncio.run(serve(cfg))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
