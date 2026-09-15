#!/bin/zsh
# launch_wait.sh <root> <log-pattern> [VAR=value …] [-- <extra launch args>]
#
# Launches the Debug Mac app (dd-mac-picplace by default; LL_APP overrides)
# on a scratch library root, waits for a NEW log file that contains
# <log-pattern>, and prints that log's picplace lines. Used by the two-device
# bench in docs/picplace-sync-v2-handover.md. Kill the instance yourself
# afterwards: pkill -f "dd-mac-picplace/Build/Products/Debug/LetsLapse.app".
ROOT="$1"; PATTERN="$2"; shift 2
ENVS=(); while [ $# -gt 0 ] && [ "$1" != "--" ]; do ENVS+=("$1"); shift; done; [ "${1:-}" = "--" ] && shift
APP="${LL_APP:-$HOME/Library/Developer/LetsLapseRun/dd-mac-picplace/Build/Products/Debug/LetsLapse.app}"
pkill -f "$(basename "$(dirname "$(dirname "$APP")")")/$(basename "$(dirname "$APP")")/$(basename "$APP")" 2>/dev/null; sleep 1
rm -f "$ROOT/Projects/.lock"
BEFORE=$(ls "$ROOT/Logs" 2>/dev/null | wc -l)
(env "${ENVS[@]}" "$APP/Contents/MacOS/LetsLapse" -storage.libraryRootPath "$ROOT" "$@" -ApplePersistenceIgnoreState YES > /dev/null 2>&1 &)
L=""
for i in $(seq 1 90); do
  sleep 1
  NOW=$(ls "$ROOT/Logs" 2>/dev/null | wc -l)
  if [ "$NOW" -gt "$BEFORE" ]; then L=$(ls -t "$ROOT/Logs"/console-*.log | head -1); grep -q "$PATTERN" "$L" && break; fi
done
[ -n "$L" ] && grep -E "picplace|walked" "$L" | sed 's/.*🎥LL [0-9.]* //' | grep -vE "session|received letslapse|migrated"
