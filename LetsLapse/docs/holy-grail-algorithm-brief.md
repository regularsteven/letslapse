# Holy Grail Algorithm Selection — Design Brief

**Project:** LetsLapse iOS App  
**Subject:** Dynamic blend algorithm selection for interval capture  
**Status:** For peer review

---

## Background

LetsLapse captures interval timelapses across dramatic lighting transitions — sunrise, sunset, the full day-to-night arc (the "holy grail" in timelapse photography). The core problem: single-frame capture produces 8–9 stops of dynamic range in low light. Competitors using computational multi-frame stacking reach 11–14 stops. The gap is 3–6 stops.

The proposed solution is a user-selectable blend algorithm that adapts the number of stacked frames per capture cycle to the prevailing light conditions. The algorithm runs on-device, in real time, for the duration of the shoot.

Three candidate algorithms are proposed. Two are ready to implement. A third is offered here for peer review before committing.

---

## Algorithm 1 — Zone

**Status:** Implemented. Shipping as default.

### Concept

Named after Ansel Adams' Zone System, which divides the tonal scale into discrete exposure zones. Zone maps the camera's current Exposure Value (EV) to a fixed burst count through a lookup table of discrete thresholds.

### Decision logic

| EV range | Burst frames blended |
|----------|----------------------|
| ≥ 13 | 8 (device-capped) |
| 10 – 13 | 5 |
| 7 – 10 | 3 |
| 4 – 7 | 2 |
| < 4 | 1 |

A 3-cycle rolling average prevents flicker when EV hovers near a boundary. Burst count is always capped by the device's measured write throughput (profiled at session start).

### Characteristics

- **Reactive** — responds to the current EV reading. Does not anticipate transitions.
- **Deterministic** — same EV always produces the same burst count. Easy to reason about and debug.
- **Abrupt at boundaries** — when EV crosses a threshold, burst count changes by 2–3 frames at once, which can introduce a subtle step in the output at golden hour.
- **Computationally trivial** — table lookup only.

### Best suited for

Stable-light conditions, or as a conservative default where predictability matters more than perfect smoothness.

---

## Algorithm 2 — Latitude

**Status:** Designed, ready to implement.

### Concept

Named after photographic exposure latitude — the range of exposures a film or sensor can handle gracefully. Latitude replaces the stepped lookup table with a continuous sigmoid curve and adds **anticipatory adjustment** based on how fast the light is changing.

### Decision logic

Burst count is computed from:

1. **Sigmoid mapping** — EV 0–16 maps continuously to burst count 1–8 via an S-curve. No hard thresholds; the count changes fractionally with each EV shift.

2. **EV velocity factor** — the algorithm tracks the rolling rate of EV change over the last 5 capture cycles (stops per cycle). When EV is dropping faster than ~0.3 stops/cycle (a fast sunset), the sigmoid output is shifted upward — the algorithm pre-loads more frames before the scene has fully transitioned.

3. **ISO ceiling adaptation** — when EV velocity is near zero (stable light), a tighter ISO ceiling is applied (favoring image quality). When velocity is high (active transition), the ceiling relaxes to prioritise exposure.

### Characteristics

- **Anticipatory** — reads the direction and speed of EV change, not just its current value.
- **Smooth** — no hard steps in blend count. Transitions in the output are gradual.
- **Slightly more complex** — requires maintaining a rolling EV history per session.
- **Still metadata-driven** — decisions are made entirely from AE/ISO readings, not from the image data itself.

### Best suited for

Holy grail shoots with a clear, fast transition (golden hour to blue hour). Expected to outperform Zone visibly in the 30–60 minutes around sunset/sunrise.

### Comparison with Zone

| Property | Zone | Latitude |
|---|---|---|
| Transition | Stepped | Continuous |
| Behaviour | Reactive | Anticipatory |
| ISO handling | Fixed ceiling | Velocity-adaptive |
| Complexity | Trivial | Low |

---

## Algorithm 3 — Lumen *(proposed — for peer review)*

**Status:** Concept only. Not yet designed for implementation.

### Concept

Zone and Latitude both operate on the **exposure side** — they ask how the camera is capturing the scene and adjust accordingly. Lumen works on the **image side**: it analyses the actual pixel data from each captured DNG frame and makes blend decisions based on what is demonstrably present in the image, not what the AE system estimates.

