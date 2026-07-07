#!/data/data/com.termux/files/usr/bin/bash
# yacfsocks — one-time Android/Termux setup (Go binary, no Python).
#
# Run this ONCE inside Termux:
#   bash setup.sh                 # then paste FUNCTION_URL + TOKEN when asked
#   bash setup.sh <SETUP-CODE>    # one-liner from make-code.sh (carries both)
#
# It installs a tiny ELF fixer, drops the prebuilt proxy binary into place, and
# creates a homescreen-widget launcher so you can start the proxy with one tap.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

CONFIG_DIR="$HOME/.config/yacfsocks"
APP_DIR="$HOME/.yacfsocks"
SHORTCUTS_DIR="$HOME/.shortcuts"
BOOT_DIR="$HOME/.termux/boot"
BIN="$APP_DIR/yacfsocks"

# --- pick the right prebuilt binary for this CPU -----------------------------
ARCH="$(uname -m)"
case "$ARCH" in
  aarch64|arm64) SRC="$HERE/bin/yacfsocks-linux-arm64" ;;
  x86_64|amd64)  SRC="$HERE/bin/yacfsocks-linux-amd64" ;;
  *) echo "Unsupported CPU '$ARCH'. Only arm64/amd64 binaries are shipped."; exit 1 ;;
esac
if [ ! -f "$SRC" ]; then
  echo "Missing binary $SRC — build it first: (on a computer) cd client-go && ./build.sh"
  exit 1
fi

# --- install binary ----------------------------------------------------------
# The binary is a cross-compiled Go PIE with no library deps. Android's linker
# is stricter than glibc's, so run termux-elf-cleaner over it once; the launcher
# then starts it through /system/bin/linker64. No Python, no glibc, no pip.
echo "==> Installing termux-elf-cleaner (tiny, one-time)"
pkg update -y
pkg install -y termux-elf-cleaner

echo "==> Installing proxy binary to $BIN"
mkdir -p "$APP_DIR"
cp "$SRC" "$BIN"
termux-elf-cleaner "$BIN" >/dev/null 2>&1 || true
chmod +x "$BIN"

# --- resolve FUNCTION_URL + TOKEN with the least friction --------------------
#   1. environment    2. setup code $1    3. secrets.local.env    4. prompt
echo "==> Configuring FUNCTION_URL + TOKEN"
mkdir -p "$CONFIG_DIR"
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

if [ -z "$FUNC_URL_VAL" ] && [ -t 0 ]; then
  printf '    Paste FUNCTION_URL and press Enter:\n    > '; read -r FUNC_URL_VAL
fi
if [ -z "$TOKEN_VAL" ] && [ -t 0 ]; then
  printf '    Paste TOKEN and press Enter:\n    > '; read -r TOKEN_VAL
fi

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

# --- launcher + optional boot autostart --------------------------------------
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
  echo "  (or re-run: bash setup.sh <SETUP-CODE>)"
else
  echo "Config has your FUNCTION_URL + TOKEN ($CONFIG_DIR/env)."
fi
echo
echo "Then:"
echo "  - Test it:   bash $SHORTCUTS_DIR/yacfsocks.sh   (expect: SOCKS5 on 127.0.0.1:1080)"
echo "  - Add the homescreen widget: Termux:Widget -> yacfsocks (one tap to start)."
echo "  - Telegram -> Settings -> Data and Storage -> Proxy -> Add SOCKS5:"
echo "        Server 127.0.0.1   Port 1080"
echo
echo "Full guide: yacfsocks/android/README.md"
