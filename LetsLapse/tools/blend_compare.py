#!/usr/bin/env python3
"""Compare Auto blend strategy logs from a field-test shoot.

Ingests one or more ``capture_log.json`` files (the per-session document the
DNG live-blend path writes into a project's ``source/`` folder) and reports
how each device's active strategy behaved — alongside what the other two
strategies *proposed* on that same device, which every Auto run records
whether or not it actuated them. That shadow record is the point: with three
different devices in the field, cross-device output comparisons are
confounded by sensor and thermals, but every single log carries its own
three-way decision comparison on identical inputs.

Usage:
  python3 blend_compare.py report LOG [LOG ...] [--labels A,B,C]
                                  [--csv out.csv] [--plot out.png]

Outputs:
  - a per-log console summary (algorithm, frames, EV span, count histogram,
    ceiling-clamp events, strategy disagreements)
  - optionally a long-format CSV, one row per output frame, for notebooks
  - optionally a two-panel PNG (EV over time; counts + proposals over time),
    when matplotlib is importable — the CSV and summary need nothing beyond
    the standard library.
"""

from __future__ import annotations

import argparse
import csv
import json
import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path


def parse_date(raw: str | None) -> datetime | None:
    if not raw:
        return None
    try:
        return datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return None


@dataclass
class FrameRow:
    frame_index: int
    captured_at: datetime | None
    ev: float | None
    iso: float | None
    shutter: float | None
    blend_count: int | None
    scene_ev: float | None = None
    zone_smoothed_ev: float | None = None
    proposed: dict[str, int | None] = field(default_factory=dict)
    latitude_continuous: float | None = None
    velocity: float | None = None
    lumen_score: float | None = None
    lumen_boost: int | None = None
    ceiling: int | None = None
    interval: float | None = None
    actuated: int | None = None
    # Delivery record (the entry's `window` block) — present on every
    # blend-path frame whatever the depth, so fixed-depth runs show their
    # shortfalls too.
    requested: int | None = None
    missed: int | None = None
    dropped_behind: int | None = None
    failures: int | None = None
    partial: bool = False
    memory_capped: bool = False
    fallback: bool = False
    thermal_start: str | None = None
    thermal_close: str | None = None
    spacing_max: float | None = None
    processing_ms: float | None = None
    actual_interval: float | None = None
    win_interval: float | None = None
    file_bytes: int | None = None
    divergence: float | None = None

    @property
    def clamped(self) -> bool:
        """The active strategy asked for more than the device ceiling gave."""
        if self.ceiling is None or self.actuated is None:
            return False
        active = self.proposed.get("active")
        return active is not None and active > self.ceiling

    @property
    def asked(self) -> int | None:
        """Frames the run wanted this window: the strategy's actuated count
        on Auto, the window's resolved target otherwise."""
        return self.actuated if self.actuated is not None else self.requested

    @property
    def shortfall(self) -> bool:
        asked = self.asked
        return (asked is not None and self.blend_count is not None
                and self.blend_count < asked)


@dataclass
class SessionLog:
    path: Path
    label: str
    device: str
    algorithm: str | None
    algorithm_version: str | None
    blend_mode: str
    camera: str | None
    capture_width: int | None
    capture_height: int | None
    interval: float | None
    end_reason: str | None
    failed_windows: int | None
    starved_windows: int | None
    started_at: datetime | None
    ended_at: datetime | None
    frames: list[FrameRow]


