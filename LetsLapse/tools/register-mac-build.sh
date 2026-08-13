#!/bin/zsh
# Point Finder's ".lapse" association at one local build.
#
# Xcode already registers whatever it builds (there is a RegisterWithLaunchServices
# build phase), so after a normal build a double-click usually just works. This
# script is for when it doesn't: two builds of the same bundle id — the usual
# Debug-beside-Release state of this project — leave Launch Services free to pick
# either, and a deleted DerivedData folder can leave a stale registration behind
# that resolves to nothing at all.
#
#   ./tools/register-mac-build.sh              # Release (default)
#   ./tools/register-mac-build.sh Debug
#   ./tools/register-mac-build.sh /path/to/LetsLapse.app
#
# Prints which app the system will hand a .lapse file to afterwards.

set -e

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
ARG="${1:-Release}"

if [[ "$ARG" == *.app ]]; then
  APP="$ARG"
else
  DERIVED=$(ls -dt "$HOME/Library/Developer/Xcode/DerivedData/LetsLapse-"* 2>/dev/null | head -1)
  if [[ -z "$DERIVED" ]]; then
    echo "No LetsLapse DerivedData folder found — build the macOS app in Xcode first." >&2
    exit 1
  fi
  APP="$DERIVED/Build/Products/$ARG/LetsLapse.app"
fi

if [[ ! -d "$APP" ]]; then
  echo "Not a build: $APP" >&2
  exit 1
fi

# Registering the one you want is not enough: the other builds of the same
# bundle id stay registered, and Launch Services picks among them on its own
# (in practice, whichever was registered last — so a Debug build wins the
# moment you build Debug). Drop the others first, so there is only one answer.
for OTHER in "$HOME/Library/Developer/Xcode/DerivedData/LetsLapse-"*/Build/Products/*/LetsLapse.app(N); do
  [[ "$OTHER:A" == "$APP:A" ]] && continue
  "$LSREGISTER" -u "$OTHER" >/dev/null 2>&1 || true
  echo "Unregistered: $OTHER"
done
"$LSREGISTER" -f -R -trusted "$APP"

echo "Registered: $APP"
echo -n "Opens .lapse files: "
/usr/bin/swift -e '
import Foundation
import CoreServices
import UniformTypeIdentifiers
guard let type = UTType(filenameExtension: "lapse") else { print("no .lapse type registered"); exit(1) }
if type.isDynamic {
    print("no app claims .lapse yet — open the app once, then re-run this")
} else if let handler = LSCopyDefaultApplicationURLForContentType(
    type.identifier as CFString, .all, nil)?.takeRetainedValue() as URL? {
    print(handler.path)
} else {
    print("none")
}' 2>/dev/null
