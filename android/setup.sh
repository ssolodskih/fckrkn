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

echo "==> Writing config to $CONFIG_DIR/env"
mkdir -p "$CONFIG_DIR"
# If you keep real values in repo-root secrets.local.env (gitignored), use them;
# otherwise write placeholders you fill in by hand.
SECRETS="$REPO/secrets.local.env"
FUNC_URL_VAL="https://functions.yandexcloud.net/REPLACE_WITH_FUNCTION_ID"
TOKEN_VAL="REPLACE_WITH_TOKEN"
if [ -f "$SECRETS" ]; then
  # shellcheck disable=SC1090
  . "$SECRETS"
  FUNC_URL_VAL="${FUNCTION_URL:-$FUNC_URL_VAL}"
  TOKEN_VAL="${TOKEN:-$TOKEN_VAL}"
  echo "    using values from $SECRETS"
fi
if [ ! -f "$CONFIG_DIR/env" ]; then
  cat > "$CONFIG_DIR/env" <<EOF
# yacfsocks client config. Set FUNCTION_URL + TOKEN (from deploy.sh output).
FUNCTION_URL=$FUNC_URL_VAL
TOKEN=$TOKEN_VAL
EOF
  cat >> "$CONFIG_DIR/env" <<'EOF'

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
  echo "    created (edit FUNCTION_URL + TOKEN)"
else
  echo "    already exists, kept"
fi

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