def load_session(path: Path, label: str) -> SessionLog:
    data = json.loads(path.read_text())
    frames: list[FrameRow] = []
    unknown_algorithms: set[str | None] = set()
    for raw in data.get("frames", []):
        row = FrameRow(
            frame_index=raw.get("frameIndex", 0),
            captured_at=parse_date(raw.get("capturedAt")),
            ev=raw.get("ev"),
            iso=raw.get("iso"),
            shutter=raw.get("exposureDuration"),
            blend_count=raw.get("blendCount"),
        )
        strategy = raw.get("strategy")
        if strategy:
            algorithm = strategy.get("algorithm")
            row.scene_ev = strategy.get("sceneEV")
            row.proposed = {
                "zone": strategy.get("proposedZone"),
                "latitude": strategy.get("proposedLatitude"),
                "lumen": strategy.get("proposedLumen"),
            }
            if algorithm not in row.proposed:
                # A silent None here would disable clamp detection for the
                # whole log — say so once instead.
                if algorithm not in unknown_algorithms:
                    unknown_algorithms.add(algorithm)
                    print(f"WARNING: {path.name}: unknown strategy algorithm "
                          f"{algorithm!r} — clamp detection disabled for its rows",
                          file=sys.stderr)
            row.proposed["active"] = row.proposed.get(algorithm)
            row.zone_smoothed_ev = strategy.get("zoneSmoothedEV")
            row.latitude_continuous = strategy.get("latitudeContinuous")
            row.velocity = strategy.get("evVelocityStopsPerMinute")
            row.lumen_score = strategy.get("lumenScore")
            row.lumen_boost = strategy.get("lumenBoost")
            row.ceiling = strategy.get("deviceCeiling")
            row.interval = strategy.get("intervalSeconds")
            row.actuated = strategy.get("actuatedCount")
        window = raw.get("window")
        if window:
            row.requested = window.get("requestedFrames")
            row.missed = window.get("missed")
            row.dropped_behind = window.get("droppedProcessingBehind")
            row.failures = window.get("failures")
            row.partial = bool(window.get("partial"))
            row.memory_capped = bool(window.get("memoryCapped"))
            row.fallback = bool(window.get("fallbackSingleFrame"))
            row.thermal_start = window.get("thermalStateAtStart")
            row.thermal_close = window.get("thermalStateAtClose")
            row.spacing_max = window.get("frameSpacingMaxSeconds")
            row.processing_ms = window.get("processingMillis")
            row.actual_interval = window.get("actualIntervalSeconds")
            row.win_interval = window.get("intervalSeconds")
            row.file_bytes = window.get("fileBytes")
            row.divergence = window.get("exposureDivergenceStops")
        frames.append(row)
    return SessionLog(
        path=path,
        label=label,
        device=data.get("deviceModel", "unknown"),
        algorithm=data.get("algorithm"),
        algorithm_version=data.get("algorithmVersion"),
        blend_mode=data.get("blendMode", "?"),
        camera=data.get("cameraName"),
        capture_width=data.get("captureWidth"),
        capture_height=data.get("captureHeight"),
        interval=data.get("intervalSeconds"),
        end_reason=data.get("endReason"),
        failed_windows=data.get("failedWindows"),
        starved_windows=data.get("starvedWindows"),
        started_at=parse_date(data.get("startedAt")),
        ended_at=parse_date(data.get("endedAt")),
        frames=frames,
    )


def histogram(values: list[int]) -> str:
    if not values:
        return "(none)"
    counts: dict[int, int] = {}
    for value in values:
        counts[value] = counts.get(value, 0) + 1
    return "  ".join(f"{k}f×{counts[k]}" for k in sorted(counts))


