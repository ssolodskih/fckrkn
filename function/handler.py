"""Yandex Cloud Function: TCP relay for the yacfsocks tunnel.

A plain Cloud Function cannot stream, so the byte stream is carried across many
short request/response invocations. Open sockets live in the module-global
``SESSIONS`` dict, which survives between invocations while the instance stays
warm. Pin traffic to one warm instance with ``--min-instances 1`` and a high
``--concurrency`` so every call for a session reaches the process that owns it.

Protocol (JSON body, one public endpoint):
  {action: "open",     token, dst: "ip:port"}    -> {sid}
  {action: "exchange", token, sid, data: <b64>}  -> {data: <b64>, closed: bool}  (send+long-poll)
  {action: "close",    token, sid}               -> {ok: true}
  {action: "ping",     token}                    -> {ok: true, sessions: n}
"""

import base64
import ipaddress
import json
import os
import select
import socket
import threading
import time
import uuid

TOKEN = os.environ.get("TOKEN", "")
IDLE_TIMEOUT = float(os.environ.get("IDLE_TIMEOUT", "120"))
CONNECT_TIMEOUT = float(os.environ.get("CONNECT_TIMEOUT", "5"))  # per-port attempt
EXCHANGE_WAIT = float(os.environ.get("EXCHANGE_WAIT", "0.5"))  # downstream long-poll per exchange
ALLOW_ALL = os.environ.get("ALLOW_ALL", "") == "1"
ALLOWED_PORTS = {80, 443, 5222}

# Telegram data-center ranges (v4 + v6). Prevents the public function from being
# an open relay: only Telegram IPs may be dialed unless ALLOW_ALL is set.
TELEGRAM_CIDRS = [
    ipaddress.ip_network(c)
    for c in (
        "149.154.160.0/20",
        "149.154.164.0/22",
        "91.108.4.0/22",
        "91.108.8.0/22",
        "91.108.12.0/22",
        "91.108.16.0/22",
        "91.108.20.0/22",
        "91.108.56.0/22",
        "91.105.192.0/23",
        "95.161.64.0/20",
        "2001:b28:f23d::/48",
        "2001:b28:f23f::/48",
        "2001:b28:f23c::/48",
        "2001:67c:4e8::/48",
    )
]

SESSIONS = {}  # sid -> {"sock": socket, "last": float}
LOCK = threading.Lock()
INSTANCE_ID = uuid.uuid4().hex[:6]  # distinct per warm instance; reveals affinity


def _allowed(host, port):
    if ALLOW_ALL:
        return True
    if port not in ALLOWED_PORTS:
        return False
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        return False  # only literal Telegram IPs (the client resolves nothing but IPs)
    return any(ip in net for net in TELEGRAM_CIDRS)


def _drop(sid):
    with LOCK:
        s = SESSIONS.pop(sid, None)
    if s:
        try:
            s["sock"].close()
        except OSError:
            pass


def _reap(now):
    with LOCK:
        dead = [sid for sid, s in SESSIONS.items() if now - s["last"] > IDLE_TIMEOUT]
    for sid in dead:
        _drop(sid)


def _touch(sid):
    with LOCK:
        s = SESSIONS.get(sid)
        if s:
            s["last"] = time.time()
        return s


def _open(dst):
    host, sep, port = dst.rpartition(":")
    if not sep:
        return {"error": "bad_dst"}
    try:
        port = int(port)
    except ValueError:
        return {"error": "bad_dst"}
    if not _allowed(host, port):
        return {"error": "dst_not_allowed"}
    # MTProto rides 443/80/5222 identically for the same DC IP. RU/DPI blocks
    # 443 on some DC ranges from Yandex egress, so if the requested port times
    # out, transparently retry the other MTProto ports on the same IP.
    ports = [port] + [p for p in (443, 80, 5222) if p != port]
    last = "no_port"
    for p in ports:
        try:
            sock = socket.create_connection((host, p), timeout=CONNECT_TIMEOUT)
        except OSError as e:
            last = str(e)
            continue
        sock.setblocking(True)
        sid = uuid.uuid4().hex
        with LOCK:
            SESSIONS[sid] = {"sock": sock, "last": time.time()}
        return {"sid": sid, "port": p}
    return {"error": "connect_failed", "detail": last}


def _exchange(sid, data_b64):
    """Serial send+receive for one pinned keep-alive connection: write any
    upstream bytes, then wait up to EXCHANGE_WAIT for downstream bytes."""
    s = _touch(sid)
    if not s:
        return {"error": "no_session"}
    sock = s["sock"]
    if data_b64:
        try:
            sock.sendall(base64.b64decode(data_b64))
        except OSError as e:
            _drop(sid)
            return {"error": "send_failed", "detail": str(e)}
    deadline = time.time() + EXCHANGE_WAIT
    while True:
        remaining = deadline - time.time()
        if remaining <= 0:
            return {"data": "", "closed": False}
        try:
            r, _, _ = select.select([sock], [], [], min(remaining, 0.2))
        except OSError:
            _drop(sid)
            return {"data": "", "closed": True}
        if not r:
            continue
        try:
            chunk = sock.recv(65536)
        except OSError:
            _drop(sid)
            return {"data": "", "closed": True}
        if chunk == b"":
            _drop(sid)
            return {"data": "", "closed": True}
        _touch(sid)
        return {"data": base64.b64encode(chunk).decode(), "closed": False}


def _resp(code, obj):
    return {
        "statusCode": code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(obj),
        "isBase64Encoded": False,
    }


def handler(event, context):
    _reap(time.time())
    body = event.get("body") or "{}"
    if event.get("isBase64Encoded"):
        body = base64.b64decode(body).decode()
    try:
        req = json.loads(body)
    except (ValueError, TypeError):
        return _resp(400, {"error": "bad_json"})

    if TOKEN and req.get("token") != TOKEN:
        return _resp(403, {"error": "forbidden"})

    action = req.get("action")
    try:
        if action == "open":
            out = _open(req["dst"])
        elif action == "exchange":
            out = _exchange(req["sid"], req.get("data", ""))
        elif action == "close":
            _drop(req.get("sid"))
            out = {"ok": True}
        elif action == "ping":
            out = {"ok": True, "sessions": len(SESSIONS), "iid": INSTANCE_ID}
        else:
            return _resp(400, {"error": "bad_action"})
    except KeyError as e:
        return _resp(400, {"error": "missing_field", "detail": str(e)})
    except Exception as e:  # noqa: BLE001 - never 500 without a message
        return _resp(500, {"error": "exception", "detail": str(e)})
    return _resp(200, out)
