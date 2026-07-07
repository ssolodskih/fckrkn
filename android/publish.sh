#!/usr/bin/env bash
# Publish the Android installer assets to a public Yandex Object Storage bucket,
# so the phone can download them on the locked-down network (*.yandexcloud.net
# is whitelisted). Run on the machine that has `yc` authenticated.
#
#   ./publish.sh
#   BUCKET=my-bucket ./publish.sh
#
# Uploads (public-read): install.sh, bin/yacfsocks-linux-{arm64,amd64},
# yacfsocks.sh, boot.sh — the same relative paths install.sh fetches.
# Only non-secret assets go here; the token lives only in the setup code.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BUCKET="${BUCKET:-yacfsocks-dist}"
YC="${YC:-yc}"
command -v "$YC" >/dev/null 2>&1 || YC=/Users/ssman/yandex-cloud/bin/yc

ARM64="$HERE/bin/yacfsocks-linux-arm64"
AMD64="$HERE/bin/yacfsocks-linux-amd64"
[ -f "$ARM64" ] || { echo "missing $ARM64 — build first: cd ../client-go && ./build.sh"; exit 1; }

# Create the bucket (public-read) if it doesn't exist.
if ! "$YC" storage bucket get --name "$BUCKET" >/dev/null 2>&1; then
  echo "==> Creating public bucket $BUCKET"
  "$YC" storage bucket create --name "$BUCKET" --public-read
else
  echo "==> Bucket $BUCKET exists"
fi

put() { # <localfile> <key>
  echo "    -> $2"
  "$YC" storage s3 cp --acl public-read "$1" "s3://$BUCKET/$2" >/dev/null
}

echo "==> Uploading assets"
put "$HERE/install.sh"   "install.sh"
put "$ARM64"             "bin/yacfsocks-linux-arm64"
[ -f "$AMD64" ] && put "$AMD64" "bin/yacfsocks-linux-amd64"
put "$HERE/yacfsocks.sh" "yacfsocks.sh"
put "$HERE/boot.sh"      "boot.sh"

BASE="https://storage.yandexcloud.net/$BUCKET"
echo
echo "Published to $BASE"
echo "Verify:  curl -fsSL $BASE/install.sh | head -1"
echo
echo "Generate the user one-liner with:  BUCKET=$BUCKET ./make-code.sh"