def summarize(log: SessionLog) -> None:
    print(f"\n=== {log.label}  ({log.path.name})")
    print(f"    device {log.device}   blend {log.blend_mode}"
          f"   algorithm {log.algorithm or '—'}"
          f"{f' ({log.algorithm_version})' if log.algorithm_version else ''}")
    context = []
    if log.camera:
        context.append(log.camera)
    if log.capture_width and log.capture_height:
        context.append(f"{log.capture_width}×{log.capture_height}")
    if log.interval:
        context.append(f"every {log.interval:g}s")
    if context:
        print(f"    {'   '.join(context)}")
    if log.started_at and log.ended_at:
        minutes = (log.ended_at - log.started_at).total_seconds() / 60
        print(f"    {log.started_at:%Y-%m-%d %H:%M:%S} → {log.ended_at:%H:%M:%S}"
              f"  ({minutes:.0f} min, {len(log.frames)} output frames)")
    if log.end_reason and log.end_reason != "user":
        print(f"    RUN SELF-ENDED: {log.end_reason}")
    hidden = []
    if log.failed_windows:
        hidden.append(f"{log.failed_windows} failed")
    if log.starved_windows:
        hidden.append(f"{log.starved_windows} starved (backpressure)")
    if hidden:
        print(f"    windows with no frame entry: {', '.join(hidden)}")
    evs = [f.ev for f in log.frames if f.ev is not None]
    if evs:
        print(f"    EV span {min(evs):.1f} … {max(evs):.1f}")
    # Two different quantities, kept apart on purpose: `asked` is what the
    # run wanted from the window (the strategy's post-ceiling count on Auto,
    # the window's resolved target otherwise); `blendCount` is what the
    # camera delivered. A gap between them is missed captures, not a
    # strategy decision.
    delivered = [f.blend_count for f in log.frames if f.blend_count is not None]
    print(f"    delivered frames per blend: {histogram(delivered)}")
    asked_all = [f.asked for f in log.frames if f.asked is not None]
    if asked_all:
        print(f"    asked per blend:            {histogram(asked_all)}")

    # Shortfall only needs asked-vs-delivered, so it also works on Auto logs
    # from builds that predate the window record.
    shortfalls = [f for f in log.frames if f.shortfall]
    if shortfalls:
        lost = sum((f.asked or 0) - (f.blend_count or 0) for f in shortfalls)
        print(f"    delivery shortfalls: {len(shortfalls)} windows, "
              f"{lost} frames short of what was asked")

    # Delivery health, from the per-window record — present on every
    # blend-path run whatever the depth.
    windowed = [f for f in log.frames if f.thermal_close is not None
                or f.missed is not None or f.requested is not None]
    if windowed:
        missed = sum(f.missed or 0 for f in log.frames)
        behind = sum(f.dropped_behind or 0 for f in log.frames)
        failures = sum(f.failures or 0 for f in log.frames)
        if missed or behind or failures:
            behind_note = f", {behind} refused with processing behind" if behind else ""
            print(f"    capture health: {missed} missed opportunities"
                  f"{behind_note}, {failures} failed captures")
        flags = {
            "partial": sum(1 for f in log.frames if f.partial),
            "memory-capped": sum(1 for f in log.frames if f.memory_capped),
            "single-frame fallback": sum(1 for f in log.frames if f.fallback),
        }
        flagged = "  ".join(f"{k}×{v}" for k, v in flags.items() if v)
        if flagged:
            print(f"    flagged windows: {flagged}")
        diverged = [f for f in log.frames if (f.divergence or 0) > 0.5]
        if diverged:
            worst = max(f.divergence for f in diverged)
            print(f"    RAMP ACTUATION FAULT: {len(diverged)} windows delivered "
                  f"an exposure >0.5 stop from the ramp's command "
                  f"(worst {worst:.1f} stops) — the sensor is not doing what "
                  f"the engine asked")
        thermal = {}
        for f in windowed:
            if f.thermal_close:
                thermal[f.thermal_close] = thermal.get(f.thermal_close, 0) + 1
        if thermal and set(thermal) != {"nominal"}:
            states = "  ".join(f"{k}×{v}" for k, v in sorted(thermal.items()))
            print(f"    thermal at window close: {states}")
        drift = [
            f.actual_interval / f.win_interval
            for f in log.frames
            if f.actual_interval and f.win_interval and f.win_interval > 0]
        if drift:
            worst = max(drift)
            if worst > 1.25:
                over = sum(1 for d in drift if d > 1.25)
                print(f"    interval drift: {over} windows ran >25% over their "
                      f"interval (worst {worst:.2f}×) — the device could not "
                      f"hold the cadence")
        processing = sorted(f.processing_ms for f in log.frames if f.processing_ms)
        if processing:
            p95 = processing[min(len(processing) - 1, int(0.95 * len(processing)))]
            print(f"    processing per window: median "
                  f"{processing[len(processing) // 2]:.0f} ms, p95 {p95:.0f} ms")

    decided = [f for f in log.frames if f.proposed]
    if not decided:
        print("    (no strategy decisions in this log — a fixed-depth run, "
              "or a pre-field-test build)")
        return
    clamps = [f for f in decided if f.clamped]
    if clamps:
        print(f"    ceiling clamps: {len(clamps)} windows had the active "
              f"strategy asking above the device ceiling")
    changes = sum(
        1 for a, b in zip(decided, decided[1:])
        if a.actuated is not None and b.actuated is not None and a.actuated != b.actuated)
    print(f"    asked-count changes: {changes} over {len(decided)} decided windows")
    for pair in (("zone", "latitude"), ("zone", "lumen"), ("latitude", "lumen")):
        diffs = [
            f for f in decided
            if f.proposed.get(pair[0]) is not None
            and f.proposed.get(pair[1]) is not None
            and f.proposed[pair[0]] != f.proposed[pair[1]]]
        print(f"    {pair[0]} vs {pair[1]}: disagreed on "
              f"{len(diffs)}/{len(decided)} windows")
    boosts = [f for f in decided if (f.lumen_boost or 0) > 0]
    if boosts:
        scores = [f.lumen_score for f in boosts if f.lumen_score is not None]
        top = f", peak score {max(scores):.3f}" if scores else ""
        print(f"    lumen boost active on {len(boosts)} windows{top}")


