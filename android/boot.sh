#!/data/data/com.termux/files/usr/bin/bash
# yacfsocks - optional autostart on phone boot (needs the Termux:Boot app).
# Copied to ~/.termux/boot/ by setup.sh. Starts the proxy in the background so
# Telegram can reach 127.0.0.1:1080 right after the phone powers on.
set -euo pipefail
termux-wake-lock 2>/dev/null || true
exec bash "$HOME/.shortcuts/yacfsocks.sh"
