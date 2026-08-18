#!/usr/bin/env bash
#
# Build an installable theme zip.
#
#   ./web/tools/package.sh            -> web/dist/letslapse-<version>.zip
#
# The archive contains a single top-level "letslapse/" directory, which is what
# WordPress expects from Appearance > Themes > Add New > Upload Theme.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="$ROOT/web/themes/letslapse"
DIST="$ROOT/web/dist"

if [ ! -f "$SRC/style.css" ]; then
	echo "error: theme not found at $SRC" >&2
	exit 1
fi

VERSION="$(sed -n 's/^Version:[[:space:]]*//p' "$SRC/style.css" | head -1 | tr -d '[:space:]')"
VERSION="${VERSION:-0.0.0}"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

rsync -a \
	--exclude '.DS_Store' \
	--exclude '.git*' \
	--exclude 'node_modules' \
	"$SRC/" "$STAGE/letslapse/"

mkdir -p "$DIST"
ZIP="$DIST/letslapse-$VERSION.zip"
rm -f "$ZIP"

( cd "$STAGE" && zip -rq "$ZIP" letslapse )

echo "packaged  $ZIP"
echo "size      $(du -h "$ZIP" | cut -f1)"
echo "files     $(unzip -l "$ZIP" | tail -1 | awk '{print $2}')"