The core insight: EV is a derived number that describes the camera's exposure intent. It does not tell you whether shadows are clipping, whether highlights are blown, or how much usable dynamic range the sensor actually captured. A scene at EV 7 with most of the histogram pushed into the shadows needs very different treatment than a scene at EV 7 with a balanced tonal distribution. Zone and Latitude cannot distinguish these. Lumen can.

### Proposed decision logic

On each captured frame (or the first frame of a burst, as a sample):

1. **Histogram analysis** — compute the luminance histogram from the DNG raw data. Extract:
   - Shadow clip percentage (pixels below the noise floor)
   - Highlight clip percentage (pixels above recovery threshold)
   - Midtone spread (IQR of the luminance distribution)

2. **DR utilisation score** — combine the above into a single score representing how well the current exposure is using the sensor's available dynamic range. High score = well-exposed, low score = shadows clipping or highlights blown.

3. **Blend count from DR score** — map DR utilisation to burst count. When shadows are clipping (score low), increase frames to lift shadow SNR. When exposure is well-distributed, fewer frames needed.

4. **Temporal consistency gate** — before changing burst count, project what the blend output luminance would be at the proposed new count, and compare to the previous cycle's output luminance. If the projected change would exceed a perceptual threshold (e.g. 0.5 JND), defer the change by one cycle. This prioritises continuity in the *output video* over responsiveness to the input signal.

### Why this may be better than Zone and Latitude

- Responds to what is actually in the image, not a metadata proxy.
- Can detect and respond to local scene events that EV alone misses: a car passing through frame, a bright cloud appearing, a street lamp switching on.
- The temporal consistency gate directly targets the artefact that matters most: visible flicker or luminance steps in the output.
- DR utilisation score could be logged to `capture_log.json`, enabling post-shoot analysis of exactly when and why blend decisions were made.

### Open questions for peer review

1. **Performance** — histogram analysis on each DNG frame adds per-cycle compute. On an iPhone 16 Pro this is likely feasible within a 3-second interval, but needs benchmarking. The analysis could run on a background thread on the previous frame while the current frame is being written.

2. **Cold start** — the algorithm needs at least one captured frame before it can make decisions. Zone and Latitude can compute burst count before the first capture, using the live viewfinder's AE. Lumen cannot; a fallback to Zone for the first cycle is required.

3. **ISO interaction** — the current pipeline controls ISO and shutter via the ramp engine. Lumen's blend decisions are image-derived but ISO decisions would still come from the ramp. These two systems need coordination: if Lumen increases burst count to compensate for shadow clipping, should the ramp also adjust ISO, or should the blend do the lifting alone? Conflating both could over-correct.

4. **Noise floor reference** — the shadow clip threshold needs calibrating per device. The capability profiler (already implemented) could be extended to capture a dark-frame reference at session start, establishing the actual noise floor rather than using a fixed threshold.

5. **Computational cost in extreme cold** — DNG histogram analysis on the main thread would delay the next capture trigger. Needs profiling to establish whether this fits within the minimum supported interval (currently ~1 second).

### Best suited for

Conditions where EV alone is an unreliable guide — highly variable scenes, urban night shoots with artificial light mixing, dawn with rapidly clearing cloud cover. Potentially the strongest performer in the most difficult conditions, at the cost of implementation complexity.

---

## Test protocol

All three algorithms produce a `capture_log.json` at session end containing per-frame: index, timestamp, ISO, shutter, aperture, EV, blend count, and (for Lumen) DR utilisation score. A reference Python analyzer (`tools/testcard_report.py`) ingests these logs for quantitative comparison.

**Recommended comparison shoot:**

- Device A: Zone (default)
- Device B: Latitude
- Device C: Lumen (when implemented)
- Same scene, same interval (e.g. 5 seconds), same start time, 90-minute window covering 30 min before to 60 min after local sunset
- Post-shoot: overlay `capture_log.json` blend count graphs for all three devices; compare output videos frame-by-frame at the 15-minute mark after sunset

---

*Prepared for peer review. Algorithms 1 and 2 are ready to implement pending review sign-off. Algorithm 3 (Lumen) is offered as a concept — implementation should not begin until the open questions above are resolved.*
