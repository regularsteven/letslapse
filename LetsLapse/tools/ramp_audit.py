#!/usr/bin/env python3
"""Did the Holy Grail ramp drive this shoot, and what did it believe?

    tools/ramp_audit.py <project-dir | source-dir> [--every N]

Reads ``capture_log.json`` (and, for logs written before 2026-09-05,
``frames.timestamps``) and prints the ramp's story beside the sensor's:

* the header verdict — ``rampDriving`` / ``rampRefusals`` when the log carries
  them, else inferred from the ``ramp`` issue;
* every ``ramp`` and ``ladder`` issue, in order (refusal reason + device
  facts, recoveries, rung changes);
* a per-window table: the pair the ramp COMMANDED against the pair the
  sensor DELIVERED, the stops between them, the engine's smoothed EV and the
  AE's scene EV, and the measurement (luma / APEX brightness).

Old logs have no ``ramp`` records; there the commanded pair is taken from
``frames.timestamps`` (which, on ramped runs before 2026-09-05, recorded the
command rather than the delivered exposure) and the raw luma measurement is
backed out of the sidecar's smoothed EV — the reconstruction that diagnosed
the 2026-09-04 iPhone 12 Pro runaway
(``docs/fieldtests/2026-09-04-ladder-readout-runaway.md``).

Exit status 1 when the ramp was asked for and never drove — greppable, and
usable as a gate in a bench script.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

SMOOTHING = 0.15  # HolyGrailRampEngine.defaultSmoothing


def shutter_text(seconds: float | None) -> str:
    if not seconds or seconds <= 0:
        return "—"
    if seconds >= 1:
        return f"{seconds:.1f}s"
    return f"1/{round(1 / seconds)}"


def ev100(shutter: float | None, iso: float | None, aperture: float) -> float | None:
    if not shutter or not iso or shutter <= 0 or iso <= 0:
        return None
    return math.log2(aperture * aperture / shutter) - math.log2(iso / 100)


def stops_between(a_sh, a_iso, b_sh, b_iso) -> float | None:
    if not all(x and x > 0 for x in (a_sh, a_iso, b_sh, b_iso)):
        return None
    return abs(math.log2((a_sh * a_iso) / (b_sh * b_iso)))


def load_timestamps(path: Path) -> dict[int, dict]:
    rows: dict[int, dict] = {}
    if not path.exists():
        return rows
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        rows[int(row.get("frame", -1))] = row
    return rows


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("project", type=Path)
    parser.add_argument("--every", type=int, default=25,
                        help="print every Nth window (changes of command always print)")
    args = parser.parse_args()

    source = args.project / "source" if (args.project / "source").is_dir() else args.project
    log_path = source / "capture_log.json"
    if not log_path.exists():
        parser.error(f"{log_path} not found")
    log = json.loads(log_path.read_text())
    frames = log.get("frames", [])
    issues = log.get("issues") or []
    aperture = next((f.get("aperture") for f in frames if f.get("aperture")), 1.6)

    print(f"{log.get('deviceModel', '?')} · {log.get('cameraName', '?')} · mode {log.get('captureMode', '?')}"
          f" · blend {log.get('blendMode', '?')} · every {log.get('intervalSeconds', '?')} s"
          f" · {log.get('startedAt', '?')} → {log.get('endedAt', '?')} · end {log.get('endReason', '?')}")

    ramped = log.get("captureMode") == "dynamic"
    driving = log.get("rampDriving")
    refusals = log.get("rampRefusals")
    ramp_issue = next((i for i in issues if i.get("kind") == "ramp"), None)
    if driving is None and ramped:
        driving = not (ramp_issue and "commanded nothing" in (ramp_issue.get("detail") or ""))
        inferred = " (inferred from issues — a log written before 2026-09-05)"
    else:
        inferred = ""
    if ramped:
        verdict = "DRIVING" if driving else "NOT DRIVING — the sensor ran on its own AE"
        print(f"ramp: {verdict}{inferred}"
              + (f" · {refusals} refused write(s)" if refusals else ""))
    else:
        print("ramp: not asked for (a plain interval run)")

    trail = [i for i in issues if i.get("kind") in ("ramp", "ladder")]
    if trail:
        print("issues:")
        for issue in trail:
            print(f"  w{issue.get('windowIndex', '?'):>4} {issue.get('at', '')[11:23]} "
                  f"{issue.get('kind')}/{issue.get('severity')}: {issue.get('detail')}")

    # Per-window table. New logs: the ramp record on each entry. Old logs:
    # frames.timestamps carries the command; back the raw measurement out.
    stamps = load_timestamps(source / "frames.timestamps")
    has_records = any(f.get("ramp") for f in frames)
    if ramped and not has_records and stamps:
        print("(no ramp records — reconstructing the command from frames.timestamps)")
    print()
    print(" window  time          commanded        delivered         Δstops  engineEV  sceneEV  meas   applied")
    prev_smoothed = None
    last_key = None
    for f in frames:
        idx = f.get("frameIndex")
        d_sh, d_iso = f.get("exposureDuration"), f.get("iso")
        ramp = f.get("ramp") or {}
        if ramp:
            c_sh, c_iso = ramp.get("commandedShutter"), ramp.get("commandedISO")
            engine_ev = ramp.get("smoothedEV")
            scene_ev = ramp.get("sceneEV")
            meas = ramp.get("measuredLuma")
            meas_text = f"L{meas:.2f}" if meas is not None else (
                f"Bv{ramp['apexBrightness']:.1f}" if ramp.get("apexBrightness") is not None else "")
            applied = ramp.get("applied")
            applied_text = {True: "yes", False: "NO", None: ""}[applied]
        else:
            stamp = stamps.get(idx) or stamps.get((idx or 0) - 1) or {}
            c_sh, c_iso = stamp.get("shutter"), stamp.get("iso")
            engine_ev = stamp.get("ev")
            scene_ev = ev100(d_sh, d_iso, aperture)
            # m(t) = s(t-1) + (s(t) - s(t-1)) / α
            if engine_ev is not None:
                raw = engine_ev if prev_smoothed is None else prev_smoothed + (engine_ev - prev_smoothed) / SMOOTHING
                prev_smoothed = engine_ev
                cmd_ev = ev100(c_sh, c_iso, aperture)
                meas_text = f"L{0.18 * 2 ** (raw - cmd_ev):.2f}*" if cmd_ev is not None else ""
            else:
                meas_text = ""
            applied_text = ""
        delta = stops_between(c_sh, c_iso, d_sh, d_iso)
        key = (round(c_sh or 0, 6), round(c_iso or 0))
        if idx % args.every == 0 or idx <= 2 or idx >= len(frames) - 1 or key != last_key:
            print(f" {idx:>6}  {f.get('capturedAt', '')[11:23]}  "
                  f"{shutter_text(c_sh):>8} ISO{(c_iso or 0):>5.0f}   "
                  f"{shutter_text(d_sh):>8} ISO{(d_iso or 0):>5.0f}   "
                  f"{(delta if delta is not None else float('nan')):>5.2f}   "
                  f"{(engine_ev if engine_ev is not None else float('nan')):>6.2f}   "
                  f"{(scene_ev if scene_ev is not None else float('nan')):>6.2f}  "
                  f"{meas_text:<7} {applied_text}")
        last_key = key
    if ramped and not has_records:
        print("  * luma backed out of the sidecar's smoothed EV against the COMMANDED pair")

    if ramped and driving is False:
        print("\nRAMP AUDIT FAIL: the ramp never drove this run")
        return 1
    print("\nRAMP AUDIT OK" if ramped else "")
    return 0


if __name__ == "__main__":
    sys.exit(main())
