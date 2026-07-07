#!/data/data/com.termux/files/usr/bin/bash
# yacfsocks — homescreen-widget launcher (Termux:Widget runs this from ~/.shortcuts/).
# One tap: hold a wake lock, load config, start the Go proxy binary.
set -euo pipefail

CONFIG="$HOME/.config/yacfsocks/env"
BIN="$HOME/.yacfsocks/yacfsocks"

if [ ! -x "$BIN" ]; then
  echo "Proxy binary missing at $BIN — run android/setup.sh first."
  exit 1
fi

# Defaults; the config file supplies the real FUNCTION_URL + TOKEN.
export FUNCTION_URL="https://functions.yandexcloud.net/REPLACE_WITH_FUNCTION_ID"
export TOKEN="REPLACE_WITH_TOKEN"
export LISTEN="127.0.0.1:1080"
export MAX_INFLIGHT="9"

if [ -f "$CONFIG" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$CONFIG"
  set +a
fi

if [ "${FUNCTION_URL}" = "https://functions.yandexcloud.net/REPLACE_WITH_FUNCTION_ID" ] || [ "${TOKEN}" = "REPLACE_WITH_TOKEN" ]; then
  echo "Set FUNCTION_URL + TOKEN in $CONFIG (re-run android/setup.sh)."
  exit 1
fi

# Keep the CPU awake so Android doze doesn't freeze the proxy in the background.
termux-wake-lock 2>/dev/null || true
trap 'termux-wake-unlock 2>/dev/null || true' EXIT

echo "Starting yacfsocks -> $FUNCTION_URL"
echo "Telegram: SOCKS5 ${LISTEN}   (Ctrl-C to stop)"

# The binary is a cross-compiled Go PIE; its ELF interpreter is a glibc path
# that doesn't exist on Android. Start it through Android's own linker, which
# ignores that field. Fall back to a direct exec (e.g. on a Linux desktop).
if [ -x /system/bin/linker64 ]; then
  exec /system/bin/linker64 "$BIN"
else
  exec "$BIN"
fi
