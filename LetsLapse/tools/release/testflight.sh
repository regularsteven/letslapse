#!/bin/bash
#
# Build a TestFlight-ready archive of LetsLapse, and optionally upload it.
#
#   ./tools/release/testflight.sh                 # archive + export an .ipa
#   ./tools/release/testflight.sh --upload        # ...and send it to TestFlight
#   ./tools/release/testflight.sh --build 512     # pin the build number
#   ./tools/release/testflight.sh --platform macos
#
# Producing a build and publishing one are deliberately separate: without
# --upload nothing leaves this machine.
#
# CREDENTIALS. This needs an App Store Connect API key — not just for the
# upload, but for the export too, because signing for distribution means
# minting an Apple Distribution certificate and an App Store profile, and
# xcodebuild can only do that if it can talk to the developer site. (The
# alternative is signing in to Xcode ▸ Settings ▸ Accounts and letting it
# manage them; then the export works with no key set, but the upload still
# needs one.)
#
#   export ASC_KEY_ID=XXXXXXXXXX
#   export ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
#
# Put the .p8 at ~/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8 —
# that is where altool looks for it, and the name matters. It downloads exactly
# once and cannot be re-downloaded, so back it up somewhere that isn't this
# repo. Override the location with ASC_KEY_PATH if you keep it elsewhere.
#
# See docs/testflight.md for the full runbook.

set -euo pipefail

cd "$(dirname "$0")/../.."   # repo's LetsLapse/ directory

PLATFORM=ios
UPLOAD=0
BUILD_NUMBER=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --platform) PLATFORM="$2"; shift 2 ;;
        --build)    BUILD_NUMBER="$2"; shift 2 ;;
        --upload)   UPLOAD=1; shift ;;
        -h|--help)  sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

# The build number has to rise with every upload for a given marketing version,
# and it has to be traceable back to a commit when a tester reports something.
# The commit count is both, for free. Overridable because a rebuild of the same
# commit (a signing fix, say) still needs a fresh number.
if [[ -z "$BUILD_NUMBER" ]]; then
    BUILD_NUMBER="$(git rev-list --count HEAD)"
fi

ASC_KEY_ID="${ASC_KEY_ID:-}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-}"
ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"

# Thread the key through xcodebuild when we have one. Without it xcodebuild
# falls back to Xcode's signed-in accounts, which is fine on a machine that has
# them and fails with a bare "No Accounts" on one that doesn't.
#
# Expanded below as ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} rather than plain
# "${AUTH_ARGS[@]}": macOS still ships bash 3.2, where expanding an EMPTY array
# under `set -u` is an unbound-variable error. The no-key path is the common
# one, so the plain form would fail every first run.
AUTH_ARGS=()
if [[ -n "$ASC_KEY_ID" && -n "$ASC_ISSUER_ID" && -f "$ASC_KEY_PATH" ]]; then
    AUTH_ARGS=(-authenticationKeyPath "$ASC_KEY_PATH"
               -authenticationKeyID "$ASC_KEY_ID"
               -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

case "$PLATFORM" in
    ios)
        DESTINATION='generic/platform=iOS'
        EXPORT_OPTIONS=tools/release/ExportOptions-iOS.plist
        ARTEFACT_EXT=ipa
        ASC_TYPE=ios
        ;;
    macos)
        DESTINATION='generic/platform=macOS'
        EXPORT_OPTIONS=tools/release/ExportOptions-macOS.plist
        ARTEFACT_EXT=pkg
        ASC_TYPE=macos
        # Fail loudly rather than burning ten minutes on an archive that App
        # Store Connect will reject the moment it is uploaded.
        if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' \
                App/LetsLapse.entitlements 2>/dev/null | grep -qi false; then
            echo "error: the macOS build is not sandboxed, so it cannot go to TestFlight." >&2
            echo "       App/LetsLapse.entitlements has app-sandbox = false." >&2
            echo "       See docs/testflight.md ▸ 'macOS: what the sandbox needs'." >&2
            exit 1
        fi
        ;;
    *) echo "unknown platform: $PLATFORM (expected ios or macos)" >&2; exit 2 ;;
esac

VERSION="$(xcodebuild -project LetsLapse.xcodeproj -target LetsLapse \
    -showBuildSettings 2>/dev/null | awk '/ MARKETING_VERSION =/ {print $3; exit}')"

