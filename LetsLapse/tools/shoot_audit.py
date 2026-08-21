#!/usr/bin/env python3
"""Repeatable cross-device audit of a LetsLapse field shoot.

Takes N imported project directories (each holding ``source/capture_log.json``
and the run's DNG frames), aligns them on wall clock, and produces one audit
folder per run of this tool:

  report.md            — topline verdicts, anomaly flags, per-device summary
  timelines.png        — EV / ISO / shutter / blend counts / pixel luma vs time
  contact-NN.jpg       — timestamp-matched frame comparisons (one column per
                         device, stats under each tile)
  metrics.csv          — every sampled frame's pixel metrics, long format
  (blend_compare's decision/delivery report is complementary — run both.)

Pixel metrics come from rendering matched DNGs through Apple's RAW pipeline
(``sips``, the same decoder family the app uses) at a fixed width, then
measuring the rendered image: mean/median luma, shadow-clip and highlight-clip
fractions, a noise proxy (median absolute Laplacian in a центral patch,
normalised), and the luminance histogram. Rendered-domain
metrics are the honest choice for "which looks best": they measure what a
viewer sees after Apple's tone mapping, not scene-referred truth — the
capture_log's own FrameLuminanceStats already hold the scene-referred side.

Anomaly detection (the "did the system actually do its job" checks):
  - frozen exposure: EV span < 0.7 stop across a run longer than 20 minutes
    that overlaps another device whose EV moved ≥ 2 stops
  - delivery shortfalls / missed captures / thermal pressure (from the
    window records)
  - dark-drift: rendered mean luma falling below 0.06 while EV stays flat
    (exposure not following the light)

Usage:
  python3 shoot_audit.py <project-dir> [<project-dir> ...]
      [--labels a,b,c] [--out DIR] [--step-seconds 180] [--tile-width 640]

Requires: numpy, opencv-python-headless, matplotlib (tools/.venv), and the
macOS ``sips`` binary for DNG rendering.
"""

from __future__ import annotations

import argparse
import csv
import json
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path

import numpy as np

try:
    import cv2
except ImportError:  # pragma: no cover
    cv2 = None


def parse_date(raw: str | None) -> datetime | None:
    if not raw:
        return None
    try:
        return datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return None


@dataclass
class Frame:
    index: int
    at: datetime
    path: Path | None
    ev: float | None
    iso: float | None
    shutter: float | None
    blend_count: int | None
    asked: int | None
    lumen_score: float | None
    thermal: str | None
    shortfall: bool


@dataclass
class Run:
    label: str
    project: Path
    device: str
    algorithm: str | None
    blend_mode: str
    interval: float | None
    camera: str | None
    frames: list[Frame]

    @property
    def start(self) -> datetime | None:
        return self.frames[0].at if self.frames else None

    @property
    def end(self) -> datetime | None:
        return self.frames[-1].at if self.frames else None

    def nearest(self, t: datetime, tolerance: float = 90.0) -> Frame | None:
        best, gap = None, tolerance
        for f in self.frames:
            d = abs((f.at - t).total_seconds())
            if d <= gap:
                best, gap = f, d
        return best


def load_run(project: Path, label: str) -> Run:
    log_path = project / "source" / "capture_log.json"
    data = json.loads(log_path.read_text())
    frames: list[Frame] = []
    for raw in data.get("frames", []):
        at = parse_date(raw.get("capturedAt"))
        if not at:
            continue
        index = raw.get("frameIndex", 0)
        dng = project / "source" / f"frame-{index:05d}.dng"
        strategy = raw.get("strategy") or {}
        window = raw.get("window") or {}
        asked = strategy.get("actuatedCount", window.get("requestedFrames"))
        delivered = raw.get("blendCount")
        frames.append(Frame(
            index=index, at=at, path=dng if dng.exists() else None,
            ev=raw.get("ev"), iso=raw.get("iso"),
            shutter=raw.get("exposureDuration"),
            blend_count=delivered, asked=asked,
            lumen_score=strategy.get("lumenScore"),
            thermal=window.get("thermalStateAtClose"),
            shortfall=(asked is not None and delivered is not None
                       and delivered < asked)))
    frames.sort(key=lambda f: f.at)
    return Run(
        label=label, project=project,
        device=data.get("deviceModel", "unknown"),
        algorithm=data.get("algorithm"),
        blend_mode=data.get("blendMode", "?"),
        interval=data.get("intervalSeconds"),
        camera=data.get("cameraName"),
        frames=frames)


