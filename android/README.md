# Run yacfsocks on Android — step by step

Goal: your phone runs a small proxy in the background, and Telegram on the **same phone** uses it.
Follow the steps in order. Each step is copy-paste. Total time ~10 minutes.

## What you need before starting

**Two values**, from whoever set up the Cloud Function (they come from `deploy.sh`):

| Value | Looks like |
|-------|-----------|
| `FUNCTION_URL` | `https://functions.yandexcloud.net/d4abc123...` |
| `TOKEN` | a long random string, e.g. `8e93e78c99fc...` |

Keep these two handy — you paste them in **Step 4**, and nowhere else.

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

## Step 3 — Run the installer

```bash
cd yacfsocks/android
bash setup.sh
```

This installs Python, copies the proxy into place, and creates the homescreen launcher. It also
creates the **one config file** you edit in the next step:
`~/.config/yacfsocks/env`.

## Step 4 — Paste your two values (THE important step)

Open the config file:

```bash
nano ~/.config/yacfsocks/env
```

You'll see two lines starting with `FUNCTION_URL=` and `TOKEN=`. Replace the placeholder after each
`=` with your real value, so they look like:

```
FUNCTION_URL=https://functions.yandexcloud.net/d4abc123...
TOKEN=8e93e78c99fc...
```

Leave the rest of the file alone. Save and exit: **Ctrl-O**, then **Enter**, then **Ctrl-X**.

> This file lives on your phone only. It is the single place secrets go — you never edit anything
> else.

## Step 5 — Test it

```bash
bash ~/.shortcuts/yacfsocks.sh
```

You should see:

```
yacfsocks SOCKS5 on 127.0.0.1:1080 ...
```

If instead it says `Set FUNCTION_URL + TOKEN ...`, go back to Step 4 — a value is still a
placeholder. Leave this running and do Step 6 (or press **Ctrl-C** to stop; you'll relaunch from the
widget).

## Step 6 — Point Telegram at it

Telegram → **Settings → Data and Storage → Proxy → Add proxy → SOCKS5**

- **Server:** `127.0.0.1`
- **Port:** `1080`
- Username/Password: leave empty.

Turn the proxy **on**. Your chats should load.

## Step 7 — The one-tap button

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

- **Telegram won't connect / stuck on "connecting":** re-check Step 4 (a wrong URL or token), then
  tap the widget again. Still stuck? In `~/.config/yacfsocks/env` set `DEBUG=1`, run
  `bash ~/.shortcuts/yacfsocks.sh`, and read the `ex ... up=.. down=..` lines.
- **`CERTIFICATE_VERIFY_FAILED`:** in `~/.config/yacfsocks/env` add a line `INSECURE=1`. Safe here —
  Telegram encrypts its own traffic inside the tunnel.
- **`command not found: termux-wake-lock`:** run `pkg install termux-api` (optional; the proxy still
  works without it).
- **Need a username/password on the proxy:** in `~/.config/yacfsocks/env` uncomment `SOCKS_USER` and
  `SOCKS_PASS`, then enter the same values in Telegram's proxy screen.
