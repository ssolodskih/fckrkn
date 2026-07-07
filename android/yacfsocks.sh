#!/data/data/com.termux/files/usr/bin/bash
# yacfsocks — homescreen-widget launcher (Termux:Widget runs this from ~/.shortcuts/).
# One tap: hold a wake lock, load config, start the local SOCKS5 client.
set -euo pipefail

CONFIG="$HOME/.config/yacfsocks/env"
APP="$HOME/.yacfsocks/client.py"

# Defaults. FUNCTION_URL/TOKEN are filled from ~/.config/yacfsocks/env, which
# setup.sh writes (from your gitignored secrets.local.env, or placeholders).
export FUNCTION_URL="https://functions.yandexcloud.net/REPLACE_WITH_FUNCTION_ID"
export TOKEN="REPLACE_WITH_TOKEN"
export LISTEN="127.0.0.1:1080"
export MAX_INFLIGHT="9"

# Config file provides the real values (and any overrides).
if [ -f "$CONFIG" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$CONFIG"
  set +a
fi

if [ "${FUNCTION_URL}" = "https://functions.yandexcloud.net/REPLACE_WITH_FUNCTION_ID" ] || [ "${TOKEN}" = "REPLACE_WITH_TOKEN" ]; then
  echo "Set FUNCTION_URL + TOKEN in $CONFIG (or run android/setup.sh)."
  exit 1
fi

# Keep the CPU awake so Android doze doesn't freeze the proxy in the background.
termux-wake-lock 2>/dev/null || true
trap 'termux-wake-unlock 2>/dev/null || true' EXIT

echo "Starting yacfsocks -> $FUNCTION_URL"
echo "Telegram: SOCKS5 ${LISTEN:-127.0.0.1:1080}   (Ctrl-C to stop)"
exec python "$APP"