OUT="build/testflight/$PLATFORM"
ARCHIVE="$OUT/LetsLapse.xcarchive"
rm -rf "$OUT"
mkdir -p "$OUT"

echo "==> LetsLapse $VERSION ($BUILD_NUMBER) · $PLATFORM · $(git rev-parse --short HEAD)"
[[ ${#AUTH_ARGS[@]} -gt 0 ]] || echo "    (no ASC API key set; relying on Xcode's accounts for signing)"

# A dirty tree makes a TestFlight build untraceable: the commit it claims to be
# is not the code the testers are running. Warn, don't block — a signing tweak
# mid-release is legitimate.
if [[ -n "$(git status --porcelain)" ]]; then
    echo "    warning: working tree is dirty; this build won't match its commit"
fi

echo "==> Archiving"
xcodebuild archive \
    -project LetsLapse.xcodeproj \
    -scheme LetsLapse \
    -destination "$DESTINATION" \
    -archivePath "$ARCHIVE" \
    -derivedDataPath build/testflight/derived \
    -allowProvisioningUpdates \
    ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    > "$OUT/archive.log" 2>&1 \
  || { echo "archive failed; last errors:" >&2
       grep -E "error:" "$OUT/archive.log" | tail -20 >&2
       echo "full log: $OUT/archive.log" >&2; exit 1; }

echo "==> Exporting"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -exportPath "$OUT" \
    -allowProvisioningUpdates \
    ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} \
    > "$OUT/export.log" 2>&1 \
  || { echo "export failed; last errors:" >&2
       grep -E "error:" "$OUT/export.log" | tail -20 >&2
       echo >&2
       echo "  'No Accounts' or 'No signing certificate \"Apple Distribution\"'" >&2
       echo "  means the distribution certificate could not be created — set the" >&2
       echo "  ASC_* variables described at the top of this script." >&2
       echo "full log: $OUT/export.log" >&2; exit 1; }

ARTEFACT="$(find "$OUT" -maxdepth 1 -name "*.$ARTEFACT_EXT" | head -1)"
[[ -n "$ARTEFACT" ]] || { echo "export produced no .$ARTEFACT_EXT" >&2; exit 1; }

# get-task-allow is the development-signing entitlement. If the export failed to
# re-sign with the distribution certificate it survives, and App Store Connect
# rejects the upload minutes later with a signature error that says nothing
# about the cause. Cheaper to catch here.
if [[ "$PLATFORM" == ios ]]; then
    WORK="$(mktemp -d)"
    unzip -qq "$ARTEFACT" -d "$WORK"
    if codesign -d --entitlements - --xml "$WORK"/Payload/*.app 2>/dev/null \
         | plutil -p - 2>/dev/null | grep -q '"get-task-allow" => 1'; then
        echo "error: exported app still carries get-task-allow — it was not" >&2
        echo "       re-signed for distribution. Check the export log." >&2
        rm -rf "$WORK"; exit 1
    fi
    rm -rf "$WORK"
fi

echo "==> Built $ARTEFACT ($(du -h "$ARTEFACT" | cut -f1))"

if [[ "$UPLOAD" -eq 0 ]]; then
    echo
    echo "Not uploaded. Re-run with --upload to send this to TestFlight,"
    echo "or drop the archive into Xcode ▸ Window ▸ Organizer."
    exit 0
fi

for var in ASC_KEY_ID ASC_ISSUER_ID; do
    if [[ -z "${!var:-}" ]]; then
        echo "error: \$$var is not set — see the header of this script." >&2
        exit 1
    fi
done
if [[ ! -f "$ASC_KEY_PATH" ]]; then
    echo "error: no API key at $ASC_KEY_PATH" >&2
    exit 1
fi

# Validate first. It catches the same defects the upload would, but in about a
# minute and without burning a build number on App Store Connect's side.
echo "==> Validating against App Store Connect"
xcrun altool --validate-app -f "$ARTEFACT" -t "$ASC_TYPE" \
    --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"

echo "==> Uploading to TestFlight"
xcrun altool --upload-app -f "$ARTEFACT" -t "$ASC_TYPE" \
    --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"

echo
echo "Uploaded LetsLapse $VERSION ($BUILD_NUMBER)."
echo "Processing takes 5–20 minutes; App Store Connect mails you when it lands."
