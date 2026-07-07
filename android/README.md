# Run yacfsocks on Android

Your phone runs a small proxy in the background, and Telegram on the **same phone** uses it. The proxy
is a single ~6 MB Go binary — **no Python, no pip, no git, no repo to clone.** You install it by
pasting **one line** into Termux.

## Step 1 — Install the apps (from F-Droid, NOT the Play Store)

The Play Store version of Termux is broken/outdated. Get F-Droid first (https://f-droid.org), then
from inside F-Droid install:

1. **Termux** — the terminal. Open it once after installing.
2. **Termux:Widget** — puts the one-tap button on your homescreen. Required.
3. **Termux:Boot** — *optional*, auto-starts the proxy after a reboot.

(All three from F-Droid so they're signed the same way.)

## Step 2 — Paste the one-liner

The person who set up the function gives you a line to paste into Termux. It looks like:

```bash
pkg install -y curl && curl -fsSL "https://storage.yandexcloud.net/yacfsocks-dist/install.sh" | bash -s -- <SETUP-CODE>
```

That's the whole install: it downloads the proxy binary + launcher and writes your config (the
`<SETUP-CODE>` carries your `FUNCTION_URL` + `TOKEN`). No editor, no clone.

> **Which network?** The line above downloads from Yandex storage, which is reachable **even on the
> locked-down network**. If you were given the *GitHub* variant instead
> (`...githubusercontent.com...`), run it on open wifi or mobile data — GitHub isn't on the
> whitelist.

If you weren't given a setup code, run the same line without the trailing code and it will **ask you
to paste** your `FUNCTION_URL` and `TOKEN`.

## Step 3 — Test it

```bash
bash ~/.shortcuts/yacfsocks.sh
```

Expect:

```
yacfsocks SOCKS5 on 127.0.0.1:1080 ...
```

Leave it running and do Step 4 (or **Ctrl-C** to stop; you'll relaunch from the widget).

## Step 4 — Point Telegram at it

Telegram → **Settings → Data and Storage → Proxy → Add proxy → SOCKS5**

- **Server:** `127.0.0.1`
- **Port:** `1080`
- Username/Password: leave empty.

Turn the proxy **on**. Your chats should load.

## Step 5 — The one-tap button

On your homescreen: long-press an empty spot → **Widgets** → **Termux:Widget** → drop it on the
screen → pick **yacfsocks**.

From now on: **tap that widget to start the proxy.** It opens a small Termux screen and keeps running
in the background. Telegram works as long as it's running.

- To stop: open that Termux screen and press **Ctrl-C**, or swipe Termux away.
- If Telegram stops working, tap the widget again.

---

## Optional: start automatically after reboot

If you installed **Termux:Boot**: open it once (so Android allows it to run) — the installer already
placed the autostart script. After every reboot the proxy starts on its own.

## Keep Android from killing it

Android kills background apps to save battery. To keep the proxy alive:

- Settings → **Apps → Termux → Battery** → **Unrestricted** (disable battery optimization).
- On Xiaomi/MIUI, Huawei, Samsung: open the recent-apps switcher and **lock** Termux so it isn't
  swiped away.
- The "wake lock acquired" notification is normal — leave it.

## If something goes wrong

- **Telegram won't connect / stuck on "connecting":** re-run the one-liner (wrong URL or token), then
  tap the widget again. Still stuck? add `DEBUG=1` to `~/.config/yacfsocks/env`, run
  `bash ~/.shortcuts/yacfsocks.sh`, and read the `ex ... up=.. down=..` lines.
- **`certificate signed by unknown authority` / TLS errors:** add `INSECURE=1` to
  `~/.config/yacfsocks/env`. Safe here — Telegram encrypts its own traffic inside the tunnel.
- **Download fails:** if you used the GitHub line on the locked-down network, switch to the Yandex
  storage line (or connect to open wifi).
- **`no such file or directory` / linker error when the binary runs:** the launcher starts it via
  `/system/bin/linker64`; if that fails, tell the maintainer your `uname -m` and Android version.
- **Need a username/password on the proxy:** uncomment `SOCKS_USER` / `SOCKS_PASS` in
  `~/.config/yacfsocks/env`, and enter the same values in Telegram's proxy screen.

## Advanced / offline: install from a cloned repo

If you'd rather not use the one-liner (e.g. you have the repo on the phone already):

```bash
pkg install -y git
git clone https://github.com/ssolodskih/fckrkn yacfsocks
cd yacfsocks/android
bash setup.sh <SETUP-CODE>      # or just: bash setup.sh  (it prompts)
```

`setup.sh` uses the binary bundled in the repo instead of downloading it.

---

## For whoever deployed the function

**Publish the installer assets** to the public Yandex storage bucket (so phones can install on the
locked-down network), on a machine with `yc` authenticated:

```bash
cd android
./publish.sh          # creates a public bucket + uploads install.sh, the binary, launchers
```

**Generate the one-liner** to hand out (carries the setup code):

```bash
./make-code.sh        # reads secrets.local.env (or FUNCTION_URL=... TOKEN=... ./make-code.sh)
```

It prints the Yandex-storage line (works everywhere), a GitHub fallback line (open networks only),
and the bare setup code. Treat any of them as secret — they carry the token.

**Rebuild the binary** (only when the client changes), on any computer with Go:

```bash
cd client-go && ./build.sh     # writes android/bin/yacfsocks-linux-arm64 ; then re-run publish.sh
```

No Android NDK needed: it's a pure-Go, CGO-free static PIE. `termux-elf-cleaner` (run by the
installer on the phone) plus launching through `/system/bin/linker64` makes it run under Android's
linker.
