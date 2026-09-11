# Shape benchmark — generated report

Generated 2026-09-11T21:22:58Z from `/Volumes/letslapse/Projects` (tag "Shape testing", 37 assets, label set 25). Size floor applied to ground truth and detections: 0.10. Consensus rule: same primitive, centre offset ≤ 2.0 % of the diagonal, mask IoU ≥ 0.7 at a 1024-px working scale, aspect within 10 %; greedy one-to-one by IoU (no Hungarian — at most a dozen detections against a handful of labels per image).

## Decision gate (brief §8)

**opencv-reference 5cc92beb0d6e: median accepted candidates/image = 2.0 → ≤ 6 → geometry alone is sufficient for photo mode; no AI ranking layer**

## Runs

| detector | key | runAt | assets | pinned |
|---|---|---|---|---|
| apple-vision | `1/93b8a04130a8` | 2026-09-11T19:35:28Z | 37 | ✓ |
| apple-vision-register | `1/1031ec098d94` | 2026-09-11T19:35:28Z | 33 | ✓ |
| manual-groundtruth | `1/e89f36e6cd43` | 2026-09-11T21:16:10Z | 25 | ✓ |
| opencv-reference | `1/5cc92beb0d6e` | 2026-09-11T19:32:01Z | 37 | ✓ |
| opencv-reference | `1/6114968f7c78` | 2026-09-11T21:21:24Z | 37 |  |

## Detectors vs ground truth

| detector | labelled | GT (≥ floor) | TP | FP | FN | precision | recall | F1 | recall on rule-passing GT | aspect err med / p95 | centre offset med / p95 (% diag) | orientation err med (°) | subclass mismatches | measured as proposed | accepted/img med (p25–p75, max) | candidates/img med | ms/img med |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| opencv-reference | 25 | 68 | 38 | 24 | 30 | 61 % [49–72] (n=62) | 56 % [44–67] (n=68) | 0.58 | 55.9 % | 1.6 % / 7.1 % | 0.11 / 0.36 | 0.3 (n=24) | 5 | 16 of 95 | 2.0 (1–4, 9) | 216.0 | 3320 |
| apple-vision | 25 | 68 | 11 | 14 | 57 | 44 % [27–63] (n=25) | 16 % [9–27] (n=68) | 0.24 | 16.2 % | 1.0 % / 3.4 % (n<20) | 0.07 / 0.38 | 12.1 (n=2) | 2 | 21 of 39 | 1.0 (0–1, 5) | 89.0 | 1021 |
| apple-vision-register | 22 | 61 | 14 | 28 | 47 | 33 % [21–48] (n=42) | 23 % [14–35] (n=61) | 0.27 | 23.0 % | 1.4 % / 6.2 % (n<20) | 0.11 / 1.71 | 23.0 (n=3) | 3 | 39 of 56 | 1.0 (1–3, 4) | 2.0 | 0 |

Precision and recall are over the labelled assets only; accepted / candidates / runtime are over every asset the run covers. Brackets are Wilson 95 % intervals. Duplicates (a second detection on an already-matched label) count as FP.

### opencv-reference

| primitive | TP | FP | FN | recall |
|---|---|---|---|---|
| ellipse | 18 | 9 | 19 | 49 % [33–64] (n=37) |
| rectangle | 20 | 15 | 11 | 65 % [47–79] (n=31) |

| GT size band | TP | FN | recall |
|---|---|---|---|
| small | 25 | 22 | 53 % [39–67] (n=47) |
| medium | 10 | 6 | 62 % [39–82] (n=16) |
| large | 3 | 2 | 60 % [23–88] (n=5) |

Subclass confusion on matched pairs (rows = ground truth, columns = detector):

| GT \ det | circle | ellipse | square | rectangle |
|---|---|---|---|---|
| circle | 13 | 1 | 0 | 0 |
| ellipse | 2 | 2 | 0 | 0 |
| square | 0 | 0 | 6 | 1 |
| rectangle | 0 | 0 | 1 | 12 |

Centre offset histogram (% of diagonal, 0.25 % bins): 0.00+: 31, 0.25+: 5, 0.50+: 2

Size-floor sweep (accepted shapes per image at alternative floors, from the candidate log — no re-run):

| floor | median | p25–p75 | max |
|---|---|---|---|
| 0.10 | 2.0 | 1–4 | 9 |
| 0.15 | 1.0 | 1–2 | 5 |
| 0.20 | 1.0 | 0–2 | 5 |
| 0.25 | 1.0 | 0–1 | 4 |

### apple-vision

| primitive | TP | FP | FN | recall |
|---|---|---|---|---|
| ellipse | 11 | 10 | 26 | 30 % [17–46] (n=37) |
| rectangle | 0 | 4 | 31 | 0 % [0–11] (n=31) |

| GT size band | TP | FN | recall |
|---|---|---|---|
| small | 4 | 43 | 9 % [3–20] (n=47) |
| medium | 6 | 10 | 38 % [18–61] (n=16) |
| large | 1 | 4 | 20 % [4–62] (n=5) |

Subclass confusion on matched pairs (rows = ground truth, columns = detector):

| GT \ det | circle | ellipse | square | rectangle |
|---|---|---|---|---|
| circle | 8 | 1 | 0 | 0 |
| ellipse | 1 | 1 | 0 | 0 |

Centre offset histogram (% of diagonal, 0.25 % bins): 0.00+: 8, 0.25+: 3

Size-floor sweep (accepted shapes per image at alternative floors, from the candidate log — no re-run):

| floor | median | p25–p75 | max |
|---|---|---|---|
| 0.10 | 1.0 | 1–2 | 5 |
| 0.15 | 1.0 | 1–2 | 5 |
| 0.20 | 1.0 | 1–1 | 4 |
| 0.25 | 1.0 | 0–1 | 3 |

