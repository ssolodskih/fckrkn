# yacfsocks — native Android APK

A standalone Android app that runs the yacfsocks SOCKS5 proxy natively — no
Termux, no F-Droid, no shell hacks. It listens on `127.0.0.1:1080`; point
Telegram (or any app) at that SOCKS5 address.

This is a self-contained track under `android-apk/`. It does not touch the
Termux client (`android/`) or the Go client (`client-go/`) — those still work as
before. The relay core here is a copy of `client-go/main.go` adapted for
in-process use (`android-apk/yacf/`), bound into a `.aar` with **gomobile** and
driven by a small Kotlin app.

Why an app instead of the Termux binary: as a normal Android app the three
on-device hacks the Termux path needs all disappear — DNS resolves through the
cgo Bionic resolver (`getaddrinfo`), TLS trust comes from `x509.SystemCertPool`
(which knows Android's CA dirs on `GOOS=android`), and there is no bundled ELF
executable to relaunch. The wire protocol is unchanged; the deployed function is
untouched.

## User side — install and use

1. **Download** the signed APK from the Yandex URL (reachable on the
   locked-down network, since `*.yandexcloud.net` is whitelisted):

       https://storage.yandexcloud.net/yacfsocks-dist/yacfsocks.apk

2. **Sideload** it: open the file, allow "install unknown apps" for your browser
   / file manager when prompted, install.
3. **Open** the app, paste your **setup code** (base64 of `FUNCTION_URL|TOKEN`,
   the same code `android/make-code.sh` prints) into the top field — or type the
   URL and token into the two fields below. Tap **ON**.
   - Grant the notification permission and, when asked, allow the app to ignore
     battery optimization (keeps the proxy alive in the background).
4. In **Telegram**: Settings → Data and Storage → Proxy → Add proxy → **SOCKS5**,
   host `127.0.0.1`, port `1080`, no username/password. Chats load.
5. Optional: tick **Autostart on boot** so the proxy comes back after a reboot.

A persistent notification shows status (`open <host> -> <sid>` lines) and a Stop
action.

## Build side

### Step 0 — one-time toolchain (macOS)

```sh
brew install --cask android-commandlinetools
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
yes | sdkmanager --sdk_root="$ANDROID_HOME" --licenses
sdkmanager --sdk_root="$ANDROID_HOME" \
  "platform-tools" "platforms;android-35" "build-tools;35.0.0" "ndk;27.2.12479018"
export ANDROID_NDK_HOME=$ANDROID_HOME/ndk/27.2.12479018

go install golang.org/x/mobile/cmd/gomobile@latest
go install golang.org/x/mobile/cmd/gobind@latest
(cd android-apk/yacf && gomobile init)
```

Requires JDK 17 (`brew install --cask temurin` if needed). The committed Gradle
wrapper (`app/gradlew`, Gradle 8.9) pulls AGP 8.5.2 + Kotlin 1.9.24 on first run.

### Step 1 — build (+ sign, + publish)

```sh
cd android-apk
./build.sh              # gomobile bind -> yacf.aar, then gradlew assembleRelease
./build.sh --publish    # also upload the signed APK to the yacfsocks-dist bucket
```

Output: `android-apk/app/app/build/outputs/apk/release/app-release.apk`.

**Signing.** By default the release APK is signed with the Android **debug**
keystore — fine for personal sideloading. For a stable release key, set these in
repo-root `secrets.local.env` (gitignored) or the environment, then rebuild:

```sh
export YACF_KEYSTORE=/path/to/release.keystore
export YACF_KEYSTORE_PASS=...
export YACF_KEY_ALIAS=yacf
export YACF_KEY_PASS=...
```

Or let the script create one for you: `YACF_KEYSTORE_PASS=... ./build.sh --release-key`.
Keystores are gitignored (`*.keystore`, `*.jks`) — never commit them.

## Layout

```
android-apk/
  yacf/                     Go module (module yacfapk/yacf) — the bindable relay core
    yacf.go                 Start/Stop/Running/SetDebug + Logger; adapted from client-go/main.go
    cmd/desktop/main.go     runs the core on a desktop for testing (not shipped)
  app/                      Gradle project (Kotlin DSL) + committed wrapper
    app/libs/yacf.aar       gomobile output (generated, gitignored)
    app/src/main/
      AndroidManifest.xml
      java/io/yacf/MainActivity.kt   setup-code UI + ON/OFF + autostart
      java/io/yacf/ProxyService.kt   foreground service owning the listener
      java/io/yacf/BootReceiver.kt   optional autostart on boot
      java/io/yacf/Store.kt          EncryptedSharedPreferences creds store
  build.sh                  bind + assembleRelease + sign + optional publish
```

## Test the core without a phone

The desktop harness runs the exact copied core against the live function:

```sh
set -a; . ../secrets.local.env; set +a
cd yacf
DEBUG=1 go run ./cmd/desktop        # listens on 127.0.0.1:1080
# in another shell, drive it through the SOCKS proxy (Telegram IPs only —
# the function allowlists Telegram CIDRs and rejects other destinations):
curl -sS --max-time 40 -k -x socks5h://127.0.0.1:1080 https://149.154.167.51/ -o /dev/null -w '%{http_code}\n'
```

`DEBUG=1` logs show `open ... -> <sid>` and `ex ... up/down` — proof the tunnel
round-trips.

## Notes / caveats

- **Loopback across apps.** Telegram runs as a separate app/UID connecting to
  `127.0.0.1:1080` where this app listens — standard on Android (how SocksDroid
  and similar work). Confirm on your phone.
- **Battery/doze.** The foreground service + battery-optimization exemption keep
  it alive, but aggressive vendor power managers (MIUI/Huawei/etc.) can still
  kill background apps — whitelist the app in the vendor battery settings.
- **Android 14+** requires a declared foreground-service type; the service
  declares `dataSync`.
- **Sideload** requires allowing unknown sources — unavoidable off the Play Store.
