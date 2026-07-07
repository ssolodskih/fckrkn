# Run yacfsocks on Android — step by step

Goal: your phone runs a small proxy in the background, and Telegram on the **same phone** uses it.
Follow the steps in order. Each step is copy-paste. Total time ~10 minutes.

## What you need before starting

**Two values**, from whoever set up the Cloud Function (they come from `deploy.sh`):

| Value | Looks like |
|-------|-----------|
| `FUNCTION_URL` | `https://functions.yandexcloud.net/d4abc123...` |
| `TOKEN` | a long random string, e.g. `8e93e78c99fc...` |

Keep these two handy — you enter them in **Step 3**, and nowhere else. (Or, even easier, ask them for
a ready-made **setup code** — see Step 3.)

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

## Step 3 — Run the installer (this is also where the two values go)

You have two ways. **No text editor either way.**

**Easiest — a setup code.** If the person who set up the function gave you a single line like
`bash setup.sh eHR0cHM6...`, just paste and run that:

```bash
cd yacfsocks/android
bash setup.sh <THE-LONG-CODE-THEY-GAVE-YOU>
```

That one code already contains both `FUNCTION_URL` and `TOKEN`. Done — skip to Step 4.

**Or — paste at the prompt.** If you only have the two values, run:

```bash
cd yacfsocks/android
bash setup.sh
```

It installs everything, then **asks you to paste** each value:

```
Paste FUNCTION_URL and press Enter:
> https://functions.yandexcloud.net/d4abc123...
Paste TOKEN and press Enter:
> 8e93e78c99fc...
```

(In Termux, paste = long-press the screen → Paste.) That's it — the values are saved to
`~/.config/yacfsocks/env` for you. You never open an editor.

## Step 4 — Test it

```bash
bash ~/.shortcuts/yacfsocks.sh
```

You should see:

```
yacfsocks SOCKS5 on 127.0.0.1:1080 ...
```

If instead it says `Set FUNCTION_URL + TOKEN ...`, re-run Step 3 — a value didn't get saved. Leave
this running and do Step 5 (or press **Ctrl-C** to stop; you'll relaunch from the widget).

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
- If Telegram stops working, just tap the widget again.

---

## Optional: start automatically after reboot

If you installed **Termux:Boot**: open it once (so Android allows it to run), and you're done —
`setup.sh` already installed the autostart script. After every reboot the proxy starts on its own.

## Keep Android from killing it

Android kills background apps to save battery. To keep the proxy alive:

- Settings → **Apps → Termux → Battery** → set to **Unrestricted** (disable battery optimization).
- On Xiaomi/MIUI, Huawei, Samsung: also open the recent-apps switcher and **lock** Termux so it
  isn't swiped away automatically.
- The "wake lock acquired" notification from Termux is normal — leave it.

## If something goes wrong

- **Telegram won't connect / stuck on "connecting":** re-check Step 3 (a wrong URL or token) by
  re-running it, then
  tap the widget again. Still stuck? In `~/.config/yacfsocks/env` set `DEBUG=1`, run
  `bash ~/.shortcuts/yacfsocks.sh`, and read the `ex ... up=.. down=..` lines.
- **`CERTIFICATE_VERIFY_FAILED`:** in `~/.config/yacfsocks/env` add a line `INSECURE=1`. Safe here —
  Telegram encrypts its own traffic inside the tunnel.
- **`command not found: termux-wake-lock`:** run `pkg install termux-api` (optional; the proxy still
  works without it).
- **Need a username/password on the proxy:** in `~/.config/yacfsocks/env` uncomment `SOCKS_USER` and
  `SOCKS_PASS`, then enter the same values in Telegram's proxy screen.

---

## For whoever deployed the function: hand out a one-line setup code

So the phone user never types a URL or token, generate a setup code on the machine that has the
secrets (reads `secrets.local.env`, or pass them inline):

```bash
cd android
./make-code.sh
# or: FUNCTION_URL=... TOKEN=... ./make-code.sh
```

It prints a single line — `bash setup.sh <CODE>` — to send them. That code carries both values, so
treat it as secret (same sensitivity as the token). The user pastes it in Step 3 and is done.

