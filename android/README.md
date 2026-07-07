# Run yacfsocks on Android — step by step

Your phone runs a small proxy in the background, and Telegram on the **same phone** uses it.
The proxy is a single ~6 MB Go binary — **no Python, no pip, no package hell** (the old Python
path pulled in ~1 GB). You still need Termux as a place to launch it from, plus one tiny helper
package (a few hundred KB). Follow the steps in order; each is copy-paste. ~10 minutes.

## What you need before starting

**Two values**, from whoever set up the Cloud Function (they come from `deploy.sh`):

| Value | Looks like |
|-------|-----------|
| `FUNCTION_URL` | `https://functions.yandexcloud.net/d4abc123...` |
| `TOKEN` | a long random string, e.g. `8e93e78c99fc...` |

Even easier: ask them for a ready-made **setup code** (see Step 3) — one line that carries both.

---

## Step 1 — Install the apps (from F-Droid, NOT the Play Store)

The Play Store version of Termux is broken/outdated. Get F-Droid first (https://f-droid.org), then
from inside F-Droid install:

1. **Termux** — the terminal. Open it once after installing.
2. **Termux:Widget** — puts the one-tap button on your homescreen. Required.
3. **Termux:Boot** — *optional*, auto-starts the proxy after a reboot.

(All three must come from F-Droid so they're signed the same way.)

## Step 2 — Get the code onto the phone

Open **Termux** and paste:

```bash
pkg install -y git
git clone https://github.com/ssolodskih/fckrkn yacfsocks
```

This includes the prebuilt `arm64` proxy binary — nothing to compile on the phone.

## Step 3 — Run the installer (this is also where the two values go)

Two ways, **no text editor either way.**

**Easiest — a setup code.** If the deployer gave you a line like `bash setup.sh eHR0cHM6...`, run it:

```bash
cd yacfsocks/android
bash setup.sh <THE-LONG-CODE-THEY-GAVE-YOU>
```

That code carries both `FUNCTION_URL` and `TOKEN`. Done — skip to Step 4.

**Or — paste at the prompt.** If you only have the two values:

```bash
cd yacfsocks/android
bash setup.sh
```

It installs a tiny ELF helper, puts the binary in place, then **asks you to paste** each value:

```
Paste FUNCTION_URL and press Enter:
> https://functions.yandexcloud.net/d4abc123...
Paste TOKEN and press Enter:
> 8e93e78c99fc...
```

(In Termux, paste = long-press the screen → Paste.) Values are saved to `~/.config/yacfsocks/env`.
You never open an editor.

## Step 4 — Test it

```bash
bash ~/.shortcuts/yacfsocks.sh
```

Expect:

```
yacfsocks SOCKS5 on 127.0.0.1:1080 ...
```

If it says `Set FUNCTION_URL + TOKEN ...`, re-run Step 3. Leave this running and do Step 5 (or
**Ctrl-C** to stop; you'll relaunch from the widget).

## Step 5 — Point Telegram at it

Telegram → **Settings → Data and Storage → Proxy → Add proxy → SOCKS5**

- **Server:** `127.0.0.1`
- **Port:** `1080`
- Username/Password: leave empty.

Turn the proxy **on**. Your chats should load.

## Step 6 — The one-tap button

On your homescreen: long-press an empty spot → **Widgets** → **Termux:Widget** → drop it on the
screen → pick **yacfsocks**.

From now on: **tap that widget to start the proxy.** It opens a small Termux screen and keeps
running in the background. Telegram works as long as it's running.

- To stop: open that Termux screen and press **Ctrl-C**, or swipe Termux away.
- If Telegram stops working, tap the widget again.

---

## Optional: start automatically after reboot

If you installed **Termux:Boot**: open it once (so Android allows it to run) — `setup.sh` already
placed the autostart script. After every reboot the proxy starts on its own.

## Keep Android from killing it

Android kills background apps to save battery. To keep the proxy alive:

- Settings → **Apps → Termux → Battery** → **Unrestricted** (disable battery optimization).
- On Xiaomi/MIUI, Huawei, Samsung: open the recent-apps switcher and **lock** Termux so it isn't
  swiped away.
- The "wake lock acquired" notification is normal — leave it.

## If something goes wrong

- **Telegram won't connect / stuck on "connecting":** re-check Step 3 (wrong URL or token) by
  re-running it, then tap the widget again. Still stuck? add `DEBUG=1` to
  `~/.config/yacfsocks/env`, run `bash ~/.shortcuts/yacfsocks.sh`, and read the
  `ex ... up=.. down=..` lines.
- **`certificate signed by unknown authority` / TLS errors:** add `INSECURE=1` to
  `~/.config/yacfsocks/env`. Safe here — Telegram encrypts its own traffic inside the tunnel.
- **`no such file or directory` when the binary runs, or a linker error:** your Android is unusual.
  The launcher already starts the binary via `/system/bin/linker64`; if that fails, tell the
  maintainer your `uname -m` and Android version.
- **Need a username/password on the proxy:** uncomment `SOCKS_USER` / `SOCKS_PASS` in
  `~/.config/yacfsocks/env`, and enter the same values in Telegram's proxy screen.

---

## For whoever deployed the function

**Generate a one-line setup code** (so the phone user types nothing) on a machine with the secrets:

```bash
cd android
./make-code.sh          # or: FUNCTION_URL=... TOKEN=... ./make-code.sh
```

It prints `bash setup.sh <CODE>` to send them. That code carries both values — treat it as secret.

**Rebuild the binary** (only when the client changes) on any computer with Go:

```bash
cd client-go && ./build.sh      # writes android/bin/yacfsocks-linux-arm64
```

No Android NDK needed: it's a pure-Go, CGO-free static PIE. `termux-elf-cleaner` (run by
`setup.sh` on the phone) plus launching through `/system/bin/linker64` makes it run under Android's
linker.
