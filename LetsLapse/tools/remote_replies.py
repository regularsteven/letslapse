#!/usr/bin/env python3
"""Read a remote_probe --verbose transcript: one line per command and reply, frames saved.

The probe's verbose output prints every reply as a sorted key = value block —
forty lines each, with a base64 JPEG in the middle when the reply carries a
preview frame. This turns that into what a test wants to read:

    → selectStop#5.0 (id 5)
        ← reply status=accepted stop=1 shapes=off mode=Photo
        ← push status=? stop=5 shapes=off mode=Photo
    → previewFrame (id 6)
        ← reply status=ok stop=5 shapes=off mode=Photo frame=run-01-stop5.jpg

and writes each frame to <prefix>-NN-stop<factor>.jpg, labelled with the lens
stop the reply reports — so a framing check (tools/zoom_curve.py's ORB scale,
or eyes) knows which stop it is looking at. A `push` is the phone's own state
broadcast after an accepted command; it is how the change is confirmed.

    tools/remote_replies.py <transcript.txt> <frame-prefix>

Used with tools/remote_run.sh, which produces the transcript.
"""
import base64
import re
import sys


def main():
    if len(sys.argv) != 3:
        print(__doc__.strip().splitlines()[-4].strip())
        sys.exit(2)
    text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
    prefix = sys.argv[2]
    frames = 0
    for block in re.split(r"^(?=→ |← )", text, flags=re.M):
        head = block.split("\n", 1)[0]
        if head.startswith("→ "):
            print("  " + head)
            continue
        if not head.startswith("← "):
            continue
        kv = dict(re.findall(r"^  (\w+) = (.*)$", block, flags=re.M))
        image = re.search(r"previewImage = ([A-Za-z0-9+/=]{500,})", block)
        line = (f"    {head.split(' (')[0]} status={kv.get('status', '?')} "
                f"stop={kv.get('zoomStop', '?')} shapes={kv.get('autoShapes', '?')} "
                f"mode={kv.get('captureMode', '?')}")
        if kv.get("message"):
            line += f" msg={kv['message']}"
        if image:
            path = f"{prefix}-{frames:02d}-stop{kv.get('zoomStop', '?')}.jpg"
            frames += 1
            with open(path, "wb") as f:
                f.write(base64.b64decode(image.group(1)))
            line += f" frame={path.rsplit('/', 1)[-1]}"
        print(line)


if __name__ == "__main__":
    main()
