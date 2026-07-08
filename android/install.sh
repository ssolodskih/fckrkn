#!/data/data/com.termux/files/usr/bin/bash
# yacfsocks — one-liner Android/Termux installer (no git, no repo clone).
#
# Paste in Termux (the deployer gives you the exact line with a setup code):
#   pkg install -y wget && wget -qO- "https://storage.yandexcloud.net/yacfsocks-dist/install.sh" | bash -s -- <SETUP-CODE>
#
# Downloads the Go proxy binary + launcher, writes your config, and installs a
# homescreen-widget launcher. No Python, no pip.
#
# Override the download source with YACF_BASE=... (e.g. file://<repo>/android
# for local testing). Skip the Termux-only steps with YACF_STUB=1.
set -euo pipefail

# Download sources, tried in order. Storage first (whitelisted on the locked-down
# network); GitHub raw as a fallback (needs an open network).
BASES=(
  "${YACF_BASE:-https://storage.yandexcloud.net/yacfsocks-dist}"
  "https://raw.githubusercontent.com/ssolodskih/fckrkn/master/android"
)

CONFIG_DIR="$HOME/.config/yacfsocks"
APP_DIR="$HOME/.yacfsocks"
SHORTCUTS_DIR="$HOME/.shortcuts"
BOOT_DIR="$HOME/.termux/boot"
BIN="$APP_DIR/yacfsocks"

# dl <url> <outfile> — download with whatever works. Prefer wget: a broken
# Termux curl (openssl/HTTP-3 symbol mismatch) is common, and wget doesn't pull
# in the QUIC libs that break. Fall back to curl if wget is absent.
dl() {
  local url="$1" out="$2"
  if command -v wget >/dev/null 2>&1 && wget -q -O "$out" "$url" 2>/dev/null; then
    return 0
  fi
  if command -v curl >/dev/null 2>&1 && curl -fsSL "$url" -o "$out" 2>/dev/null; then
    return 0
  fi
  return 1
}

# fetch <relpath> <outfile> — try each base until one works.
fetch() {
  local rel="$1" out="$2" b
  for b in "${BASES[@]}"; do
    if dl "$b/$rel" "$out"; then
      return 0
    fi
  done
  echo "download failed for '$rel' (tried: ${BASES[*]})" >&2
  return 1
}

# --- pick the right binary for this CPU --------------------------------------
ARCH="$(uname -m)"
case "$ARCH" in
  aarch64|arm64) BINREL="bin/yacfsocks-linux-arm64" ;;
  x86_64|amd64)  BINREL="bin/yacfsocks-linux-amd64" ;;
  *) echo "Unsupported CPU '$ARCH'. Only arm64/amd64 are shipped."; exit 1 ;;
esac

STUB="${YACF_STUB:-0}"

# --- install binary + launcher scripts ---------------------------------------
if [ "$STUB" != "1" ]; then
  echo "==> Installing termux-elf-cleaner (tiny, one-time)"
  pkg update -y
  pkg install -y termux-elf-cleaner
fi

echo "==> Downloading proxy binary -> $BIN"
mkdir -p "$APP_DIR"
fetch "$BINREL" "$BIN"
if [ "$STUB" != "1" ]; then
  termux-elf-cleaner "$BIN" >/dev/null 2>&1 || true
fi
chmod +x "$BIN"

echo "==> Downloading launcher"
mkdir -p "$SHORTCUTS_DIR" "$BOOT_DIR"
fetch "yacfsocks.sh" "$SHORTCUTS_DIR/yacfsocks.sh"
chmod +x "$SHORTCUTS_DIR/yacfsocks.sh"
fetch "boot.sh" "$BOOT_DIR/yacfsocks-boot.sh"
chmod +x "$BOOT_DIR/yacfsocks-boot.sh"

# --- resolve FUNCTION_URL + TOKEN --------------------------------------------
#   1. setup code $1   2. environment   3. interactive prompt (via /dev/tty)
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

# Under `curl | bash`, stdin is the script, not the keyboard — so prompt on the
# controlling terminal explicitly.
if [ -z "$FUNC_URL_VAL" ] || [ -z "$TOKEN_VAL" ]; then
  if [ -e /dev/tty ]; then
    [ -z "$FUNC_URL_VAL" ] && { printf '    Paste FUNCTION_URL and press Enter:\n    > ' >/dev/tty; read -r FUNC_URL_VAL </dev/tty; }
    [ -z "$TOKEN_VAL" ]    && { printf '    Paste TOKEN and press Enter:\n    > '        >/dev/tty; read -r TOKEN_VAL </dev/tty; }
  fi
fi

if [ -z "$FUNC_URL_VAL" ] || [ -z "$TOKEN_VAL" ]; then
  echo
  echo "No FUNCTION_URL/TOKEN provided. Re-run with a setup code:" >&2
  echo "    ... | bash -s -- <SETUP-CODE>" >&2
  echo "(ask whoever deployed the function for it)" >&2
  exit 1
fi

echo "==> Writing config to $CONFIG_DIR/env"
{
  cat <<EOF
# yacfsocks client config. Written by install.sh.
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

echo
echo "Installed. Next:"
echo "  - Test it:   bash $SHORTCUTS_DIR/yacfsocks.sh   (expect: SOCKS5 on 127.0.0.1:1080)"
echo "  - Add the homescreen widget: Termux:Widget -> yacfsocks (one tap to start)."
echo "  - Telegram -> Settings -> Data and Storage -> Proxy -> Add SOCKS5:"
echo "        Server 127.0.0.1   Port 1080"
