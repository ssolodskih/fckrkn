#!/usr/bin/env bash
# Cross-compile the Go client to static, dependency-free binaries.
# Output goes to ../android/bin/ so the Android bundle can ship them.
#
#   ./build.sh            # arm64 (phones) + amd64 (desktop test)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/../android/bin"
mkdir -p "$OUT"

# CGO off => fully static, no libc dependency. PIE => runs under Android's
# linker (Termux requires position-independent executables).
export CGO_ENABLED=0

build() {
  local goos="$1" goarch="$2" name="$3"
  echo "==> $goos/$goarch -> $name"
  ( cd "$HERE" && GOOS="$goos" GOARCH="$goarch" \
      go build -trimpath -buildmode=pie -ldflags "-s -w" -o "$OUT/$name" . )
}

# Android phones are arm64. (32-bit arm needs cgo for PIE; skipped - arm64
# covers effectively every phone from the last decade.)
build linux arm64 yacfsocks-linux-arm64
# Handy for testing the exact binary logic on a Linux desktop.
build linux amd64 yacfsocks-linux-amd64

echo
echo "Built:"
ls -la "$OUT"
