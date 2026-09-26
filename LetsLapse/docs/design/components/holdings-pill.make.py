#!/usr/bin/env python3
"""Generates components/holdings-pill.<state>.svg — the status pill of plan §16
(App/HoldingsPill.swift: HoldingsPillBody, StatusGlyphView), measured from the
16 Pro's own render (LL_PILL_SHEET=1, 2026-09-26): 18 pt high, 5 pt padding,
3 pt gaps, camera 13 · layers 11.3 · cloud 14.5 pt wide, a 0.5 pt hairline
with 1 pt either side. Re-run after changing a state: python3 holdings-pill.make.py
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
GREEN = "#30D158"          # StatusGlyphView green, on a photo
GREY = ('#FFFFFF', 0.45)   # white at 45 %: not on this device
NEUTRAL = ('#FFFFFF', 0.9) # the cloud at rest
AMBER = "#FFB340"          # LL.amber — moving, checking
RED = "#FF453A"            # attention
KNOCK = "#1F1F21"          # a knocked-out symbol: the capsule's own tone over a dark photo

CAM_BODY = ("M5.6 7.2H8.3L9.7 5Q10.1 4.4 10.8 4.4H13.2Q13.9 4.4 14.3 5L15.7 7.2H18.4A3.1 3.1 0 0 1 21.5 10.3"
            "V17.4A3.1 3.1 0 0 1 18.4 20.5H5.6A3.1 3.1 0 0 1 2.5 17.4V10.3A3.1 3.1 0 0 1 5.6 7.2Z")
CLOUD = "M6.5 19.5H17.8A4.6 4.6 0 0 0 18.6 10.4A6.8 6.8 0 0 0 5.8 9.3A5.2 5.2 0 0 0 6.5 19.5Z"
L_TOP = "M12 3.2L20.8 8L12 12.8L3.2 8Z"
SYMBOL = {
    "safe": '<path d="M8.4 14L11 16.5L15.8 11.7" fill="none" stroke="{k}" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"/>',
    "needs": '<path d="M12 17.3V10.7M9.1 13.4L12 10.5L14.9 13.4" fill="none" stroke="{k}" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"/>',
    "up": '<path d="M12 17.3V10.7M9.1 13.4L12 10.5L14.9 13.4" fill="none" stroke="{k}" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"/>',
    "down": '<path d="M12 10.5V17.1M9.1 14.4L12 17.3L14.9 14.4" fill="none" stroke="{k}" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"/>',
    "checking": ('<path d="M15.1 12.2A3.3 3.3 0 1 0 15.3 15.3" fill="none" stroke="{k}" stroke-width="2.3" stroke-linecap="round"/>'
                 '<path d="M15.6 10L15.2 12.5L12.8 12.1" fill="none" stroke="{k}" stroke-width="2.1" stroke-linecap="round" stroke-linejoin="round"/>'),
    "waiting": '<path d="M10.3 11.7V16.5M13.7 11.7V16.5" stroke="{k}" stroke-width="2.5" stroke-linecap="round"/>',
    "alert": '<path d="M12 10.6V14.4" stroke="{k}" stroke-width="2.6" stroke-linecap="round"/><circle cx="12" cy="16.9" r="1.4" fill="{k}"/>',
}
CLOUD_SF = {"safe": "checkmark.icloud.fill", "needs": "icloud.and.arrow.up.fill", "up": "icloud.and.arrow.up.fill",
            "down": "icloud.and.arrow.down.fill", "checking": "arrow.clockwise.icloud.fill",
            "waiting": "icloud.fill + pause.fill knocked out", "alert": "exclamationmark.icloud.fill"}
CLOUD_TINT = {"safe": NEUTRAL, "needs": NEUTRAL, "waiting": NEUTRAL, "up": AMBER, "down": AMBER, "checking": AMBER, "alert": RED}
PLACE_TINT = {"here": GREEN, "there": GREY, "nowhere": GREY}


def paint(tint):
    return f'fill="{tint[0]}" fill-opacity="{tint[1]}"' if isinstance(tint, tuple) else f'fill="{tint}"'


def stroke(tint):
    return f'stroke="{tint[0]}" stroke-opacity="{tint[1]}"' if isinstance(tint, tuple) else f'stroke="{tint}"'


def fit(x, width, span_x, span_y):
    """transform placing a 24-grid glyph whose ink spans span_x/span_y at x, `width` wide, centred on y 9."""
    s = width / (span_x[1] - span_x[0])
    tx = x - span_x[0] * s
    ty = 9 - (span_y[0] + span_y[1]) / 2 * s
    return f'translate({tx:.2f},{ty:.2f}) scale({s:.4f})'


def camera(x, place):
    t = PLACE_TINT[place]
    body = (f'<path {paint(t)} fill-rule="evenodd" d="{CAM_BODY}M7.7 13.7a4.3 4.3 0 1 0 8.6 0a4.3 4.3 0 1 0 -8.6 0Z'
            f'M9.6 13.7a2.4 2.4 0 1 0 4.8 0a2.4 2.4 0 1 0 -4.8 0Z"/>')
    sym = "camera.fill"
    if place == "nowhere":
        sym = "camera.fill + a slash knocked through (no SF camera.slash)"
        body = (f'<mask id="knock-camera" maskUnits="userSpaceOnUse" x="0" y="0" width="24" height="24">'
                f'<rect width="24" height="24" fill="#FFFFFF"/><path d="M3 2.4L21 21.6" stroke="#000000" stroke-width="5" stroke-linecap="round"/></mask>'
                f'<g mask="url(#knock-camera)">{body}</g>'
                f'<path d="M3 2.4L21 21.6" {stroke(t)} stroke-width="2.3" stroke-linecap="round"/>')
    return f'<g transform="{fit(x, 13, (2.5, 21.5), (4.4, 20.5))}" data-symbol="{sym}">{body}</g>'


def layers(x, place):
    t = PLACE_TINT[place]
    if place == "nowhere":
        body = (f'<mask id="knock-layers" maskUnits="userSpaceOnUse" x="0" y="0" width="24" height="24">'
                f'<rect width="24" height="24" fill="#FFFFFF"/><path d="M3 2.4L21 21.6" stroke="#000000" stroke-width="5" stroke-linecap="round"/></mask>'
                f'<g mask="url(#knock-layers)" fill="none" {stroke(t)} stroke-width="2.2" stroke-linejoin="round" stroke-linecap="round">'
                f'<path d="{L_TOP}"/><path d="M3.2 11.6L12 16.4L20.8 11.6"/><path d="M3.2 15.2L12 20L20.8 15.2"/></g>'
                f'<path d="M3 2.4L21 21.6" {stroke(t)} stroke-width="2.3" stroke-linecap="round"/>')
        sym = "square.3.layers.3d.slash"
    else:
        body = (f'<path d="{L_TOP}" {paint(t)}/>'
                f'<g fill="none" {stroke(t)} stroke-width="2.2" stroke-linejoin="round" stroke-linecap="round">'
                f'<path d="M3.2 11.6L12 16.4L20.8 11.6"/><path d="M3.2 15.2L12 20L20.8 15.2"/></g>')
        sym = "square.3.layers.3d.top.filled"
    return f'<g transform="{fit(x, 11.3, (3.2, 20.8), (3.2, 20))}" data-symbol="{sym}">{body}</g>'


def cloud(x, state):
    t = CLOUD_TINT[state]
    # The symbol is knocked OUT of the cloud (a mask), so the capsule shows
    # through it on any photo, as SF Symbols' filled clouds do.
    mask = (f'<mask id="knock-cloud" maskUnits="userSpaceOnUse" x="0" y="0" width="24" height="24">'
            f'<rect width="24" height="24" fill="#FFFFFF"/>{SYMBOL[state].format(k="#000000")}</mask>')
    body = f'{mask}<path d="{CLOUD}" {paint(t)} mask="url(#knock-cloud)"/>'
    return f'<g transform="{fit(x, 14.5, (1.3, 22.4), (3.7, 19.5))}" data-symbol="{CLOUD_SF[state]}">{body}</g>'


STATES = [
    # file state, originals, blends, cloud, what it says (the pill's VoiceOver words), the moment
    ("here.safe", "here", None, "safe", "On this device · Backed up", "the photos here, every one verified on PicPlace"),
    ("here.needs", "here", None, "needs", "On this device · Needs uploading", "just shot, or only the project's records on PicPlace"),
    ("here.checking", "here", None, "checking", "On this device · Checking with PicPlace",
     "an upload just ended and PicPlace is reading it back (≈40–60 s), or free up space verifying before a removal"),
    ("here.uploading", "here", None, "up", "On this device · Uploading", "the originals going up (a records-only sync draws nothing)"),
    ("here.waiting", "here", None, "waiting", "On this device · Upload waiting", "a job paused, held for Wi-Fi, or stopped by iOS"),
    ("here.attention", "here", None, "alert", "On this device · Needs attention", "a failed upload or sync, a conflict"),
    ("there.safe", "there", None, "safe", "Download available · Backed up",
     "a preview: the originals removed here or never pulled — PicPlace holds them, so the tick stays"),
    ("there.downloading", "there", None, "down", "Download available · Downloading", "the originals coming down"),
    ("both.safe", "here", "here", "safe", "On this device · Blends on this device · Backed up", "photos and every blend here, all verified"),
    ("both.needs", "here", "here", "needs", "On this device · Blends on this device · Needs uploading",
     "a new blend (or the photos) not on PicPlace yet"),
    ("both.uploading", "here", "here", "up", "On this device · Blends on this device · Uploading", "a blend or the photos going up"),
    ("both.checking", "here", "here", "checking", "On this device · Blends on this device · Checking with PicPlace",
     "just uploaded, PicPlace reading it back"),
    ("here.blend-there.safe", "here", "there", "safe", "On this device · Blends on PicPlace · Backed up",
     "the photos here; a blend removed here, safe on PicPlace"),
    ("there.blend-here.safe", "there", "here", "safe", "Download available · Blends on this device · Backed up",
     "the originals removed, the blend kept — what's here is safe too"),
    ("there.blend-there.safe", "there", "there", "safe", "Download available · Blends on PicPlace · Backed up",
     "a preview whose originals and blends are all on PicPlace"),
    ("nowhere", "nowhere", "nowhere", None, "Not available to download · Blends not available",
     "a preview whose files are neither here nor on PicPlace (Victory Bridge Sunset)"),
    ("nowhere.originals", "nowhere", None, None, "Not available to download", "the originals nowhere reachable, no blends"),
    ("unconnected.blend-here", None, "here", None, "Blends on this device",
     "a library never connected to PicPlace: the camera, here by definition, is hidden; green layers say the project has blends"),
    # one blend's pill — a blend row, drawn at 0.8 on its thumbnail
    ("blend.here.safe", None, "here", "safe", "Blends on this device · Backed up", "a blend row: the clip here and on PicPlace"),
    ("blend.here.needs", None, "here", "needs", "Blends on this device · Needs uploading", "a blend row: the clip only here"),
    ("blend.here.uploading", None, "here", "up", "Blends on this device · Uploading", "a blend row: its project's heavy run"),
    ("blend.there.safe", None, "there", "safe", "Blends on PicPlace · Backed up", "a blend row: the clip only on PicPlace (Download)"),
    ("blend.there", None, "there", None, "Blends on PicPlace", "a blend row: not here, PicPlace's list not read yet — no claim"),
    ("blend.nowhere", None, "nowhere", None, "Blends not available", "a blend row: neither here nor on PicPlace (no Download)"),
    ("blend.downloading", None, "there", "down", "Blends on PicPlace · Downloading", "a blend row: coming down"),
]


def build(name, originals, blends, cl, words, moment):
    parts, x = [], 5.0
    if originals:
        parts.append(camera(x, originals)); x += 13
    if blends:
        if parts:
            x += 3
        parts.append(layers(x, blends)); x += 11.3
    if cl:
        if parts:
            x += 3
            parts.append(f'<rect x="{x + 1:.2f}" y="4" width="0.5" height="10" fill="#FFFFFF" fill-opacity="0.35"/>')
            x += 2.5 + 3
        parts.append(cloud(x, cl)); x += 14.5
    width = max(22.0, round(x + 5, 1))
    if width > x + 5:  # a lone glyph centres in the 22 pt minimum
        shift = (width - (x + 5)) / 2
        parts = [f'<g transform="translate({shift:.2f},0)">' + "".join(parts) + '</g>']
    w = f"{width:g}"
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} 18" width="{w}" height="18">
  <title>Component · Holdings pill · {name}</title>
  <desc>Mirrors HoldingsPillBody + StatusGlyphView (App/HoldingsPill.swift, plan §16 — signed off 2026-09-26 on the canvas "Holdings Pill States", revision 2.1). Reads: {words}. The moment: {moment}. Green = on this device; grey = on PicPlace, not here; slashed = nowhere reachable; one cloud, never green — ✓ PicPlace holds everything the project has, ↑ something here isn't up yet, amber while moving or checking, red for attention. Measured from the 16 Pro's own render (LL_PILL_SHEET=1).</desc>
  <!-- LetsLapse design component · Holdings pill · {w}×18, origin top-left. Generated by holdings-pill.make.py; see components/README.md. -->
  <g id="holdings-pill" data-state="{name}">
    <rect x="0" y="0" width="{w}" height="18" rx="9" fill="#000" fill-opacity="0.5"/>
    {"".join(parts)}
  </g>
</svg>
'''


if __name__ == "__main__":
    for spec in STATES:
        svg = build(*spec)
        path = os.path.join(HERE, f"holdings-pill.{spec[0]}.svg")
        open(path, "w").write(svg)
        width = svg.split('width="')[1].split('"')[0]
        print(f"holdings-pill.{spec[0]}.svg  {width}×18")