def write_csv(logs: list[SessionLog], out: Path) -> None:
    columns = [
        "label", "device", "algorithm", "frameIndex", "capturedAt",
        "minutes", "ev", "sceneEV", "zoneSmoothedEV", "iso", "shutter",
        "blendCount",
        "proposedZone", "proposedLatitude", "proposedLumen",
        "latitudeContinuous", "evVelocityStopsPerMinute",
        "lumenScore", "lumenBoost", "deviceCeiling", "intervalSeconds",
        "actuatedCount", "clamped",
        "requestedFrames", "shortfall", "missed", "droppedProcessingBehind",
        "failures", "partial",
        "memoryCapped", "fallbackSingleFrame", "thermalAtStart",
        "thermalAtClose", "frameSpacingMaxSeconds", "processingMillis",
        "actualIntervalSeconds", "windowIntervalSeconds", "fileBytes",
        "exposureDivergenceStops",
    ]
    epoch = min(
        (log.started_at for log in logs if log.started_at),
        default=None)
    with out.open("w", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(columns)
        for log in logs:
            for f in log.frames:
                minutes = (
                    (f.captured_at - epoch).total_seconds() / 60
                    if epoch and f.captured_at else None)
                writer.writerow([
                    log.label, log.device, log.algorithm, f.frame_index,
                    f.captured_at.isoformat() if f.captured_at else None,
                    f"{minutes:.3f}" if minutes is not None else None,
                    f.ev, f.scene_ev, f.zone_smoothed_ev, f.iso, f.shutter,
                    f.blend_count,
                    f.proposed.get("zone"), f.proposed.get("latitude"),
                    f.proposed.get("lumen"), f.latitude_continuous,
                    f.velocity, f.lumen_score, f.lumen_boost,
                    f.ceiling, f.interval, f.actuated, f.clamped,
                    f.requested, f.shortfall, f.missed, f.dropped_behind,
                    f.failures,
                    f.partial, f.memory_capped, f.fallback, f.thermal_start,
                    f.thermal_close, f.spacing_max, f.processing_ms,
                    f.actual_interval, f.win_interval, f.file_bytes,
                    f.divergence,
                ])
    print(f"\nCSV written: {out}")


def write_plot(logs: list[SessionLog], out: Path) -> None:
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        print("\n(no matplotlib in this environment — skipped the plot; "
              "the CSV has everything it would have drawn)")
        return
    epoch = min((log.started_at for log in logs if log.started_at), default=None)
    if epoch is None:
        print("\n(no start times in the logs — skipped the plot)")
        return
    figure, (ax_ev, ax_count) = plt.subplots(
        2, 1, sharex=True, figsize=(12, 7),
        gridspec_kw={"height_ratios": [1, 1.4]})
    for log in logs:
        times, evs, delivered, asked = [], [], [], []
        p_zone, p_latitude, p_lumen, ceilings = [], [], [], []
        for f in log.frames:
            if not f.captured_at:
                continue
            minutes = (f.captured_at - epoch).total_seconds() / 60
            times.append(minutes)
            evs.append(f.ev)
            delivered.append(f.blend_count)
            asked.append(f.asked)
            p_zone.append(f.proposed.get("zone"))
            p_latitude.append(f.proposed.get("latitude"))
            p_lumen.append(f.proposed.get("lumen"))
            ceilings.append(f.ceiling)
        tag = f"{log.label} [{log.algorithm or log.blend_mode}]"
        ax_ev.plot(times, evs, label=tag, linewidth=1.2)
        # "asked" is the strategy's post-ceiling decision; "delivered" is
        # what the camera landed. Keeping both visible is the point of the
        # chart — a gap between them is missed captures, not a decision.
        headline = asked if any(v is not None for v in asked) else delivered
        headline_name = "asked" if headline is asked else "delivered"
        (line,) = ax_count.plot(
            times, headline, label=f"{tag} {headline_name}",
            linewidth=1.8, drawstyle="steps-post")
        color = line.get_color()
        if headline is asked and any(v is not None for v in delivered):
            ax_count.plot(
                times, delivered, linewidth=1.0, alpha=0.5, color=color,
                marker=".", markersize=2, linestyle="none",
                label=f"{log.label} delivered")
        shortfall_t = [
            (f.captured_at - epoch).total_seconds() / 60
            for f in log.frames if f.captured_at and f.shortfall]
        if shortfall_t:
            ax_count.plot(
                [t for t in shortfall_t],
                [0.5] * len(shortfall_t),
                marker="x", markersize=4, linestyle="none", color=color,
                alpha=0.8, label=f"{log.label} shortfall")
        for series, style, name in (
                (p_zone, ":", "zone"), (p_latitude, "--", "latitude"),
                (p_lumen, "-.", "lumen")):
            if any(v is not None for v in series):
                ax_count.plot(
                    times, series, style, linewidth=0.8, alpha=0.55,
                    color=color, drawstyle="steps-post",
                    label=f"{log.label} {name} (proposal)")
        if any(v is not None for v in ceilings):
            ax_count.plot(
                times, ceilings, linewidth=0.8, alpha=0.4, color=color,
                drawstyle="steps-post", label=f"{log.label} ceiling")
    ax_ev.set_ylabel("EV (captured frame)")
    ax_ev.legend(fontsize=7)
    ax_ev.grid(alpha=0.25)
    ax_count.set_ylabel("frames per blend")
    ax_count.set_xlabel(f"minutes since {epoch:%H:%M:%S}")
    ax_count.legend(fontsize=6, ncol=2)
    ax_count.grid(alpha=0.25)
    figure.tight_layout()
    figure.savefig(out, dpi=160)
    print(f"Plot written: {out}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    report = sub.add_parser("report", help="summarize and compare capture logs")
    report.add_argument("logs", nargs="+", type=Path)
    report.add_argument("--labels", help="comma-separated, one per log")
    report.add_argument("--csv", type=Path, help="write a long-format CSV")
    report.add_argument("--plot", type=Path, help="write a comparison PNG")
    args = parser.parse_args()

    labels = (args.labels.split(",") if args.labels else [])
    if labels and len(labels) != len(args.logs):
        parser.error(f"--labels has {len(labels)} entries for {len(args.logs)} logs")
    sessions = []
    for i, path in enumerate(args.logs):
        if not path.exists():
            parser.error(f"no such log: {path}")
        label = labels[i] if labels else path.parent.name or path.stem
        sessions.append(load_session(path, label))

    for session in sessions:
        summarize(session)
    if args.csv:
        write_csv(sessions, args.csv)
    if args.plot:
        write_plot(sessions, args.plot)
    return 0


if __name__ == "__main__":
    sys.exit(main())
