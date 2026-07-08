# yacfsocks - Project Notes (agent handoff)

Everything a future agent needs to understand, operate, and extend this project. Read this before touching
anything. Companion docs: `README.md` (user-facing usage), this file (design + history + gotchas).

---

## 1. What this is and why it exists

**Goal:** let a user whose network is a *whitelist* (only `*.yandexcloud.net` reachable; Telegram and all
third-party proxies blocked at the ISP/DPI layer) use Telegram by routing through a **Yandex Cloud Function**.

The insight that makes it possible: the **whitelist is on the user's side**. The user's phone/PC can only
reach Yandex, but a Cloud Function's *own* egress to the public internet (including Telegram data-centres) is
unrestricted. So the function acts as the exit:

```
Telegram ──SOCKS5──► client.py ──HTTPS to functions.yandexcloud.net (whitelisted)──► Cloud Function ──TCP──► Telegram DC
 proxy=127.0.0.1:1080  (local)          real TLS, Yandex SNI, DPI-exempt            (relay)        149.154.x.x / 91.108.x.x
```

The function is a **transparent byte relay**. Telegram runs its own MTProto end-to-end *inside* the tunnel;
we add no crypto and do not parse MTProto.

This method is documented (in principle) on Habr: «Белые списки: способы обхода»
<https://habr.com/ru/articles/1027276/> - "functions.yandexcloud.net is universally whitelisted; write a
SOCKS5 client to connect to the function." That article states *that* it works, not *how*; this repo is a
working *how*.

**Hard requirement from the user (do not relitigate):** must be a plain **Cloud Function** - NOT a VM, NOT a
Serverless Container. This constraint drove every hard design decision below.

---

## 2. The two-component architecture

- **`client/client.py`** - runs LOCALLY where Telegram can reach it (PC `127.0.0.1`, or a phone via Termux /
  a LAN box). A minimal asyncio **SOCKS5 server** (RFC 1928 + RFC 1929: no-auth and user/pass). It is the
  "minimalistic SOCKS5 client" of the original brief: SOCKS5 to Telegram, HTTPS tunnel-client to the function.
- **`function/handler.py`** - DEPLOYED to the Cloud Function. A **stdlib-only TCP relay**. Opens sockets to
  Telegram DCs and shuttles bytes.

Telegram never talks to the function directly - it only speaks raw-TCP SOCKS5/MTProto, never `https://`.
The local client is therefore **mandatory** (every comparable project - Flowseal/tg-ws-proxy, yac-ws-bridge -
has one). Do not try to remove it.

---

## 3. Protocol (client ⇄ function)

JSON POST body to the single function URL. `token` (shared secret) on every call.

| action | request | response |
|---|---|---|
| `open`     | `{dst:"ip:port"}`      | `{sid, port}` or `{error}` |
| `exchange` | `{sid, data?:<b64>}`   | `{data:<b64>, closed:bool}` or `{error}` |
| `close`    | `{sid}`                | `{ok:true}` |
| `ping`     | -                      | `{ok, sessions, iid}` (iid = instance id, for debugging) |

`exchange` is a **serial ping-pong**: the client sends any pending upstream bytes and the server, after
writing them to the DC socket, waits up to `EXCHANGE_WAIT` (default 0.5s) for downstream bytes and returns
them. One `exchange` in flight at a time per session.

> Legacy `up`/`down` actions still exist in the handler but are unused (superseded by `exchange`). Safe to
> delete later; left for now.

---

## 4. THE critical design decision (read this or you will break it)

A plain Cloud Function **cannot** naively hold a TCP stream, for two independent reasons - both empirically
verified against the live function, not assumed:

1. **No streaming.** Request body is fully buffered; the response is a single JSON object; WebSocket-via-API-
   Gateway delivers each message as a separate stateless invocation. So one invocation cannot stream a
   bidirectional socket. → We split the stream across many short request/response calls.

2. **No session stickiness across instances.** YC runs the function as **one instance per availability zone
   (ru-central1 a/b/d) = up to 3 instances**, and load-balances across them. The open socket lives in a
   module-global `SESSIONS` dict on whichever instance handled `open`. Naive per-call requests scatter across
   the 3 instances → the socket is missing 2/3 of the time → `no_session` → dead connection. Measured: 20
   pings returned 3 distinct instance ids (~7/9/4). Attaching a VPC network did NOT reduce this (still 3).
   `--provisioned-instances-count 1` means 1 warm *per zone*, i.e. 3 total - it does NOT pin to one instance.

