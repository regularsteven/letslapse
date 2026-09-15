#!/bin/zsh
# sim-fresh.sh — a fresh iOS Simulator running LetsLapse against picplace.test.
#
#   tools/sim-fresh.sh                      erase "iPhone 16 Pro", build, install, launch
#   tools/sim-fresh.sh --device "iPhone 17 Pro"
#   tools/sim-fresh.sh --new                create a new device ("LetsLapse Fresh") instead of erasing
#   tools/sim-fresh.sh --keep               do not erase (reinstall over the existing library)
#   tools/sim-fresh.sh --no-build           reuse the last build
#
# The steps, in order: shut the device down · erase it (or create a new one) ·
# build the app for the Simulator, signed to run locally (an unsigned build
# carries no entitlements and the Simulator's keychain refuses the PicPlace
# sign-in with -34018) · boot it and open Simulator.app · trust the Valet CA so
# https://picplace.test works · install · launch. Sign in is yours: Settings ›
# PicPlace › Sign in with PicPlace (the Debug build on the Simulator talks to
# picplace.test). Everything is idempotent; re-run it whenever you want a
# clean device.
set -euo pipefail

DEVICE_NAME="iPhone 16 Pro"
MODE="erase"          # erase | new | keep
BUILD=1
BUNDLE_ID="com.regularsteven.letslapse"
NEW_NAME="LetsLapse Fresh"
VALET_CA="${VALET_CA:-$HOME/.config/valet/CA/LaravelValetCASelfSigned.pem}"
DD="${LL_SIM_DERIVED_DATA:-$HOME/Library/Developer/LetsLapseRun/dd-sim-fresh}"

while [ $# -gt 0 ]; do
  case "$1" in
    --device) DEVICE_NAME="$2"; shift 2 ;;
    --new) MODE="new"; shift ;;
    --keep) MODE="keep"; shift ;;
    --no-build) BUILD=0; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

UNIT="$(cd "$(dirname "$0")/.." && pwd)"          # LetsLapse/
APP="$DD/Build/Products/Debug-iphonesimulator/LetsLapse.app"
step() { print -P "%F{yellow}▶ $1%f"; }

# 1. The device.
if [ "$MODE" = "new" ]; then
  step "Creating a new simulator '$NEW_NAME' ($DEVICE_NAME, newest iOS runtime)"
  UDID=$(python3 - "$DEVICE_NAME" "$NEW_NAME" <<'PY'
import json, subprocess, sys
device_type_name, new_name = sys.argv[1], sys.argv[2]
types = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devicetypes", "-j"]))["devicetypes"]
dtype = next(t["identifier"] for t in types if t["name"] == device_type_name)
runtimes = [r for r in json.loads(subprocess.check_output(["xcrun", "simctl", "list", "runtimes", "-j"]))["runtimes"]
            if r["platform"] == "iOS" and r["isAvailable"]]
runtime = sorted(runtimes, key=lambda r: [int(x) for x in r["version"].split(".")])[-1]["identifier"]
print(subprocess.check_output(["xcrun", "simctl", "create", new_name, dtype, runtime]).decode().strip())
PY
  )
else
  UDID=$(xcrun simctl list devices available | grep -F "$DEVICE_NAME (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
  [ -n "$UDID" ] || { echo "no available simulator named '$DEVICE_NAME' — xcrun simctl list devices available" >&2; exit 1; }
fi
echo "   $DEVICE_NAME → $UDID"

# 2 + 3. Down, and clean.
xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
if [ "$MODE" = "erase" ]; then
  step "Erasing $UDID (library, keychain, everything)"
  xcrun simctl erase "$UDID"
fi

# 4. The build.
if [ "$BUILD" = 1 ]; then
  step "Building LetsLapse for the Simulator (arm64, signed to run locally) → $DD"
  LOG="$DD/sim-fresh-build.log"; mkdir -p "$DD"
  if ! xcodebuild -project "$UNIT/LetsLapse.xcodeproj" -scheme LetsLapse -configuration Debug \
      -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DD" \
      ARCHS=arm64 CODE_SIGN_IDENTITY=- build > "$LOG" 2>&1; then
    grep -E " error:|BUILD" "$LOG" | head -20 >&2
    echo "build failed — full log: $LOG" >&2; exit 1
  fi
  echo "   built $APP"
fi
[ -d "$APP" ] || { echo "no app at $APP — run without --no-build" >&2; exit 1; }

# 5. Up.
step "Booting"
xcrun simctl boot "$UDID" >/dev/null 2>&1 || true
open -a Simulator
xcrun simctl bootstatus "$UDID" -b >/dev/null

# 6. The certificate picplace.test answers with.
if [ -f "$VALET_CA" ]; then
  step "Trusting the Valet CA ($VALET_CA)"
  xcrun simctl keychain "$UDID" add-root-cert "$VALET_CA"
else
  echo "   (no Valet CA at $VALET_CA — https://picplace.test will not be trusted; set VALET_CA=...)" >&2
fi

# 7 + 8. In, and running.
step "Installing and launching $BUNDLE_ID"
xcrun simctl install "$UDID" "$APP"
xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null

cat <<EOT

Ready. The first launch opens the capture screen and asks for camera access — Allow (or not), tap ✕ for the tabs,
then Settings › PicPlace › Sign in with PicPlace (picplace.test), then Connect.
Device: $UDID
Log:    tail -f "\$(ls -t ~/Library/Developer/CoreSimulator/Devices/$UDID/data/Containers/Data/Application/*/Library/Application\\ Support/LetsLapse/Logs/console-*.log | head -1)"
EOT
