#!/usr/bin/env bash
# Build, sign, and (optionally) publish the yacfsocks Android APK.
#
#   ./build.sh              # bind + assembleRelease -> signed APK
#   ./build.sh --publish    # also upload the APK to the Yandex bucket
#
# Toolchain (see README Step 0): Android cmdline-tools + platform-35 +
# build-tools 35.0.0 + ndk 27.2.12479018, gomobile/gobind, JDK 17.
#
# Signing: if YACF_KEYSTORE (+ YACF_KEYSTORE_PASS/YACF_KEY_ALIAS/YACF_KEY_PASS)
# is set — via env or repo-root secrets.local.env — assembleRelease produces a
# release-signed APK. Otherwise it falls back to the debug keystore (fine for
# personal sideload). This script generates a local keystore on first run if
# none is configured and you pass --release-key.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
BUCKET="${BUCKET:-yacfsocks-dist}"

PUBLISH=0
RELEASE_KEY=0
for a in "$@"; do
  case "$a" in
    --publish) PUBLISH=1 ;;
    --release-key) RELEASE_KEY=1 ;;
    *) echo "unknown arg: $a"; exit 2 ;;
  esac
done

# Pull optional signing/publish secrets.
if [ -f "$REPO/secrets.local.env" ]; then
  # shellcheck disable=SC1090
  . "$REPO/secrets.local.env"
fi

# --- Android SDK/NDK discovery ---
: "${ANDROID_HOME:=/opt/homebrew/share/android-commandlinetools}"
export ANDROID_HOME
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$ANDROID_HOME/ndk/27.2.12479018}"
export PATH="$PATH:$(go env GOPATH)/bin"

[ -d "$ANDROID_NDK_HOME" ] || { echo "NDK not found at $ANDROID_NDK_HOME — see README Step 0"; exit 1; }
command -v gomobile >/dev/null 2>&1 || { echo "gomobile not on PATH — go install golang.org/x/mobile/cmd/gomobile@latest"; exit 1; }

# --- optional: generate a local release keystore once ---
KEYSTORE_DEFAULT="$HERE/release.keystore"
if [ "$RELEASE_KEY" = 1 ] && [ ! -f "$KEYSTORE_DEFAULT" ]; then
  echo "==> Generating release keystore $KEYSTORE_DEFAULT"
  : "${YACF_KEYSTORE_PASS:?set YACF_KEYSTORE_PASS to create a keystore}"
  keytool -genkeypair -v -keystore "$KEYSTORE_DEFAULT" \
    -alias "${YACF_KEY_ALIAS:-yacf}" -keyalg RSA -keysize 2048 -validity 10000 \
    -storepass "$YACF_KEYSTORE_PASS" -keypass "${YACF_KEY_PASS:-$YACF_KEYSTORE_PASS}" \
    -dname "CN=yacfsocks, OU=self, O=self, L=-, S=-, C=-"
  export YACF_KEYSTORE="$KEYSTORE_DEFAULT"
  export YACF_KEY_ALIAS="${YACF_KEY_ALIAS:-yacf}"
  export YACF_KEY_PASS="${YACF_KEY_PASS:-$YACF_KEYSTORE_PASS}"
fi

# --- Step 1+2: bind the Go core into the .aar ---
echo "==> gomobile bind -> app/app/libs/yacf.aar"
mkdir -p "$HERE/app/app/libs"
( cd "$HERE/yacf" && gomobile bind -target=android/arm64,android/arm -androidapi 26 \
    -o "$HERE/app/app/libs/yacf.aar" . )

# --- Step 3: assemble the signed release APK ---
echo "==> gradlew assembleRelease"
( cd "$HERE/app" && ./gradlew --no-daemon assembleRelease )

APK="$(ls -t "$HERE"/app/app/build/outputs/apk/release/*.apk | head -1)"
[ -f "$APK" ] || { echo "APK not found"; exit 1; }
echo "==> Built $APK"
if [ -n "${YACF_KEYSTORE:-}" ]; then
  echo "    (release-signed)"
else
  echo "    (debug-signed — fine for personal sideload)"
fi

# --- Step 4: publish to the Yandex bucket ---
if [ "$PUBLISH" = 1 ]; then
  YC="${YC:-yc}"
  command -v "$YC" >/dev/null 2>&1 || YC=/Users/ssman/yandex-cloud/bin/yc
  if ! "$YC" storage bucket get --name "$BUCKET" >/dev/null 2>&1; then
    echo "==> Creating public bucket $BUCKET"
    "$YC" storage bucket create --name "$BUCKET" --public-read
  fi
  KEY="yacfsocks.apk"
  echo "==> Uploading $KEY"
  # Bucket is created --public-read (anonymous read), so objects are readable
  # without a per-object ACL; `yc storage s3 cp` rejects --acl on objects.
  "$YC" storage s3 cp "$APK" "s3://$BUCKET/$KEY" >/dev/null
  URL="https://storage.yandexcloud.net/$BUCKET/$KEY"
  echo
  echo "Published: $URL"
  echo "Works on the locked-down network (*.yandexcloud.net whitelisted)."
fi