def render(dng: Path, width: int, out: Path) -> bool:
    """DNG → JPEG through Apple's RAW pipeline. Returns success."""
    result = subprocess.run(
        ["sips", "-s", "format", "jpeg", "--resampleWidth", str(width),
         str(dng), "--out", str(out)],
        capture_output=True)
    return result.returncode == 0 and out.exists()


@dataclass
class PixelMetrics:
    mean_luma: float
    median_luma: float
    shadow_clip: float      # fraction of pixels ≤ 8/255
    highlight_clip: float   # fraction of pixels ≥ 250/255
    noise: float            # median |Laplacian| in the centre patch / 255
    histogram: np.ndarray   # 32-bin luma histogram, normalised


def measure(image_path: Path) -> PixelMetrics | None:
    if cv2 is None:
        return None
    image = cv2.imread(str(image_path), cv2.IMREAD_GRAYSCALE)
    if image is None:
        return None
    f = image.astype(np.float32)
    h, w = f.shape
    patch = f[h // 3: 2 * h // 3, w // 3: 2 * w // 3]
    lap = cv2.Laplacian(patch, cv2.CV_32F, ksize=3)
    hist = np.histogram(f, bins=32, range=(0, 255))[0].astype(np.float64)
    return PixelMetrics(
        mean_luma=float(f.mean()) / 255,
        median_luma=float(np.median(f)) / 255,
        shadow_clip=float((f <= 8).mean()),
        highlight_clip=float((f >= 250).mean()),
        noise=float(np.median(np.abs(lap))) / 255,
        histogram=hist / max(1.0, hist.sum()))


def sample_times(runs: list[Run], step: float) -> list[datetime]:
    starts = [r.start for r in runs if r.start]
    ends = [r.end for r in runs if r.end]
    if not starts or not ends:
        return []
    # The union window, so a run that outlived the others still shows its
    # tail (the overlap is visible per-tile: absent devices show a gap).
    t, out = min(starts), []
    while t <= max(ends):
        out.append(t)
        t += timedelta(seconds=step)
    return out


def annotate(tile: "np.ndarray", lines: list[str]) -> "np.ndarray":
    bar = np.zeros((20 * len(lines) + 8, tile.shape[1], 3), dtype=np.uint8)
    for i, line in enumerate(lines):
        cv2.putText(bar, line, (6, 18 * (i + 1)), cv2.FONT_HERSHEY_SIMPLEX,
                    0.42, (235, 235, 235), 1, cv2.LINE_AA)
    return np.vstack([tile, bar])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("projects", nargs="+", type=Path)
    parser.add_argument("--labels")
    parser.add_argument("--out", type=Path,
                        default=Path(f"shoot-audit-{datetime.now():%Y%m%d-%H%M}"))
    parser.add_argument("--step-seconds", type=float, default=180)
    parser.add_argument("--tile-width", type=int, default=640)
    args = parser.parse_args()

    labels = args.labels.split(",") if args.labels else []
    if labels and len(labels) != len(args.projects):
        parser.error("--labels count must match projects")
    runs = []
    for i, project in enumerate(args.projects):
        if not (project / "source" / "capture_log.json").exists():
            parser.error(f"{project} has no source/capture_log.json")
        runs.append(load_run(project, labels[i] if labels else project.name[:8]))

    args.out.mkdir(parents=True, exist_ok=True)
    times = sample_times(runs, args.step_seconds)
    epoch = min(r.start for r in runs if r.start)

    # ---- pixel pass over matched frames -------------------------------
    metrics_rows = []
    contact_paths = []
    with tempfile.TemporaryDirectory() as scratch_dir:
        scratch = Path(scratch_dir)
        for n, t in enumerate(times):
            tiles = []
            for run in runs:
                frame = run.nearest(t)
                tile = None
                stats_lines = [f"{run.label}", "no frame near this time"]
                if frame and frame.path:
                    rendered = scratch / f"{run.label}-{n:03d}.jpg"
                    if render(frame.path, args.tile_width, rendered):
                        pixels = measure(rendered)
                        tile = cv2.imread(str(rendered)) if cv2 is not None else None
                        if pixels:
                            metrics_rows.append({
                                "label": run.label, "minutes": (t - epoch).total_seconds() / 60,
                                "sampleTime": t.isoformat(), "frameIndex": frame.index,
                                "capturedAt": frame.at.isoformat(),
                                "ev": frame.ev, "iso": frame.iso, "shutter": frame.shutter,
                                "blendCount": frame.blend_count, "asked": frame.asked,
                                "lumenScore": frame.lumen_score, "thermal": frame.thermal,
                                "shortfall": frame.shortfall,
                                "meanLuma": pixels.mean_luma, "medianLuma": pixels.median_luma,
                                "shadowClip": pixels.shadow_clip,
                                "highlightClip": pixels.highlight_clip,
                                "noise": pixels.noise,
                            })
                            stats_lines = [
                                f"{run.label}  #{frame.index}  {frame.at:%H:%M:%S}",
                                f"EV {frame.ev:.1f}" if frame.ev is not None else "EV -",
                                f"ISO {frame.iso:.0f}  1/{1 / frame.shutter:.0f}s"
                                if frame.iso and frame.shutter and frame.shutter < 1
                                else (f"ISO {frame.iso:.0f}  {frame.shutter:.1f}s"
                                      if frame.iso and frame.shutter else "exposure -"),
                                f"blend {frame.blend_count}"
                                + (f"/{frame.asked} SHORT" if frame.shortfall else ""),
                                f"luma {pixels.mean_luma:.3f}  shadow {pixels.shadow_clip:.0%}"
                                f"  noise {pixels.noise * 1000:.1f}",
                            ]
                if cv2 is not None:
                    if tile is None:
                        tile = np.zeros((int(args.tile_width * 0.75), args.tile_width, 3),
                                        dtype=np.uint8)
                    scale = args.tile_width / tile.shape[1]
                    tile = cv2.resize(tile, (args.tile_width, int(tile.shape[0] * scale)))
                    tiles.append(annotate(tile, stats_lines))
            if cv2 is not None and tiles:
                height = max(t.shape[0] for t in tiles)
                padded = [np.vstack([t, np.zeros((height - t.shape[0], t.shape[1], 3),
                                                 dtype=np.uint8)]) for t in tiles]
                sheet = np.hstack(padded)
                header = np.zeros((32, sheet.shape[1], 3), dtype=np.uint8)
                cv2.putText(header, f"t+{(t - epoch).total_seconds() / 60:5.1f} min   "
                            f"{t:%Y-%m-%d %H:%M:%S} UTC",
                            (8, 22), cv2.FONT_HERSHEY_SIMPLEX, 0.55,
                            (255, 255, 255), 1, cv2.LINE_AA)
                path = args.out / f"contact-{n:02d}.jpg"
                cv2.imwrite(str(path), np.vstack([header, sheet]),
                            [cv2.IMWRITE_JPEG_QUALITY, 88])
                contact_paths.append(path)

    # ---- metrics CSV ---------------------------------------------------
    csv_path = args.out / "metrics.csv"
    if metrics_rows:
        with csv_path.open("w", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=list(metrics_rows[0]))
            writer.writeheader()
            writer.writerows(metrics_rows)

    # ---- timelines figure ---------------------------------------------
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        figure, axes = plt.subplots(4, 1, sharex=True, figsize=(13, 11))
        ax_ev, ax_gain, ax_count, ax_luma = axes
        for run in runs:
            minutes = [(f.at - epoch).total_seconds() / 60 for f in run.frames]
            tag = f"{run.label} [{run.algorithm or run.blend_mode}]"
            ax_ev.plot(minutes, [f.ev for f in run.frames], linewidth=1.1, label=tag)
            ax_gain.plot(minutes, [f.iso for f in run.frames], linewidth=1.1, label=f"{tag} ISO")
            ax_count.plot(minutes, [f.blend_count for f in run.frames],
                          drawstyle="steps-post", linewidth=1.3, label=f"{tag} delivered")
            ax_count.plot(minutes, [f.asked for f in run.frames], ":",
                          drawstyle="steps-post", linewidth=0.9, alpha=0.6,
                          label=f"{tag} asked")
            rows = [r for r in metrics_rows if r["label"] == run.label]
            ax_luma.plot([r["minutes"] for r in rows], [r["meanLuma"] for r in rows],
                         marker="o", markersize=3, linewidth=1.1,
                         label=f"{tag} rendered luma")
            ax_luma.plot([r["minutes"] for r in rows], [r["shadowClip"] for r in rows],
                         "--", linewidth=0.9, alpha=0.7,
                         label=f"{tag} shadow-clip")
        ax_ev.set_ylabel("EV (frame)")
        ax_gain.set_ylabel("ISO")
        ax_gain.set_yscale("log")
        ax_count.set_ylabel("frames/blend")
        ax_luma.set_ylabel("rendered luma / clip")
        ax_luma.set_xlabel(f"minutes since {epoch:%H:%M:%S} UTC")
        for ax in axes:
            ax.grid(alpha=0.25)
            ax.legend(fontsize=7)
        figure.tight_layout()
        figure.savefig(args.out / "timelines.png", dpi=150)
    except ImportError:
        print("(matplotlib unavailable — timelines.png skipped)")

    # ---- anomaly detection + report -----------------------------------
    lines = [f"# Shoot audit — {epoch:%Y-%m-%d}", ""]
    ev_spans = {}
    for run in runs:
        evs = [f.ev for f in run.frames if f.ev is not None]
        ev_spans[run.label] = (max(evs) - min(evs)) if evs else 0.0
    max_span = max(ev_spans.values(), default=0)
    for run in runs:
        duration = ((run.end - run.start).total_seconds() / 60
                    if run.start and run.end else 0)
        shortfalls = [f for f in run.frames if f.shortfall]
        lost = sum((f.asked or 0) - (f.blend_count or 0) for f in shortfalls)
        thermal = {}
        for f in run.frames:
            if f.thermal:
                thermal[f.thermal] = thermal.get(f.thermal, 0) + 1
        rows = [r for r in metrics_rows if r["label"] == run.label]
        lines += [f"## {run.label} — {run.device}",
                  f"- algorithm **{run.algorithm or run.blend_mode}**, "
                  f"every {run.interval:g}s, {len(run.frames)} frames over "
                  f"{duration:.0f} min" if run.interval else
                  f"- {len(run.frames)} frames over {duration:.0f} min",
                  f"- EV span {ev_spans[run.label]:.1f} stops"]
        if shortfalls:
            lines.append(f"- **delivery shortfalls: {len(shortfalls)} windows, "
                         f"{lost} frames lost**")
        if thermal and set(thermal) != {"nominal"}:
            lines.append("- thermal at close: "
                         + "  ".join(f"{k}×{v}" for k, v in sorted(thermal.items())))
        if ev_spans[run.label] < 0.7 and duration > 20 and max_span >= 2:
            lines.append(f"- **ANOMALY — frozen exposure**: EV moved only "
                         f"{ev_spans[run.label]:.1f} stops in {duration:.0f} min "
                         f"while another device moved {max_span:.1f}; the "
                         f"exposure system did not follow the light")
        if rows:
            dark = [r for r in rows if r["meanLuma"] < 0.06]
            if dark and ev_spans[run.label] < 0.7:
                first = min(dark, key=lambda r: r["minutes"])
                lines.append(f"- **ANOMALY — dark drift**: rendered luma below "
                             f"0.06 from t+{first['minutes']:.0f} min with EV "
                             f"flat — frames went dark without exposure following")
            last_rows = rows[-3:]
            lines.append(f"- late-run rendered luma "
                         f"{np.mean([r['meanLuma'] for r in last_rows]):.3f}, "
                         f"shadow-clip {np.mean([r['shadowClip'] for r in last_rows]):.0%}, "
                         f"noise {np.mean([r['noise'] for r in last_rows]) * 1000:.1f}")
        lines.append("")
    lines += ["## Files", f"- metrics: `{csv_path.name}`",
              "- timelines: `timelines.png`",
              f"- contact sheets: {len(contact_paths)} × `contact-NN.jpg`", ""]
    (args.out / "report.md").write_text("\n".join(lines))
    print(f"Audit written to {args.out}/ "
          f"({len(metrics_rows)} sampled frames, {len(contact_paths)} sheets)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
