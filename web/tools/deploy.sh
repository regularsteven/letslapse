#!/usr/bin/env bash
#
# Sync the theme into a WordPress themes directory.
#
#   ./web/tools/deploy.sh                      # to the default destination
#   ./web/tools/deploy.sh --dry-run            # show what would change
#   ./web/tools/deploy.sh --dest /path/themes  # somewhere else
#
# Override the default with LETSLAPSE_THEME_DEST. Deploying does NOT activate
# the theme — switch to it in Appearance > Themes when you are ready.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="$ROOT/web/themes/letslapse"
DEST="${LETSLAPSE_THEME_DEST:-$HOME/Sites/letslapse/public_html/wp-content/themes}"
DRY=""
ASSUME_YES=""

while [ $# -gt 0 ]; do
	case "$1" in
		--dest) DEST="$2"; shift 2 ;;
		--dry-run) DRY="--dry-run"; shift ;;
		--yes|-y) ASSUME_YES="1"; shift ;;
		-h|--help) sed -n '2,12p' "$0"; exit 0 ;;
		*) echo "error: unknown option $1" >&2; exit 1 ;;
	esac
done

TARGET="$DEST/letslapse"

if [ ! -f "$SRC/style.css" ]; then
	echo "error: theme not found at $SRC" >&2
	exit 1
fi

if [ ! -d "$DEST" ]; then
	echo "error: themes directory not found: $DEST" >&2
	exit 1
fi

# --delete is only safe if the target is ours (or does not exist yet).
if [ -e "$TARGET" ] && ! grep -q '^Theme Name:[[:space:]]*LetsLapse' "$TARGET/style.css" 2>/dev/null; then
	echo "error: $TARGET exists and is not the LetsLapse theme — refusing to overwrite" >&2
	exit 1
fi

echo "source      $SRC"
echo "destination $TARGET"
echo

if [ -z "$DRY" ] && [ -z "$ASSUME_YES" ]; then
	rsync -a --delete --itemize-changes --dry-run \
		--exclude '.DS_Store' --exclude '.git*' \
		"$SRC/" "$TARGET/" | sed 's/^/  /'
	echo
	printf 'Apply these changes? [y/N] '
	read -r reply
	case "$reply" in
		y|Y|yes|YES) ;;
		*) echo "aborted"; exit 0 ;;
	esac
fi

rsync -a --delete --itemize-changes $DRY \
	--exclude '.DS_Store' --exclude '.git*' \
	"$SRC/" "$TARGET/"

if [ -n "$DRY" ]; then
	echo "(dry run — nothing written)"
else
	echo "deployed to $TARGET"
fi
