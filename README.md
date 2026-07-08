# yacfsocks

Minimal SOCKS5 proxy for Telegram that tunnels through a **plain Yandex Cloud Function**.

On networks that whitelist only `*.yandexcloud.net` (and where DPI skips Yandex IPs), Telegram and
ordinary proxies are unreachable — but a Cloud Function is. This runs a local SOCKS5 server that carries
each TCP connection over HTTPS to a function, which relays it to the Telegram data-centers. The phone's
egress is limited to Yandex; the function's egress to Telegram is not.

```
Telegram ──SOCKS5──► client.py ──HTTPS to functions.yandexcloud.net──► handler.py ──TCP──► Telegram DC
 127.0.0.1:1080                    (whitelisted, real TLS + Yandex SNI)   (warm instance)   149.154.x.x:443
```

Telegram runs its own MTProto end-to-end inside a transparent byte tunnel — this adds no crypto.

## How it carries a stream over a stateless function

A plain function has a buffered request and a single JSON response — no streaming — and YC spreads
invocations across **one instance per availability zone with no session stickiness**. The open socket lives
in a module-global dict on whichever instance ran `open`, so naive per-call requests scatter across instances
and miss the socket (`no_session`).

The fix: **an HTTP keep-alive connection pins to one instance.** Each SOCKS session opens its own keep-alive
connection and drives it *serially* with one `exchange` call — send any upstream bytes, then wait up to
`EXCHANGE_WAIT` for downstream bytes. All of a session's calls ride that one connection, so they always reach
the instance holding its socket. (Verified: keep-alive connections return a stable instance id across many
requests; different sessions may pin to different instances, each self-consistent.)

Protocol: `open{dst}` → `sid`; `exchange{sid,data}` → `{data, closed}` (ping-pong); `close{sid}`.

## Layout

- `function/handler.py` — deployed relay (stdlib only). Entry point `handler.handler`.
- `function/serve_local.py` — run the handler locally for testing.
- `client/client.py` — local SOCKS5 server + tunnel driver (stdlib only).
- `deploy.sh` — deploy to a Cloud Function via `yc`.
- `test_e2e.py` — one-process end-to-end test.

## Deploy

```bash
# needs: yc CLI (authenticated), zip, openssl
TOKEN=$(openssl rand -hex 16) ./deploy.sh
```

Prints `FUNCTION_URL` and `TOKEN`.

## Run the client

```bash
export FUNCTION_URL=https://functions.yandexcloud.net/<id>
export TOKEN=<token from deploy>
# optional SOCKS auth:
# export SOCKS_USER=me SOCKS_PASS=secret
python client/client.py               # listens on 127.0.0.1:1080
```

**macOS TLS certs:** stock macOS Python often has no CA bundle, so the client's
HTTPS calls to the function fail with `CERTIFICATE_VERIFY_FAILED`. Fix one of:
- `pip3 install certifi` (the client picks it up automatically), **or**
- run the `Install Certificates.command` in your Python's folder, **or**
- run with `INSECURE=1` to skip TLS server verification (safe-ish: the tunneled
  bytes are inside Telegram's own MTProto crypto anyway).

## Point Telegram at it

Settings → Data and Storage → Proxy → Add proxy → **SOCKS5**
- Server `127.0.0.1`, Port `1080` (or the LAN IP if the client runs elsewhere)
- Username/password only if you set `SOCKS_USER`/`SOCKS_PASS`

**Phone can't reach `127.0.0.1`:** run `client.py` on the phone (Termux), a home router, or a Pi on the LAN,
and point Telegram at that `LAN-IP:1080`.

**Run it on an Android phone — native app (recommended):** see [`android-apk/README.md`](android-apk/README.md).
A standalone APK (no Termux, no Python) built with gomobile: download the signed `.apk` from the whitelisted
Yandex bucket, sideload, paste the setup code, tap ON. As a normal app the DNS/TLS/ELF on-device hacks the
Termux path needs all disappear. Telegram on the same phone then uses `SOCKS5 127.0.0.1:1080`.

**Termux fallback:** see [`android/README.md`](android/README.md). Install is a single line pasted into
Termux — a ~6 MB Go binary downloaded from the same whitelisted bucket (GitHub fallback). Use this if you
can't sideload an APK.

## Test locally (no deploy)

```bash
python test_e2e.py          # no-auth
python test_e2e.py --auth   # user/pass
```

## Limits / notes

- **Session = one pinned keep-alive connection.** Sockets are per-instance; the keep-alive pin keeps each
  session on its instance. If that connection drops, the session ends and Telegram reconnects (new session,
  new pin). Multiple sessions across instances are fine.
- **Ping-pong transport**, so latency is higher than a raw socket and throughput is ~one 64 KB chunk per
  round-trip — good for messaging, weak for large media. `EXCHANGE_WAIT` (server, default 0.5s) bounds the
  idle downstream poll.
- **Not an open relay:** the function only dials Telegram DC ranges unless `ALLOW_ALL=1`.
- **Port fallback:** RU/DPI blocks `:443` on some DC ranges (e.g. `149.154.167.x`) from Yandex egress. MTProto
  rides `443/80/5222` identically per DC IP, so the relay retries the other ports on the same IP when one times
  out. This is transparent to Telegram (same DC IP = same DC).
- **Concurrency quota.** YC allows **10 concurrent function calls per zone** by default. Each live connection
  holds one slot (its `down` long-poll), so the client caps in-flight calls at `MAX_INFLIGHT=9` and retries on
  429 — bursts queue instead of failing. Handles a few simultaneous Telegram connections; for heavier use, ask
  YC support to raise the "concurrent function invocations" quota and bump `MAX_INFLIGHT`.
- Free tier is 1M invocations/mo; long-poll `DOWN_TIMEOUT≈50s` keeps the call count low.
- This bypass has been targeted before — keep the URL private and redeploy (new function) if it stops working.
