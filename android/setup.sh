#!/data/data/com.termux/files/usr/bin/bash
# yacfsocks — one-time Android/Termux setup.
#
# Run this ONCE inside Termux:
#   bash setup.sh
#
# It installs Python, copies the client, and creates a homescreen-widget
# launcher so you can start the proxy with a single tap. After it finishes,
# edit ~/.config/yacfsocks/env with your FUNCTION_URL and TOKEN.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

CONFIG_DIR="$HOME/.config/yacfsocks"
APP_DIR="$HOME/.yacfsocks"
SHORTCUTS_DIR="$HOME/.shortcuts"
BOOT_DIR="$HOME/.termux/boot"

echo "==> Installing Python + certifi"
pkg update -y
pkg install -y python
python -m pip install --upgrade pip >/dev/null 2>&1 || true
python -m pip install certifi >/dev/null 2>&1 || true

echo "==> Copying client to $APP_DIR"
mkdir -p "$APP_DIR"
cp "$REPO/client/client.py" "$APP_DIR/client.py"

echo "==> Configuring FUNCTION_URL + TOKEN"
mkdir -p "$CONFIG_DIR"

# Resolve the two secrets with the least friction, in priority order:
#   1. environment:   FUNCTION_URL=... TOKEN=... bash setup.sh
#   2. setup code:     bash setup.sh <CODE>     (one string, base64 of "URL|TOKEN")
#   3. repo-root secrets.local.env (gitignored, for the person who deployed)
#   4. interactive paste prompt (no editor needed)
FUNC_URL_VAL="${FUNCTION_URL:-}"
TOKEN_VAL="${TOKEN:-}"

if { [ -z "$FUNC_URL_VAL" ] || [ -z "$TOKEN_VAL" ]; } && [ -n "${1:-}" ]; then
  decoded="$(printf '%s' "$1" | base64 -d 2>/dev/null || true)"
  if [ -n "$decoded" ] && [ "$decoded" != "${decoded#*|}" ]; then
    FUNC_URL_VAL="${decoded%%|*}"
    TOKEN_VAL="${decoded#*|}"
    echo "    using the setup code you passed"
  else
    echo "    (ignoring unreadable setup code)"
  fi
fi

if { [ -z "$FUNC_URL_VAL" ] || [ -z "$TOKEN_VAL" ]; } && [ -f "$REPO/secrets.local.env" ]; then
  # shellcheck disable=SC1090
  . "$REPO/secrets.local.env"
  FUNC_URL_VAL="${FUNC_URL_VAL:-${FUNCTION_URL:-}}"
  TOKEN_VAL="${TOKEN_VAL:-${TOKEN:-}}"
  echo "    using values from secrets.local.env"
fi

# Interactive paste — only if still missing and we have a terminal.
if [ -z "$FUNC_URL_VAL" ] && [ -t 0 ]; then
  printf '    Paste FUNCTION_URL and press Enter:\n    > '; read -r FUNC_URL_VAL
fi
if [ -z "$TOKEN_VAL" ] && [ -t 0 ]; then
  printf '    Paste TOKEN and press Enter:\n    > '; read -r TOKEN_VAL
fi

# Last resort (non-interactive, nothing supplied): placeholders.
FUNC_URL_VAL="${FUNC_URL_VAL:-https://functions.yandexcloud.net/REPLACE_WITH_FUNCTION_ID}"
TOKEN_VAL="${TOKEN_VAL:-REPLACE_WITH_TOKEN}"

echo "==> Writing config to $CONFIG_DIR/env"
{
  cat <<EOF
# yacfsocks client config. Written by setup.sh.
FUNCTION_URL=$FUNC_URL_VAL
TOKEN=$TOKEN_VAL
EOF
  cat <<'EOF'

# Optional. Uncomment to require SOCKS auth from Telegram.
#SOCKS_USER=me
#SOCKS_PASS=secret

# Listen address. Telegram on THIS phone reaches 127.0.0.1. Use 0.0.0.0 only
# if another device on your LAN should use this phone as the proxy.
LISTEN=127.0.0.1:1080

# YC zone quota is 10 concurrent calls; stay under it.
MAX_INFLIGHT=9

# Set to 1 only if TLS verification fails (bytes are inside MTProto anyway).
#INSECURE=1

# Set to 1 for verbose per-exchange logging.
#DEBUG=1
EOF
} > "$CONFIG_DIR/env"

echo "==> Installing widget launcher to $SHORTCUTS_DIR"
mkdir -p "$SHORTCUTS_DIR"
cp "$HERE/yacfsocks.sh" "$SHORTCUTS_DIR/yacfsocks.sh"
chmod +x "$SHORTCUTS_DIR/yacfsocks.sh"

echo "==> Installing boot autostart to $BOOT_DIR (optional; needs Termux:Boot)"
mkdir -p "$BOOT_DIR"
cp "$HERE/boot.sh" "$BOOT_DIR/yacfsocks-boot.sh"
chmod +x "$BOOT_DIR/yacfsocks-boot.sh"

echo
if grep -q "REPLACE_WITH_" "$CONFIG_DIR/env" 2>/dev/null; then
  echo "IMPORTANT — do this now:"
  echo "  Put your FUNCTION_URL and TOKEN into the config file:"
  echo "      nano $CONFIG_DIR/env"
  echo "  Replace the two REPLACE_WITH_... placeholders, save (Ctrl-O, Enter, Ctrl-X)."
else
  echo "Config already has your FUNCTION_URL + TOKEN ($CONFIG_DIR/env)."
fi
echo
echo "Then:"
echo "  - Test it:            bash $SHORTCUTS_DIR/yacfsocks.sh   (expect: SOCKS5 on 127.0.0.1:1080)"
echo "  - Add the homescreen widget: Termux:Widget -> yacfsocks (one tap to start)."
echo "  - Telegram -> Settings -> Data and Storage -> Proxy -> Add SOCKS5:"
echo "        Server 127.0.0.1   Port 1080"
echo
echo "Full guide: yacfsocks/android/README.md"
