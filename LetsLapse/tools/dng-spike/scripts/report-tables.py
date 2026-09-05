#!/usr/bin/env python3
"""report-tables.py — the markdown tables of the spike report, from the bench CSV.

    scripts/report-tables.py <matrix.csv> [more.csv …] > docs/dng-archive-spike/matrix.md

Rows are grouped by (set, strategy) and averaged over the spot frames; the
throughput rows (frame = "throughput×N") get their own table. No dependencies
beyond the standard library, so the tables regenerate anywhere the CSV is.
"""
import csv
import sys
from collections import OrderedDict, defaultdict


def num(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def mean(values):
    values = [v for v in values if v is not None]
    return sum(values) / len(values) if values else None


def fmt(value, digits=1, suffix=""):
    return "" if value is None else f"{value:.{digits}f}{suffix}"


def load(paths):
    rows = []
    for path in paths:
        with open(path, newline="") as handle:
            rows.extend(csv.DictReader(handle))
    return rows


def strategy_table(rows, set_id):
    groups = OrderedDict()
    for row in rows:
        if row["set"] != set_id or row["frame"].startswith("throughput"):
            continue
        groups.setdefault(row["strategy"], []).append(row)
    lines = [
        "| strategy | out MB | ratio | ms/frame | fps | peak MB | PSNR dB | SSIM | stops RMS | vs source whole / block | Apple direct | WB warm/cool dB | ImageIO | QuickLook | notes |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|---|---|---|---|---|---|",
    ]
    for strategy, group in groups.items():
        errors = [g["error"] for g in group if g["error"]]
        if errors:
            lines.append(f"| `{strategy}` | | | | | | | | | | | | | | FAILED: {errors[0][:80]} |")
            continue
        out_mb = mean([num(g["out_bytes"]) for g in group])
        ratio = mean([num(g["ratio"]) for g in group])
        ms = mean([num(g["total_ms"]) for g in group])
        fps = 1000 / ms if ms else None
        peak = mean([num(g["peak_mb"]) for g in group])
        psnr = mean([num(g["psnr_db"]) for g in group])
        ssim = mean([num(g["ssim"]) for g in group])
        stops = mean([num(g["stops_rms"]) for g in group])
        whole = mean([num(g["whole_rel"]) for g in group])
        block = mean([num(g["block_rel"]) for g in group])
        direct = mean([num(g["apple_direct_whole"]) for g in group])
        repack = any(g["repack_applies"] == "yes" for g in group)
        warm = mean([num(g["wb_warm_psnr"]) for g in group])
        cool = mean([num(g["wb_cool_psnr"]) for g in group])
        imageio = "yes" if all(g["imageio_decodes"] == "yes" for g in group) else "NO"
        ql = "yes" if all(g["quicklook"] == "thumbnail drawn" for g in group) else "NO"
        note = ""
        if direct is not None and direct > 0.1:
            note = "Apple renders it WRONG directly"
        elif whole is not None and whole > 0.1:
            note = "off against the source's Apple decode"
        direct_text = (fmt(direct * 100, 1, "%") if direct is not None else "") + (" (Kit repacks)" if repack else "")
        wb = f"{fmt(warm)} / {fmt(cool)}" if warm is not None else ""
        lines.append(
            f"| `{strategy}` | {fmt(out_mb / 1e6, 2)} | {fmt(ratio, 1)}× | {fmt(ms, 0)} | {fmt(fps, 2)} | {fmt(peak, 0)} | "
            f"{fmt(psnr, 1)} | {fmt(ssim, 4)} | {fmt(stops, 3)} | {fmt(whole * 100 if whole is not None else None, 1, '%')} / "
            f"{fmt(block * 100 if block is not None else None, 1, '%')} | {direct_text} | {wb} | {imageio} | {ql} | {note} |"
        )
    return "\n".join(lines)


def stage_table(rows, set_id):
    groups = OrderedDict()
    for row in rows:
        if row["set"] != set_id or row["frame"].startswith("throughput") or row["error"]:
            continue
        groups.setdefault(row["strategy"], []).append(row)
    lines = [
        "| strategy | decode | demosaic (GPU) | curve | encode | write | total | size |",
        "|---|---:|---:|---:|---:|---:|---:|---|",
    ]
    for strategy, group in groups.items():
        def stage(name):
            return fmt(mean([num(g[name]) for g in group]), 0)
        size = group[0]["width"] + "×" + group[0]["height"]
        lines.append(f"| `{strategy}` | {stage('decode_ms')} | {stage('demosaic_ms')} | {stage('curve_ms')} | {stage('encode_ms')} | {stage('write_ms')} | {stage('total_ms')} | {size} |")
    return "\n".join(lines)


def throughput_table(rows):
    lines = ["| set | strategy | frames | wall s | fps | peak MB | notes |", "|---|---|---:|---:|---:|---:|---|"]
    for row in rows:
        if not row["frame"].startswith("throughput"):
            continue
        frames = row["frame"].split("×")[-1]
        lines.append(f"| {row['set']} | `{row['strategy']}` | {frames} | {fmt(num(row['total_ms']) / 1000 if num(row['total_ms']) else None, 1)} | {fmt(num(row['fps_single']), 2)} | {row['peak_mb']} | {row['notes'][:80]} |")
    return "\n".join(lines) if len(lines) > 2 else "_no throughput rows_"


def per_frame_table(rows, set_id):
    lines = ["| frame | strategy | out MB | ms | PSNR | SSIM | whole | block | Apple direct |", "|---|---|---:|---:|---:|---:|---:|---:|---:|"]
    for row in rows:
        if row["set"] != set_id or row["frame"].startswith("throughput") or row["error"]:
            continue
        lines.append(
            f"| {row['frame']} | `{row['strategy']}` | {fmt((num(row['out_bytes']) or 0) / 1e6, 2)} | {row['total_ms']} | {row['psnr_db']} | {row['ssim']} | "
            f"{fmt((num(row['whole_rel']) or 0) * 100, 1, '%')} | {fmt((num(row['block_rel']) or 0) * 100, 1, '%')} | {fmt((num(row['apple_direct_whole']) or 0) * 100, 1, '%')} |"
        )
    return "\n".join(lines)


def main():
    rows = load(sys.argv[1:])
    print("# Strategy matrix — generated by `tools/dng-spike/scripts/report-tables.py`\n")
    print(f"_{len([r for r in rows if not r['frame'].startswith('throughput')])} conversions from {', '.join(sys.argv[1:])}._\n")
    print("Quality columns: PSNR/SSIM/stops against the strategy's lossless twin (same decode, demosaic and size) for lossy rows and against the source for lossless rows; "
          "\"vs source\" is the LossyLinearDNGTests measure (worst channel of whole-frame / 8×6-block means against the Kit's decode of the input, linear P3, quarter scale); "
          "\"Apple direct\" is `CIRAWFilter(imageURL:)` on the output with no repack, whole-frame means against the input; WB = PSNR under ±2000 K pushes balanced in the converter.\n")
    for set_id, title in (("1", "Set 1 — Sony ILCE-7M4 ARW (dusk, dark, night)"), ("2", "Set 2 — LetsLapse Bayer DNG (iPhone 16 Pro, live blend)")):
        if not any(r["set"] == set_id for r in rows):
            continue
        print(f"## {title}\n")
        print(strategy_table(rows, set_id))
        print(f"\n### Stage timings (ms, mean of the spot frames)\n")
        print(stage_table(rows, set_id))
        print()
    print("## Throughput (frames in flight)\n")
    print(throughput_table(rows))
    print()
    for set_id in ("1", "2"):
        if any(r["set"] == set_id for r in rows):
            print(f"## Per-frame rows — set {set_id}\n")
            print(per_frame_table(rows, set_id))
            print()


if __name__ == "__main__":
    main()