**The fix - keep-alive pinning.** A single HTTP keep-alive connection sticks to ONE instance for its lifetime
(verified: 15/15 requests on one connection → one iid). So **each SOCKS session opens its own keep-alive
connection and drives it serially** with `open` then `exchange`…`exchange` then `close`. All of a session's
calls reach the instance that owns its socket. Different sessions may pin to different instances; each is
self-consistent. HTTP/1.1 keep-alive is serial, which is exactly why `up`/`down` were collapsed into one
`exchange` (two concurrent loops can't share one serial connection).

If a future change reintroduces separate concurrent calls per session, or drops the per-session keep-alive
connection, the `no_session` bug returns. Don't.

---

## 5. Other non-obvious fixes baked in (each was a real failure, in order)

1. **macOS TLS: `CERTIFICATE_VERIFY_FAILED`.** Stock macOS python.org Python has no CA bundle, so every HTTPS
   call to the function failed. Fix: client uses `certifi` if importable, else honours `INSECURE=1`
   (skips TLS verify - acceptable because payload is inside Telegram's own MTProto crypto). **`certifi` is
   already `pip`-installed** in `/Library/Frameworks/Python.framework/Versions/3.13`, so it works with no flag.

2. **RU/DPI blocks port 443 on some DC ranges from Yandex egress** (notably `149.154.167.x` = DC2/DC4). MTProto
   rides `443/80/5222` identically for the *same DC IP*, so `_open` retries the other ports on the same IP when
   one times out (transparent to Telegram: same IP = same DC). Measured: `149.154.167.x:443` timed out but
   `:80`/`:5222` were open; `149.154.175.x`/`91.108.56.x:443` mostly open. Reachability also *flaps* per
   request - the port fallback + Telegram's own retries absorb it.

3. **HTTP 429 Too Many Requests.** YC default quota = **10 concurrent function calls per zone**. Each active
   session holds ~1 in-flight `exchange`. Fix: client caps concurrent calls with a semaphore (`MAX_INFLIGHT`,
   default 9) and retries 429 with backoff. Bursts queue instead of failing (tested: 14 concurrent opens → 13
   ok, 0 throttled).

4. **`1.0.0.0:443` in logs** = a Telegram connectivity-probe sentinel, not a real DC. The allowlist correctly
   drops it (`dst_not_allowed`); harmless noise. Real DCs are `149.154.x.x` / `91.108.x.x`.

---

## 6. Live deployment (current state)

- **Function name:** `yacfsocks`
- **Function id:** `<FUNCTION_ID>` (real value in gitignored `secrets.local.env`; or `yc serverless function get --name yacfsocks`)
- **URL:** `https://functions.yandexcloud.net/<FUNCTION_ID>`
- **Runtime/entry:** `python312`, `handler.handler`, memory `256m`, execution-timeout `60s`, concurrency `16`
- **Scaling policy (`$latest`):** `--provisioned-instances-count 1 --zone-instances-limit 1` (⇒ ~3 warm
  instances, one per zone; multi-instance is FINE now thanks to keep-alive pinning; provisioning keeps them
  warm to avoid mid-session cold starts)
- **Env:** `TOKEN`, `EXCHANGE_WAIT=0.5`. Allowlist ON (open relay disabled).
- **Public invoke:** enabled (`allow-unauthenticated-invoke`). Access is gated by `TOKEN` in the body, not IAM.
- **Default VPC network in folder:** `enp39m10qfodcgunl724` (NOT attached to the function - attaching did not
  help and isn't needed).

**Secrets.** The shared secret `TOKEN` and the function id are kept OUT of this repo (public). Real values
live in the gitignored `secrets.local.env` at the repo root. `TOKEN` is NOT sensitive beyond gating this
relay; prefer fetching the canonical value from the deployed function, and rotate by redeploying with a new
`TOKEN`:

```bash
yc serverless function version get-by-tag --function-name yacfsocks --tag '$latest' --format json \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["environment"]["TOKEN"])'
```

`yc` CLI is installed at `/Users/ssman/yandex-cloud/bin/yc` and is authenticated with rights to manage this
function.

---

## 7. Files

```
yacfsocks/
├── function/
│   ├── handler.py        # deployed relay: SESSIONS dict, _open (port fallback), _exchange, allowlist, INSTANCE_ID
│   ├── serve_local.py    # ThreadingHTTPServer wrapper to run handler locally (ALLOW_ALL=1 PORT=8080)
│   └── requirements.txt  # empty (stdlib only)
├── client/
│   ├── client.py         # local SOCKS5 server + per-session keep-alive exchange loop
│   └── requirements.txt  # empty (stdlib; certifi optional but recommended)
├── deploy.sh             # yc: create-if-missing, version create, scaling policy, allow-invoke, print URL
├── test_e2e.py           # one-process end-to-end: echo <- function <- client <- raw SOCKS5
├── README.md             # user-facing
└── PROJECT.md            # this file
```

Key handler config (env-overridable): `TOKEN`, `EXCHANGE_WAIT` (0.5), `CONNECT_TIMEOUT` (5, per-port attempt),
`IDLE_TIMEOUT` (120, session reaper), `ALLOW_ALL` (unset; set `1` ONLY for diagnostics - turns it into an open
relay), allowlist `TELEGRAM_CIDRS` + `ALLOWED_PORTS {80,443,5222}`.

Client env/flags: `FUNCTION_URL`, `TOKEN`, `LISTEN` (127.0.0.1:1080), `SOCKS_USER`/`SOCKS_PASS`,
`MAX_INFLIGHT` (9), `INSECURE=1`, `DEBUG=1`.

---

## 8. Operate

**Deploy / redeploy** (keep the same TOKEN so running clients don't break):
```bash
cd /Users/ssman/PycharmProjects/yacfsocks
TOKEN=<your-token> ./deploy.sh    # or: source secrets.local.env; TOKEN=$TOKEN ./deploy.sh
```
Fresh token: run without `TOKEN=` and it generates one (then update the client).

**Run client + Telegram:**
```bash
source secrets.local.env    # sets FUNCTION_URL + TOKEN
python3 client/client.py
```
Telegram → Settings → Proxy → SOCKS5 `127.0.0.1:1080`. Phone can't reach `127.0.0.1`? Run the client on the
phone (Termux) / router / a LAN box and point Telegram at that `LAN-IP:1080`.

---

## 9. Test & debug

- **Local e2e (no deploy, no network):** `python3 test_e2e.py` and `python3 test_e2e.py --auth`. Proves
  SOCKS5 + relay + byte round-trip.
- **Function reachable / token:** `curl -sS -X POST "$URL" -d '{"action":"ping","token":"'"$TOKEN"'"}'` →
  `{ok, sessions, iid}`.
- **Instance spread:** loop `ping` and `uniq -c` the `iid`s - expect ~3 distinct (the whole reason for pinning).
- **DC reachability / port fallback:** `curl -sS -X POST "$URL" -d '{"action":"open","token":"'"$TOKEN"'","dst":"149.154.167.51:443"}'`
  → `{sid, port}` (port shows which port fallback landed on).
- **Full data path through DEPLOYED function:** temporarily deploy a version with `ALLOW_ALL=1`, then
  `curl -x socks5://127.0.0.1:1080 http://1.1.1.1/` should return `301`. **Re-deploy without `ALLOW_ALL`
  afterwards** (`./deploy.sh`) to re-lock. This is how the pinning fix was validated.
- **Live client tracing:** run the client with `DEBUG=1` → per-connection `ex <sid> up=.. down=.. err=.. closed=..`.
  If Telegram stalls, this shows exactly where bytes stop.

---

## 10. Known limits & risks

- **Throughput/latency:** ping-pong = ~one 64 KB chunk per round-trip; fine for messaging, weak for large
  media. `EXCHANGE_WAIT` bounds idle downstream latency.
- **Concurrency ceiling:** ~9 concurrent function calls (client semaphore, under the 10/zone quota). Enough for
  a few simultaneous Telegram connections. For heavier/multi-user use, ask YC support to raise the "concurrent
  function invocations" quota and bump `MAX_INFLIGHT`.
- **Session durability:** a session dies if its pinned keep-alive connection drops or its instance cold-cycles;
  Telegram just reconnects (new session, new pin).
- **DPI flap:** DC reachability from Yandex egress is intermittent per IP:port; port fallback + retries cover
  most of it, not all.
- **Invocations cost:** idle sessions still ping-pong (~1 `exchange` per `EXCHANGE_WAIT`). Free tier is 1M/mo;
  watch it under sustained use. Raising `EXCHANGE_WAIT` cuts call count at the cost of idle downstream latency.
- **Not an open relay:** allowlist restricts `dst` to Telegram CIDRs + ports {80,443,5222}. Keep it that way in
  production; `ALLOW_ALL=1` is diagnostics-only.
- **Keep the URL/token private**; redeploy (new function/token) if the endpoint gets blocked.

---

## 11. Verified facts about YC Cloud Functions (with sources)

- Instances are reused across invocations; declarations outside the handler stay initialized (like a reused DB
  connection) - <https://yandex.cloud/en/docs/functions/concepts/runtime/execution-context>. BUT this is
  per-instance and there are multiple zonal instances → needs the keep-alive pin.
- Default egress: isolated network + NAT, **public IPv4 only**, outbound TCP/UDP/ICMP; inbound not supported;
  TCP/25 blocked - <https://yandex.cloud/en/docs/functions/concepts/networking>.
- Execution timeout 1–900s (we use 60s). Request buffered, single JSON response (no streaming).
- Default quota: **10 concurrent calls per zone**, 10 instances per zone -
  <https://yandex.cloud/en/docs/functions/concepts/limits>.
- `--min-instances` is NOT a `version create` flag; warm instances are a separate scaling policy
  (`yc serverless function set-scaling-policy --provisioned-instances-count N --zone-instances-limit M`).
- Attaching a VPC network creates per-zone service subnets (198.19.0.0/16) and does NOT confine to one zone.

---

## 12. Ideas / next steps (not done)

- Delete dead `up`/`down` handler actions.
- Batch multiple 64 KB chunks per `exchange` to improve media throughput.
- Optional: raise the concurrency quota (support ticket) and increase `MAX_INFLIGHT` for multi-user.
- Consider MTProto-aware obfuscation / fake-TLS on the client↔function hop if the plain WSS/HTTPS pattern is
  ever fingerprinted (currently it's ordinary TLS to `*.yandexcloud.net`, which is the whole point).
- If the user ever relaxes the "function only" rule, a Serverless Container removes the pinning/quota gymnastics
  (single addressable endpoint, holds the socket) - but that was explicitly rejected.
```
