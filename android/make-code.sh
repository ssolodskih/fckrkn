#!/usr/bin/env bash
# Make the one-liner to hand a phone user, so they never type a URL, token, or
# edit a config file. Prints ready-to-send install commands.
#
# Values come from the environment or repo-root secrets.local.env:
#   ./make-code.sh
#   FUNCTION_URL=... TOKEN=... ./make-code.sh
#
# Override the storage bucket used in the primary one-liner with BUCKET=...
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
BUCKET="${BUCKET:-yacfsocks-dist}"

if { [ -z "${FUNCTION_URL:-}" ] || [ -z "${TOKEN:-}" ]; } && [ -f "$REPO/secrets.local.env" ]; then
  # shellcheck disable=SC1090
  . "$REPO/secrets.local.env"
fi

: "${FUNCTION_URL:?set FUNCTION_URL (or fill secrets.local.env)}"
: "${TOKEN:?set TOKEN (or fill secrets.local.env)}"

CODE="$(printf '%s|%s' "$FUNCTION_URL" "$TOKEN" | base64 | tr -d '\n')"

STORAGE="https://storage.yandexcloud.net/$BUCKET/install.sh"
GITHUB="https://raw.githubusercontent.com/ssolodskih/fckrkn/master/android/install.sh"

echo "Send the phone user ONE of these lines to paste in Termux."
echo "(It carries FUNCTION_URL + TOKEN — treat it like the token itself.)"
echo
echo "Works on the locked-down network (Yandex, whitelisted):"
echo
echo "    pkg install -y wget && wget -qO- \"$STORAGE\" | bash -s -- $CODE"
echo
echo "Fallback, only on an open network (GitHub):"
echo
echo "    pkg install -y wget && wget -qO- \"$GITHUB\" | bash -s -- $CODE"
echo
echo "Just the setup code (for the git-clone method: bash setup.sh <CODE>):"
echo
echo "    $CODE"
