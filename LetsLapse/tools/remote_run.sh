#!/bin/zsh
# One scripted run over the Camera remote, readable: the probe's transcript,
# one line per command and reply (status · lens stop · Find Shapes · mode),
# and every preview frame the run pulled, saved and labelled with its stop.
#
#   tools/remote_run.sh <code> <name> "<script>" [out-dir]
#
#   tools/remote_run.sh 346447 repro \
#     "selectStop#5,wait@3,setAutoShapes:on,wait@3,selectStop#1,wait@3,setAutoShapes:off,wait@2,previewFrame,wait@1,previewFrame"
#
# <code> is the pairing code the capture screen prints (`remote-listener
# advertising … code=NNNNNN` in Logs/console-<launch>.log; it rotates with the
# screen). The script grammar is remote_probe.swift's. Output lands in
# <out-dir> (default ~/Library/Developer/LetsLapseRun/remote-runs/<name>/):
# transcript.txt, and frame-NN-stop<factor>.jpg per previewFrame answered.
# A `previewFrame` attaches the framing tap, so the first one after a pause
# usually answers without a frame and the next one, a second later, with it.
#
# Compare the frames with tools/zoom_curve.py's method (ORB scale) or by eye;
# the 2026-09-18 zoom matrix used exactly this: seven scripts, every 1x frame
# afterwards at 1.000 of the baseline.
#
# Needs the probe built: from tools/,
#   swiftc -O -o remote_probe remote_probe.swift ../Shared/CaptureRemoteFrame.swift \
#     ../Shared/CaptureRemotePairing.swift ../Shared/WatchMessageKey.swift
set -u
here=${0:A:h}
code=${1:?pairing code}; name=${2:?run name}; script=${3:?probe script}
out=${4:-$HOME/Library/Developer/LetsLapseRun/remote-runs/$name}
if [[ ! -x "$here/remote_probe" ]]; then
  echo "remote_run: build the probe first (see the header of $here/remote_probe.swift)" >&2
  exit 1
fi
mkdir -p "$out"
echo "=== $name: $script"
( cd "$here" && timeout 150 ./remote_probe "$code" "$script" --verbose ) > "$out/transcript.txt" 2>&1
echo "    (probe exit $?) → $out"
grep -E "connected —|CONNECT FAILED|BROWSE FAILED|no camera with pairing" "$out/transcript.txt" | head -2 | sed 's/^/    /'
python3 "$here/remote_replies.py" "$out/transcript.txt" "$out/frame"
