# Run yacfsocks on Android (one-tap homescreen widget)

Android can't run a background TCP listener from a bare homescreen link — there's no app to
host the server. The minimal-effort real path is **Termux** (a terminal/Linux environment) plus
its **Termux:Widget** add-on, which puts a one-tap launcher on your homescreen. `client.py` is
pure stdlib, so it runs on Termux's Python unchanged — no rewrite, no APK to build.

The phone runs the SOCKS5 client locally; Telegram on the **same phone** points at `127.0.0.1:1080`.

## 1. Install the apps (from F-Droid, not Play Store)

The Play Store builds of Termux are outdated and its widget add-on isn't there. Use F-Droid:

- **Termux** — the terminal.
- **Termux:Widget** — the homescreen widget/shortcut. Required for the one-tap launch.
- **Termux:Boot** — *optional*, auto-starts the proxy when the phone powers on.

Install Termux first and open it once before installing the add-ons (they must be signed by the
same source — all from F-Droid is fine).

## 2. Copy this repo onto the phone and run setup

In Termux:

```bash
pkg install -y git
git clone <this-repo-url> yacfsocks     # or copy the folder over however you like
cd yacfsocks/android
bash setup.sh
```

`setup.sh` installs Python + certifi, copies `client.py` to `~/.yacfsocks/`, drops the widget
launcher into `~/.shortcuts/`, and writes a config template to `~/.config/yacfsocks/env`.

## 3. (Optional) change the function URL / token

The widget ships with the current `FUNCTION_URL` and `TOKEN` baked in — nothing to edit for a
normal install. You only need this if you **redeploy** (new function id or token) or want SOCKS
auth:

```bash
nano ~/.config/yacfsocks/env
```

Any `NAME=value` line there overrides the baked-in default. Save and exit.

## 4. Add the widget

On the homescreen: add a widget → **Termux:Widget** → pick **yacfsocks**. Tapping it opens a
short Termux session that holds a wake lock and starts the proxy. Leave that session alive (it can
sit in the background); closing it or swiping Termux away stops the proxy.

Test it first without the widget:

```bash
bash ~/.shortcuts/yacfsocks.sh
```

You should see `yacfsocks SOCKS5 on 127.0.0.1:1080 ...`.

## 5. Point Telegram at it

Telegram → **Settings → Data and Storage → Proxy → Add proxy → SOCKS5**
- Server `127.0.0.1`, Port `1080`
- Username/Password only if you set `SOCKS_USER` / `SOCKS_PASS`

Enable the proxy. Chats should load on the whitelisted network.

## Auto-start on boot (optional)

If you installed **Termux:Boot**, `setup.sh` already placed an autostart script in
`~/.termux/boot/`. Open Termux:Boot once so Android grants it launch permission. After a reboot the
proxy starts on its own — no tap needed.

## Keeping it alive

Android aggressively kills background apps to save battery. To keep the proxy up:

- The launcher already calls `termux-wake-lock` (a persistent "acquired wake lock" notification is
  normal and expected).
- In Android Settings → Apps → Termux → Battery, set it to **Unrestricted** / disable battery
  optimization.
- On some vendors (Xiaomi/MIUI, Huawei, Samsung), also **lock** Termux in the recent-apps switcher
  so the OS won't swipe-kill it.

If the connection drops, Telegram reconnects on its own; if the whole process was killed, tap the
widget again.

## Troubleshooting

- **`CERTIFICATE_VERIFY_FAILED`** — set `INSECURE=1` in `~/.config/yacfsocks/env`. Safe here: the
  tunneled bytes are inside Telegram's own MTProto crypto.
- **Telegram stuck on "connecting"** — set `DEBUG=1` in the config, run
  `bash ~/.shortcuts/yacfsocks.sh` in Termux, and watch the `ex <sid> up=.. down=..` lines to see
  where bytes stop.
- **`command not found: termux-wake-lock`** — `pkg install termux-api` (harmless if missing; the
  launcher ignores the error).
