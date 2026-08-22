#!/usr/bin/env python3
"""Session report and standing baseline for a fleet shoot.

One fleet session is several arms — one device, one strategy each — that ran
the same sky at the same time. This turns that session into two things at
once:

  - an INSTRUMENT: a side-by-side of what each arm decided and delivered,
    with the validity gate's verdict per arm, so a strategy can be chosen on
    evidence rather than on survivor bias;
  - a GATE: a baseline record written into
    ``LetsLapse/docs/fieldtests/baselines/``, and a diff against the newest
    earlier baseline for the same device+strategy, so a later change to the
    governor or the damper cannot quietly make things worse.

The distinction that makes the diff honest: some numbers move because the
CODE changed and some move because the LIGHT changed. Only the first kind
can fail a run.

  code-sensitive   ceiling clamps · delivery shortfalls · failed and starved
                   windows · self-stops · damper-bypassing count jumps
  light-sensitive  EV span · integration coverage · which counts were used

Usage:
  python3 fleet_report.py <fleet-output-dir>            # a shoot.py fleet run
  python3 fleet_report.py <log.json> [<log.json> ...]   # loose capture logs
  python3 fleet_report.py <dir> --label sunset-control  # names the baseline
  python3 fleet_report.py <dir> --no-write              # report only
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
BASELINES = HERE.parent / "docs/fieldtests/baselines"


def _load_blend_compare():
    """Reuse the loader and the gate rather than reimplementing either."""
    spec = importlib.util.spec_from_file_location(
        "blend_compare", HERE / "blend_compare.py")
    module = importlib.util.module_from_spec(spec)
    # Registered BEFORE exec: @dataclass resolves annotations through
    # sys.modules[cls.__module__], and without this the import dies on
    # blend_compare's first dataclass.
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


BC = _load_blend_compare()

# Numbers a code change can move. A worsening here is a regression; a
# worsening in anything else is weather.
CODE_SENSITIVE = {
    "clampedWindows": "ceiling clamps",
    "shortfallWindows": "delivery shortfalls",
    "failedWindows": "failed windows",
    "starvedWindows": "starved windows",
    "damperBypassJumps": "count jumps ≥2",
}


def measure(path: Path, strategy: str | None = None) -> dict:
    log = BC.load_session(path, BC.default_label(path))
    decided = [f for f in log.frames if f.proposed]
    steps = BC.count_change_stats(decided)
    coverage = sorted(c for c in (BC.integration_coverage(f, log.interval)
                                  for f in log.frames) if c is not None)
    scene = [f.scene_ev for f in decided if f.scene_ev is not None] or \
            [f.ev for f in log.frames if f.ev is not None]
    divergences = [f.divergence for f in log.frames if f.divergence is not None]
    counts: dict[str, int] = {}
    for frame in log.frames:
        if frame.blend_count is not None:
            key = str(frame.blend_count)
            counts[key] = counts.get(key, 0) + 1
    thermal: dict[str, int] = {}
    for frame in log.frames:
        if frame.thermal_close:
            thermal[frame.thermal_close] = thermal.get(frame.thermal_close, 0) + 1

    gate = BC.validity_gate(log, decided)
    verdicts = {v for _, v, _ in gate}
    overall = ("FAIL" if "fail" in verdicts
               else "INCOMPLETE" if "unknown" in verdicts else "PASS")

    minutes = None
    if log.started_at and log.ended_at:
        minutes = (log.ended_at - log.started_at).total_seconds() / 60

    return {
        "capturePath": str(path),
        "device": log.device,
        "strategy": strategy or log.algorithm,
        "algorithmVersion": log.algorithm_version,
        "blendMode": log.blend_mode,
        "intervalSeconds": log.interval,
        "startedAt": log.started_at.isoformat() if log.started_at else None,
        "durationMinutes": round(minutes, 1) if minutes else None,
        "outputFrames": len(log.frames),
        "evSpanStops": round(max(scene) - min(scene), 3) if scene else None,
        "coverageMedianPercent": round(coverage[len(coverage) // 2] * 100, 3)
                                 if coverage else None,
        "coveragePeakPercent": round(max(coverage) * 100, 3) if coverage else None,
        "deliveredCounts": counts,
        "countChanges": steps["changes"],
        "damperBypassJumps": steps["jumps"],
        "largestCountStep": steps["largest"],
        "clampedWindows": sum(1 for f in decided if f.clamped),
        "shortfallWindows": sum(1 for f in log.frames if f.shortfall),
        "failedWindows": log.failed_windows,
        "starvedWindows": log.starved_windows,
        "endReason": log.end_reason,
        "worstDivergenceStops": round(max(divergences), 3) if divergences else None,
        "thermalAtClose": thermal,
        "actuation": actuation(path),
        "gate": {name: verdict for name, verdict, _ in gate},
        "gateDetail": {name: detail for name, _, detail in gate},
        "validity": overall,
    }


def actuation(capture_path: Path) -> dict | None:
    """Did the sensor do what the ramp asked?

    Reads the ramp's own per-frame command record (`frames.timestamps`) beside
    the capture log and compares it to what the frames actually reported. This
    separates the two failures that look identical in a finished clip: the
    engine choosing badly, and the engine choosing right while the capture
    chain ignores it.

    Found this way on 2026-08-22: two iPads commanded down to 1/387 and 1/524
    and delivered one and two distinct shutter values respectively, while two
    iPhones on the identical capture path reached 1/715 and 1/796.
    """
    sidecar = capture_path.parent / "frames.timestamps"
    if not sidecar.exists():
        return None
    raw = sidecar.read_text().strip()
    if not raw:
        return None
    try:
        entries = (json.loads(raw) if raw.startswith("[")
                   else [json.loads(line) for line in raw.splitlines() if line.strip()])
    except ValueError:
        return None
    commanded = [e["shutter"] for e in entries
                 if isinstance(e.get("shutter"), (int, float)) and e["shutter"] > 0]
    if not commanded:
        return None
    log = json.loads(capture_path.read_text())
    delivered = sorted({f["exposureDuration"] for f in log.get("frames", [])
                        if f.get("exposureDuration")})
    if not delivered:
        return None
    floor = min(delivered)
    # Commands meaningfully shorter than anything ever delivered: the engine
    # asked for less light and never got it.
    ignored_short = sum(1 for c in commanded if c < floor * 0.98)
    # And the reverse — asked for MORE light than the longest delivered. A
    # device sitting at a hardware floor still lengthens happily, so this
    # separates "floored" from "stuck".
    ceiling = max(delivered)
    ignored_long = sum(1 for c in commanded if c > ceiling * 1.02)
    verdict = "actuating"
    if len(delivered) <= 2 and (ignored_short or ignored_long):
        verdict = "STUCK" if ignored_long else "FLOORED"
    elif ignored_short > len(commanded) * 0.5:
        verdict = "FLOORED"
    return {
        "commandedShortest": round(min(commanded), 6),
        "commandedLongest": round(max(commanded), 6),
        "deliveredDistinct": len(delivered),
        "deliveredShortest": round(floor, 6),
        "commandsIgnoredShort": ignored_short,
        "commandsIgnoredLong": ignored_long,
        "verdict": verdict,
    }


def find_logs(targets: list[Path]) -> list[tuple[Path, str | None]]:
    """A fleet output directory, or loose capture logs."""
    found: list[tuple[Path, str | None]] = []
    for target in targets:
        if target.is_dir():
            session = target / "session.json"
            if session.exists():
                data = json.loads(session.read_text())
                for arm in data.get("arms", []):
                    if arm.get("captureLog"):
                        found.append((Path(arm["captureLog"]), arm.get("strategy")))
                continue
            found += [(p, None) for p in sorted(target.rglob("capture_log.json"))]
        else:
            found.append((target, None))
    return found


def prior_baseline(directory: Path, device: str, strategy: str | None,
                   exclude: Path | None):
    """The newest earlier record for this device+strategy pair."""
    best, best_key = None, None
    if not directory.exists():
        return None
    for path in sorted(directory.glob("*.json")):
        if exclude and path == exclude:
            continue
        try:
            data = json.loads(path.read_text())
        except (ValueError, OSError):
            continue
        for arm in data.get("arms", []):
            if arm.get("device") == device and arm.get("strategy") == strategy:
                key = (data.get("writtenAt") or "", path.name)
                if best_key is None or key > best_key:
                    best, best_key = (arm, data, path), key
    return best


def diff_against_prior(directory: Path, arm: dict,
                       exclude: Path | None) -> list[str]:
    found = prior_baseline(directory, arm["device"], arm["strategy"], exclude)
    if not found:
        return [f"    no earlier baseline for {arm['device']} · {arm['strategy']} "
                f"— this run becomes it"]
    previous, session, path = found
    lines = [f"    vs {path.name} ({session.get('writtenAt', '?')[:10]})"]
    regressions = []
    for key, label in CODE_SENSITIVE.items():
        now, before = arm.get(key), previous.get(key)
        if now is None or before is None:
            continue
        if now != before:
            direction = "worse" if now > before else "better"
            lines.append(f"      {label:<22} {before} → {now}  ({direction})")
            if now > before:
                regressions.append(label)
    for key, label in (("evSpanStops", "EV span"),
                       ("coverageMedianPercent", "coverage median %")):
        now, before = arm.get(key), previous.get(key)
        if now is not None and before is not None and now != before:
            lines.append(f"      {label:<22} {before} → {now}  (light, not code)")
    if regressions:
        lines.append(f"      REGRESSION: {', '.join(regressions)}")
    elif len(lines) == 1:
        lines.append("      no change in any code-sensitive number")
    return lines


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("targets", nargs="+", type=Path,
                        help="a fleet output directory, or capture_log.json files")
    parser.add_argument("--label", help="name for the baseline record")
    parser.add_argument("--no-write", action="store_true",
                        help="report only; write no baseline")
    parser.add_argument("--baselines", type=Path, default=BASELINES)
    args = parser.parse_args()

    logs = find_logs(args.targets)
    if not logs:
        print("no capture logs found in " +
              ", ".join(str(t) for t in args.targets), file=sys.stderr)
        return 1
    arms = [measure(path, strategy) for path, strategy in logs if path.exists()]
    if not arms:
        print("none of the capture logs exist", file=sys.stderr)
        return 1

    label = args.label or "session"
    stamp = time.strftime("%Y-%m-%d")
    print(f"\n{'=' * 72}\nFLEET SESSION · {label} · {len(arms)} arm(s)\n{'=' * 72}")

    header = (f"{'device':<13}{'strategy':<11}{'frames':>7}{'EVspan':>8}"
              f"{'cover%':>8}{'chg':>5}{'jump':>6}{'clamp':>7}  verdict")
    print(header)
    print("-" * len(header))
    for arm in arms:
        print(f"{str(arm['device']):<13}{str(arm['strategy']):<11}"
              f"{arm['outputFrames']:>7}"
              f"{(arm['evSpanStops'] if arm['evSpanStops'] is not None else 0):>8.2f}"
              f"{(arm['coverageMedianPercent'] or 0):>8.2f}"
              f"{arm['countChanges']:>5}{arm['damperBypassJumps']:>6}"
              f"{arm['clampedWindows']:>7}  {arm['validity']}")

    measured = [a for a in arms if a.get("actuation")]
    if measured:
        print("\nActuation — did the sensor do what the ramp asked?")
        for arm in measured:
            act = arm["actuation"]
            print(f"  {str(arm['device']):<13} commanded 1/{1/act['commandedShortest']:.0f}"
                  f" … 1/{1/act['commandedLongest']:.0f}   delivered"
                  f" {act['deliveredDistinct']:>3} value(s), shortest"
                  f" 1/{1/act['deliveredShortest']:.0f}   {act['verdict']}")
            if act["verdict"] != "actuating":
                print(f"  {'':<13}   {act['commandsIgnoredShort']} shorter and "
                      f"{act['commandsIgnoredLong']} longer commands never landed")

    usable = [a for a in arms if a["validity"] == "PASS"]
    print(f"\n{len(usable)}/{len(arms)} arm(s) are usable as strategy evidence")
    for arm in arms:
        if arm["validity"] != "PASS":
            failed = [n for n, v in arm["gate"].items() if v != "pass"]
            print(f"  {arm['device']} · {arm['strategy']}: {arm['validity']} — "
                  f"{', '.join(failed)}")

    # The comparison the session exists for. Only arms that passed the gate
    # belong in it — an arm that never traversed the bands, or whose count
    # the hardware chose, says nothing about its strategy.
    if len(usable) > 1:
        print("\nStrategy comparison (gate-passing arms only):")
        for arm in sorted(usable, key=lambda a: a["damperBypassJumps"]):
            print(f"  {str(arm['strategy']):<10} {str(arm['device']):<13} "
                  f"{arm['countChanges']:>3} changes, "
                  f"{arm['damperBypassJumps']:>2} bypassing the damper, "
                  f"coverage {arm['coverageMedianPercent']:.2f}%")
        print("  (fewer damper-bypassing jumps ⇒ fewer un-damped luminance "
              "steps; confirm against flicker_report.py on the exported clip)")
    elif usable:
        print("\n  only one arm passed the gate — no comparison is possible "
              "from this session")

    record = {
        "label": label,
        "writtenAt": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "arms": arms,
    }
    written = None
    if not args.no_write:
        args.baselines.mkdir(parents=True, exist_ok=True)
        written = args.baselines / f"{stamp}-{label}.json"
        written.write_text(json.dumps(record, indent=2, sort_keys=True))

    print("\nRegression check")
    for arm in arms:
        print(f"  {arm['device']} · {arm['strategy']}")
        for line in diff_against_prior(args.baselines, arm, written):
            print(line)

    if written:
        print(f"\nbaseline written → {written}")
    else:
        print("\n--no-write: no baseline recorded")
    return 0


if __name__ == "__main__":
    sys.exit(main())