### apple-vision-register

| primitive | TP | FP | FN | recall |
|---|---|---|---|---|
| ellipse | 14 | 26 | 21 | 40 % [26–56] (n=35) |
| rectangle | 0 | 2 | 26 | 0 % [0–13] (n=26) |

| GT size band | TP | FN | recall |
|---|---|---|---|
| small | 5 | 36 | 12 % [5–26] (n=41) |
| medium | 8 | 7 | 53 % [30–75] (n=15) |
| large | 1 | 4 | 20 % [4–62] (n=5) |

Subclass confusion on matched pairs (rows = ground truth, columns = detector):

| GT \ det | circle | ellipse | square | rectangle |
|---|---|---|---|---|
| circle | 10 | 1 | 0 | 0 |
| ellipse | 2 | 1 | 0 | 0 |

By v1 provenance (`captured` = left standing by the shooter on the viewfinder, `detected` = the file pass / Find shapes):

| source | shapes ≥ floor | TP | FP |
|---|---|---|---|
| captured | 22 | 10 | 12 |
| detected | 20 | 4 | 16 |

Centre offset histogram (% of diagonal, 0.25 % bins): 0.00+: 9, 0.25+: 3, 1.50+: 1, 1.75+: 1

Size-floor sweep (accepted shapes per image at alternative floors, from the candidate log — no re-run):

| floor | median | p25–p75 | max |
|---|---|---|---|
| 0.10 | 2.0 | 1–3 | 4 |
| 0.15 | 2.0 | 1–3 | 4 |
| 0.20 | 2.0 | 1–3 | 4 |
| 0.25 | 1.0 | 1–1 | 3 |

## Per asset

| asset | name | GT | opencv-reference TP/FP/FN (acc, cand) | apple-vision TP/FP/FN (acc, cand) | apple-vision-register TP/FP/FN (acc, cand) |
|---|---|---|---|---|---|
| 017F2704 | 1 photos | 9 | 2/7/7 (9, 415) | 1/3/8 (4, 142) | 1/0/8 (1, 1) |
| 02A0573B | 1 photos | 2 | 1/0/1 (1, 221) | 1/0/1 (1, 59) | 1/2/1 (3, 4) |
| 0BB87681 | 1 photos | 4 | 1/0/3 (1, 21) | 1/1/3 (2, 36) | 2/2/2 (4, 5) |
| 11C2EC0F | 1 photos | 1 | 1/0/0 (1, 278) | 0/0/1 (0, 58) | — |
| 19F20A05 | 1 photos | 2 | 1/1/1 (2, 182) | 1/1/1 (2, 94) | 1/1/1 (2, 2) |
| 2306FD1B | 1 photos | 2 | 2/0/0 (2, 87) | 1/0/1 (1, 48) | 1/1/1 (2, 2) |
| 48F0E90D | 1 photos | 1 | 1/0/0 (1, 278) | 1/0/0 (1, 162) | 1/1/0 (2, 2) |
| 50E24192 | 1 photos | 2 | 1/0/1 (1, 206) | 0/0/2 (0, 81) | 0/0/2 (0, 1) |
| 51208197 | 1 photos | 2 | 1/0/1 (1, 31) | 0/0/2 (0, 51) | 0/0/2 (0, 2) |
| 5D452591 | 1 photos | 3 | 2/1/1 (3, 320) | 1/1/2 (2, 114) | 1/3/2 (4, 5) |
| 5DF429BD | 1 photos | 2 | 1/3/1 (4, 237) | 0/1/2 (1, 109) | 0/2/2 (2, 2) |
| 606B29B0 | 1 photos | 5 | 3/0/2 (3, 419) | 0/0/5 (0, 113) | 0/0/5 (0, 3) |
| 60FC1F35 | 1 photos | 1 | 0/1/1 (1, 172) | 0/1/1 (1, 86) | 0/1/1 (1, 1) |
| 6426B50C | 1 photos | 2 | 0/0/2 (0, 192) | 0/0/2 (0, 65) | 0/3/2 (3, 3) |
| 69200198 | 1 photos | 0 | 0/0/0 (0, 216) | 0/0/0 (0, 89) | — |
| 7746D41B | 1 photos | 2 | 2/2/0 (4, 296) | 1/0/1 (1, 146) | 1/0/1 (1, 3) |
| 96752BAC | 1 photos | 6 | 1/3/5 (4, 309) | 0/3/6 (3, 112) | 1/2/5 (3, 3) |
| 9D619859 | 1 photos | 3 | 3/0/0 (3, 446) | 0/0/3 (0, 116) | 0/4/3 (4, 5) |
| A7F2AB82 | 1 photos | 2 | 2/1/0 (3, 62) | 1/0/1 (1, 60) | 1/2/1 (3, 9) |
| C71D3F3B | 1 photos | 5 | 4/1/1 (5, 237) | 1/0/4 (1, 89) | 1/2/4 (3, 6) |
| D877F2BD | 1 photos | 2 | 1/1/1 (2, 66) | 1/0/1 (1, 31) | 1/0/1 (1, 1) |
| E0556DD6 | 1 photos | 2 | 2/2/0 (4, 234) | 0/0/2 (0, 139) | 1/0/1 (1, 1) |
| E3470B75 | 1 photos | 1 | 0/0/1 (0, 92) | 0/0/1 (0, 39) | 0/0/1 (0, 0) |
| F7EC5F46 | 1 photos | 6 | 5/1/1 (6, 127) | 0/2/6 (2, 83) | — |
| FC1137ED | 1 photos | 1 | 1/0/0 (1, 19) | 0/1/1 (1, 34) | 0/2/1 (2, 2) |
