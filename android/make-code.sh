#!/usr/bin/env bash
# Make a one-line "setup code" to hand to a phone user, so they never edit a
# config file. They run:  bash setup.sh <CODE>
#
# Values come from the environment or repo-root secrets.local.env:
#   ./make-code.sh
#   FUNCTION_URL=... TOKEN=... ./make-code.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

if { [ -z "${FUNCTION_URL:-}" ] || [ -z "${TOKEN:-}" ]; } && [ -f "$REPO/secrets.local.env" ]; then
  # shellcheck disable=SC1090
  . "$REPO/secrets.local.env"
fi

: "${FUNCTION_URL:?set FUNCTION_URL (or fill secrets.local.env)}"
: "${TOKEN:?set TOKEN (or fill secrets.local.env)}"

CODE="$(printf '%s|%s' "$FUNCTION_URL" "$TOKEN" | base64 | tr -d '\n')"

echo "Send the phone user this one line:"
echo
echo "    bash setup.sh $CODE"
echo
echo "(It carries FUNCTION_URL + TOKEN — treat it like the token itself.)"
