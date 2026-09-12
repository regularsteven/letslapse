# Shape benchmark — generated report

Generated 2026-09-12T09:14:13Z from `/Volumes/letslapse/Projects` (tag "Shape testing", 37 assets, label set 25). Size floor applied to ground truth and detections: 0.10. Consensus rule: same primitive, centre offset ≤ 2.0 % of the diagonal, mask IoU ≥ 0.7 at a 1024-px working scale, aspect within 10 %; greedy one-to-one by IoU (no Hungarian — at most a dozen detections against a handful of labels per image).

## Decision gate (brief §8)

**opencv-reference a49d2b2eb28e: median accepted candidates/image = 2.0 → ≤ 6 → geometry alone is sufficient for photo mode; no AI ranking layer**

## Runs

| detector | key | runAt | assets | pinned |
|---|---|---|---|---|
| apple-vision | `1/294b1327db76` | 2026-09-12T06:39:40Z | 37 |  |
| apple-vision | `1/dd1309823bbd` | 2026-09-12T06:42:52Z | 37 |  |
| apple-vision | `1/aaa7ac724bca` | 2026-09-12T06:45:56Z | 37 |  |
| apple-vision | `1/3a2071895eeb` | 2026-09-12T06:49:10Z | 37 |  |
| apple-vision | `1/8c343ec8bc13` | 2026-09-12T06:50:41Z | 37 |  |
| apple-vision | `1/fc8bfcfcf3dc` | 2026-09-12T06:53:54Z | 37 |  |
| apple-vision | `1/40c7353f8987` | 2026-09-12T06:55:37Z | 37 |  |
| apple-vision | `1/f7fef8b9a7bb` | 2026-09-12T06:59:42Z | 37 |  |
| apple-vision | `1/18af76fb2371` | 2026-09-12T07:48:41Z | 37 |  |
| apple-vision | `1/0a949c12c77b` | 2026-09-12T07:52:39Z | 37 |  |
| apple-vision | `1/630594b98ea9` | 2026-09-12T09:14:12Z | 37 | ✓ |
| apple-vision-register | `1/01e9cab7f08c` | 2026-09-12T06:39:40Z | 33 |  |
| apple-vision-register | `1/26f7ceec831c` | 2026-09-12T09:14:12Z | 33 | ✓ |
| manual-groundtruth | `1/e89f36e6cd43` | 2026-09-12T09:08:09Z | 37 | ✓ |
| opencv-reference | `1/d7fa78344644` | 2026-09-12T06:30:10Z | 37 |  |
| opencv-reference | `1/a49d2b2eb28e` | 2026-09-12T07:45:38Z | 37 | ✓ |

## Detectors vs ground truth

| detector | labelled | GT (≥ floor) | TP | FP | FN | precision | recall | F1 | recall on rule-passing GT | aspect err med / p95 | centre offset med / p95 (% diag) | orientation err med (°) | subclass mismatches | measured as proposed | FP nested in a label (precision without them) | accepted/img med (p25–p75, max) | candidates/img med | ms/img med |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| opencv-reference · dedupe 0.7 | 37 | 153 | 61 | 33 | 92 | 65 % [55–74] (n=94) | 40 % [32–48] (n=153) | 0.49 | 40.9 % | 0.8 % / 5.7 % | 0.09 / 0.32 | 0.2 (n=40) | 3 | 31 of 94 | 15 (77.2 %) | 2.0 (1–3, 12) | 216.0 | 2925 |
| opencv-reference · dedupe 0.9 | 37 | 153 | 66 | 43 | 87 | 61 % [51–69] (n=109) | 43 % [36–51] (n=153) | 0.50 | 44.3 % | 0.9 % / 6.3 % | 0.10 / 0.53 | 0.2 (n=42) | 5 | 32 of 109 | 24 (77.6 %) | 2.0 (1–4, 13) | 216.0 | 3032 |
| apple-vision · file all/medium/all -regions | 37 | 153 | 24 | 23 | 129 | 51 % [37–65] (n=47) | 16 % [11–22] (n=153) | 0.24 | 16.1 % | 1.3 % / 5.7 % | 0.08 / 0.72 | 0.5 (n=11) | 3 | 29 of 47 | 14 (72.7 %) | 1.0 (0–1, 7) | 89.0 | 971 |
| apple-vision · file all/medium/all +regions | 37 | 153 | 33 | 25 | 120 | 57 % [44–69] (n=58) | 22 % [16–29] (n=153) | 0.31 | 22.1 % | 1.4 % / 7.1 % | 0.09 / 0.80 | 0.5 (n=19) | 3 | 35 of 58 | 16 (78.6 %) | 1.0 (0–2, 10) | 89.0 | 1193 |
| apple-vision · file all/medium/all -regions floor 0.100 | 37 | 153 | 38 | 23 | 115 | 62 % [50–73] (n=61) | 25 % [19–32] (n=153) | 0.36 | 25.5 % | 1.2 % / 7.9 % | 0.09 / 0.90 | 1.3 (n=19) | 8 | 34 of 61 | 13 (79.2 %) | 1.0 (1–2, 9) | 155.0 | 936 |
| apple-vision · file all/medium/all +regions floor 0.100 | 37 | 153 | 50 | 33 | 103 | 60 % [49–70] (n=83) | 33 % [26–40] (n=153) | 0.42 | 33.6 % | 1.1 % / 8.2 % | 0.12 / 0.86 | 0.9 (n=30) | 8 | 51 of 83 | 17 (75.8 %) | 1.0 (1–2, 17) | 155.0 | 1200 |
| apple-vision · file all/low/all -regions | 37 | 153 | 23 | 12 | 130 | 66 % [49–79] (n=35) | 15 % [10–22] (n=153) | 0.24 | 15.4 % | 1.1 % / 4.6 % | 0.06 / 0.45 | 0.4 (n=11) | 2 | 16 of 35 | 9 (88.5 %) | 1.0 (0–1, 7) | 56.0 | 282 |
| apple-vision · file all/high/all -regions | 37 | 153 | 27 | 47 | 126 | 36 % [26–48] (n=74) | 18 % [12–24] (n=153) | 0.24 | 18.1 % | 1.4 % / 7.2 % | 0.13 / 0.84 | 0.8 (n=12) | 4 | 53 of 74 | 19 (49.1 %) | 2.0 (1–3, 7) | 91.0 | 1017 |
| apple-vision · file all/low/all +regions floor 0.100 | 37 | 153 | 46 | 31 | 107 | 60 % [49–70] (n=77) | 30 % [23–38] (n=153) | 0.40 | 30.9 % | 1.0 % / 6.2 % | 0.08 / 0.68 | 0.6 (n=28) | 5 | 43 of 77 | 17 (76.7 %) | 1.0 (1–2, 17) | 88.0 | 555 |
| apple-vision · file all/medium/all +regions regions@1024,2048 floor 0.100 | 37 | 153 | 53 | 50 | 100 | 51 % [42–61] (n=103) | 35 % [28–42] (n=153) | 0.41 | 35.6 % | 1.1 % / 5.9 % | 0.08 / 0.60 | 0.3 (n=31) | 5 | 60 of 103 | 21 (64.6 %) | 2.0 (1–3, 18) | 155.0 | 2178 |
| apple-vision · file all/medium/all -regions · 18af76 | 37 | 153 | 26 | 30 | 127 | 46 % [34–59] (n=56) | 17 % [12–24] (n=153) | 0.25 | 17.4 % | 1.2 % / 5.6 % | 0.08 / 0.69 | 0.5 (n=12) | 3 | 36 of 56 | 18 (68.4 %) | 1.0 (0–2, 7) | 89.0 | 925 |
| apple-vision · file all/medium/all +regions floor 0.100 · 0a949c | 37 | 153 | 72 | 66 | 81 | 52 % [44–60] (n=138) | 47 % [39–55] (n=153) | 0.49 | 48.3 % | 1.1 % / 4.9 % | 0.10 / 0.46 | 0.3 (n=47) | 7 | 76 of 138 | 32 (67.9 %) | 3.0 (1–4, 26) | 155.0 | 2137 |
| apple-vision · file all/medium/all | 37 | 153 | 72 | 66 | 81 | 52 % [44–60] (n=138) | 47 % [39–55] (n=153) | 0.49 | 48.3 % | 1.1 % / 4.9 % | 0.10 / 0.46 | 0.3 (n=47) | 7 | 76 of 138 | 32 (67.9 %) | 3.0 (1–4, 26) | 155.0 | 2272 |
| apple-vision-register · 01e9cab7f08c | 33 | 132 | 25 | 35 | 107 | 42 % [30–54] (n=60) | 19 % [13–26] (n=132) | 0.26 | 19.5 % | 1.2 % / 5.6 % | 0.18 / 1.48 | 1.3 (n=8) | 4 | 43 of 60 | 11 (51.0 %) | 2.0 (1–3, 4) | 2.0 | 0 |
| apple-vision-register · 26f7ceec831c | 33 | 132 | 25 | 35 | 107 | 42 % [30–54] (n=60) | 19 % [13–26] (n=132) | 0.26 | 19.5 % | 1.2 % / 5.6 % | 0.18 / 1.48 | 1.3 (n=8) | 4 | 43 of 60 | 11 (51.0 %) | 2.0 (1–3, 4) | 2.0 | 0 |

Precision and recall are over the labelled assets only; accepted / candidates / runtime are over every asset the run covers. Brackets are Wilson 95 % intervals. Duplicates (a second detection on an already-matched label) count as FP.

### opencv-reference · dedupe 0.7

| primitive | TP | FP | FN | recall |
|---|---|---|---|---|
| ellipse | 24 | 10 | 32 | 43 % [31–56] (n=56) |
| rectangle | 37 | 23 | 60 | 38 % [29–48] (n=97) |

| GT size band | TP | FN | recall |
|---|---|---|---|
| small | 42 | 69 | 38 % [29–47] (n=111) |
| medium | 13 | 18 | 42 % [26–59] (n=31) |
| large | 6 | 5 | 55 % [28–79] (n=11) |

Subclass confusion on matched pairs (rows = ground truth, columns = detector):

| GT \ det | circle | ellipse | square | rectangle |
|---|---|---|---|---|
| circle | 20 | 1 | 0 | 0 |
| ellipse | 1 | 2 | 0 | 0 |
| square | 0 | 0 | 13 | 1 |
| rectangle | 0 | 0 | 0 | 23 |

Centre offset histogram (% of diagonal, 0.25 % bins): 0.00+: 51, 0.25+: 7, 0.50+: 2, 0.75+: 1

Size-floor sweep (accepted shapes per image at alternative floors, from the candidate log — no re-run):

| floor | median | p25–p75 | max |
|---|---|---|---|
| 0.10 | 2.0 | 1–3 | 12 |
| 0.15 | 1.0 | 1–2 | 8 |
| 0.20 | 1.0 | 0–2 | 5 |
| 0.25 | 1.0 | 0–1 | 3 |

### opencv-reference · dedupe 0.9

| primitive | TP | FP | FN | recall |
|---|---|---|---|---|
| ellipse | 27 | 17 | 29 | 48 % [36–61] (n=56) |
| rectangle | 39 | 26 | 58 | 40 % [31–50] (n=97) |

| GT size band | TP | FN | recall |
|---|---|---|---|
| small | 43 | 68 | 39 % [30–48] (n=111) |
| medium | 16 | 15 | 52 % [35–68] (n=31) |
| large | 7 | 4 | 64 % [35–85] (n=11) |

Subclass confusion on matched pairs (rows = ground truth, columns = detector):

| GT \ det | circle | ellipse | square | rectangle |
|---|---|---|---|---|
| circle | 21 | 3 | 0 | 0 |
| ellipse | 1 | 2 | 0 | 0 |
| square | 0 | 0 | 14 | 1 |
| rectangle | 0 | 0 | 0 | 24 |

Centre offset histogram (% of diagonal, 0.25 % bins): 0.00+: 55, 0.25+: 6, 0.50+: 3, 0.75+: 2

Size-floor sweep (accepted shapes per image at alternative floors, from the candidate log — no re-run):

| floor | median | p25–p75 | max |
|---|---|---|---|
| 0.10 | 2.0 | 1–4 | 13 |
| 0.15 | 1.0 | 1–2 | 9 |
| 0.20 | 1.0 | 0–2 | 5 |
| 0.25 | 1.0 | 0–2 | 4 |

### apple-vision · file all/medium/all -regions

| primitive | TP | FP | FN | recall |
|---|---|---|---|---|
| ellipse | 15 | 11 | 41 | 27 % [17–40] (n=56) |
| rectangle | 9 | 12 | 88 | 9 % [5–17] (n=97) |

| GT size band | TP | FN | recall |
|---|---|---|---|
| small | 13 | 98 | 12 % [7–19] (n=111) |
| medium | 9 | 22 | 29 % [16–47] (n=31) |
| large | 2 | 9 | 18 % [5–48] (n=11) |

Subclass confusion on matched pairs (rows = ground truth, columns = detector):

| GT \ det | circle | ellipse | square | rectangle |
|---|---|---|---|---|
| circle | 12 | 1 | 0 | 0 |
| ellipse | 1 | 1 | 0 | 0 |
| square | 0 | 0 | 3 | 0 |
| rectangle | 0 | 0 | 1 | 5 |

Centre offset histogram (% of diagonal, 0.25 % bins): 0.00+: 17, 0.25+: 5, 0.75+: 2

Size-floor sweep (accepted shapes per image at alternative floors, from the candidate log — no re-run):

| floor | median | p25–p75 | max |
|---|---|---|---|
| 0.10 | 1.0 | 1–2 | 7 |
| 0.15 | 1.0 | 1–2 | 7 |
| 0.20 | 1.0 | 1–2 | 4 |
| 0.25 | 1.0 | 0–1 | 3 |

### apple-vision · file all/medium/all +regions

| primitive | TP | FP | FN | recall |
|---|---|---|---|---|
| ellipse | 16 | 11 | 40 | 29 % [18–41] (n=56) |
| rectangle | 17 | 14 | 80 | 18 % [11–26] (n=97) |

| GT size band | TP | FN | recall |
|---|---|---|---|
| small | 18 | 93 | 16 % [11–24] (n=111) |
| medium | 12 | 19 | 39 % [24–56] (n=31) |
| large | 3 | 8 | 27 % [10–57] (n=11) |

Subclass confusion on matched pairs (rows = ground truth, columns = detector):

| GT \ det | circle | ellipse | square | rectangle |
|---|---|---|---|---|
| circle | 13 | 1 | 0 | 0 |
| ellipse | 1 | 1 | 0 | 0 |
| square | 0 | 0 | 4 | 0 |
| rectangle | 0 | 0 | 1 | 12 |

Centre offset histogram (% of diagonal, 0.25 % bins): 0.00+: 23, 0.25+: 6, 0.50+: 1, 0.75+: 3

Size-floor sweep (accepted shapes per image at alternative floors, from the candidate log — no re-run):

| floor | median | p25–p75 | max |
|---|---|---|---|
| 0.10 | 1.5 | 1–3 | 10 |
| 0.15 | 1.5 | 1–3 | 10 |
| 0.20 | 1.0 | 1–2 | 4 |
| 0.25 | 1.0 | 1–1 | 3 |

### apple-vision · file all/medium/all -regions floor 0.100

| primitive | TP | FP | FN | recall |
|---|---|---|---|---|
| ellipse | 24 | 5 | 32 | 43 % [31–56] (n=56) |
| rectangle | 14 | 18 | 83 | 14 % [9–23] (n=97) |

| GT size band | TP | FN | recall |
|---|---|---|---|
| small | 24 | 87 | 22 % [15–30] (n=111) |
| medium | 11 | 20 | 35 % [21–53] (n=31) |
| large | 3 | 8 | 27 % [10–57] (n=11) |

Subclass confusion on matched pairs (rows = ground truth, columns = detector):

| GT \ det | circle | ellipse | square | rectangle |
|---|---|---|---|---|
| circle | 18 | 1 | 0 | 0 |
| ellipse | 4 | 1 | 0 | 0 |
| square | 0 | 0 | 4 | 1 |
| rectangle | 0 | 0 | 2 | 7 |

Centre offset histogram (% of diagonal, 0.25 % bins): 0.00+: 26, 0.25+: 7, 0.50+: 1, 0.75+: 2, 1.00+: 1, 1.50+: 1

Size-floor sweep (accepted shapes per image at alternative floors, from the candidate log — no re-run):

| floor | median | p25–p75 | max |
|---|---|---|---|
| 0.10 | 1.0 | 1–2 | 9 |
| 0.15 | 1.0 | 0–1 | 7 |
| 0.20 | 1.0 | 0–1 | 4 |
| 0.25 | 0.5 | 0–1 | 2 |

### apple-vision · file all/medium/all +regions floor 0.100

| primitive | TP | FP | FN | recall |
|---|---|---|---|---|
| ellipse | 25 | 5 | 31 | 45 % [32–58] (n=56) |
| rectangle | 25 | 28 | 72 | 26 % [18–35] (n=97) |

| GT size band | TP | FN | recall |
|---|---|---|---|
| small | 32 | 79 | 29 % [21–38] (n=111) |
| medium | 14 | 17 | 45 % [29–62] (n=31) |
| large | 4 | 7 | 36 % [15–65] (n=11) |

Subclass confusion on matched pairs (rows = ground truth, columns = detector):

| GT \ det | circle | ellipse | square | rectangle |
|---|---|---|---|---|
| circle | 19 | 1 | 0 | 0 |
| ellipse | 4 | 1 | 0 | 0 |
| square | 0 | 0 | 8 | 1 |
| rectangle | 0 | 0 | 2 | 14 |

Centre offset histogram (% of diagonal, 0.25 % bins): 0.00+: 34, 0.25+: 9, 0.50+: 2, 0.75+: 3, 1.00+: 1, 1.50+: 1

Size-floor sweep (accepted shapes per image at alternative floors, from the candidate log — no re-run):

| floor | median | p25–p75 | max |
|---|---|---|---|
| 0.10 | 2.0 | 1–2 | 17 |
| 0.15 | 1.0 | 0–2 | 10 |
| 0.20 | 1.0 | 0–2 | 4 |
| 0.25 | 1.0 | 0–1 | 2 |

### apple-vision · file all/low/all -regions

| primitive | TP | FP | FN | recall |
|---|---|---|---|---|
| ellipse | 14 | 0 | 42 | 25 % [16–38] (n=56) |
| rectangle | 9 | 12 | 88 | 9 % [5–17] (n=97) |

| GT size band | TP | FN | recall |
|---|---|---|---|
| small | 13 | 98 | 12 % [7–19] (n=111) |
| medium | 8 | 23 | 26 % [14–43] (n=31) |
| large | 2 | 9 | 18 % [5–48] (n=11) |

Subclass confusion on matched pairs (rows = ground truth, columns = detector):

| GT \ det | circle | ellipse | square | rectangle |
|---|---|---|---|---|
| circle | 11 | 1 | 0 | 0 |
| ellipse | 1 | 1 | 0 | 0 |
| square | 0 | 0 | 4 | 0 |
| rectangle | 0 | 0 | 0 | 5 |

Centre offset histogram (% of diagonal, 0.25 % bins): 0.00+: 18, 0.25+: 4, 0.75+: 1

Size-floor sweep (accepted shapes per image at alternative floors, from the candidate log — no re-run):

| floor | median | p25–p75 | max |
|---|---|---|---|
| 0.10 | 1.0 | 1–2 | 7 |
| 0.15 | 1.0 | 1–2 | 7 |
| 0.20 | 1.0 | 1–1 | 4 |
| 0.25 | 1.0 | 0–1 | 2 |

### apple-vision · file all/high/all -regions

| primitive | TP | FP | FN | recall |
|---|---|---|---|---|
| ellipse | 18 | 35 | 38 | 32 % [21–45] (n=56) |
| rectangle | 9 | 12 | 88 | 9 % [5–17] (n=97) |

| GT size band | TP | FN | recall |
|---|---|---|---|
| small | 13 | 98 | 12 % [7–19] (n=111) |
| medium | 11 | 20 | 35 % [21–53] (n=31) |
| large | 3 | 8 | 27 % [10–57] (n=11) |

Subclass confusion on matched pairs (rows = ground truth, columns = detector):

| GT \ det | circle | ellipse | square | rectangle |
|---|---|---|---|---|
| circle | 14 | 1 | 0 | 0 |
| ellipse | 2 | 1 | 0 | 0 |
| square | 0 | 0 | 3 | 0 |
| rectangle | 0 | 0 | 1 | 5 |

Centre offset histogram (% of diagonal, 0.25 % bins): 0.00+: 19, 0.25+: 5, 0.75+: 2, 1.75+: 1

Size-floor sweep (accepted shapes per image at alternative floors, from the candidate log — no re-run):

| floor | median | p25–p75 | max |
|---|---|---|---|
| 0.10 | 2.0 | 1–3 | 7 |
| 0.15 | 2.0 | 1–3 | 7 |
| 0.20 | 1.0 | 1–3 | 4 |
| 0.25 | 1.0 | 0–1 | 3 |

### apple-vision · file all/low/all +regions floor 0.100

| primitive | TP | FP | FN | recall |
|---|---|---|---|---|
| ellipse | 21 | 6 | 35 | 38 % [26–51] (n=56) |
| rectangle | 25 | 25 | 72 | 26 % [18–35] (n=97) |

| GT size band | TP | FN | recall |
|---|---|---|---|
| small | 31 | 80 | 28 % [20–37] (n=111) |
| medium | 12 | 19 | 39 % [24–56] (n=31) |
| large | 3 | 8 | 27 % [10–57] (n=11) |

Subclass confusion on matched pairs (rows = ground truth, columns = detector):

| GT \ det | circle | ellipse | square | rectangle |
|---|---|---|---|---|
| circle | 17 | 1 | 0 | 0 |
| ellipse | 2 | 1 | 0 | 0 |
| square | 0 | 0 | 10 | 1 |
| rectangle | 0 | 0 | 1 | 13 |

Centre offset histogram (% of diagonal, 0.25 % bins): 0.00+: 35, 0.25+: 7, 0.50+: 2, 0.75+: 2

Size-floor sweep (accepted shapes per image at alternative floors, from the candidate log — no re-run):

| floor | median | p25–p75 | max |
|---|---|---|---|
| 0.10 | 1.0 | 1–2 | 17 |
| 0.15 | 1.0 | 1–2 | 10 |
| 0.20 | 1.0 | 0–2 | 4 |
| 0.25 | 1.0 | 0–1 | 2 |

### apple-vision · file all/medium/all +regions regions@1024,2048 floor 0.100

| primitive | TP | FP | FN | recall |
|---|---|---|---|---|
| ellipse | 25 | 10 | 31 | 45 % [32–58] (n=56) |
| rectangle | 28 | 40 | 69 | 29 % [21–39] (n=97) |

| GT size band | TP | FN | recall |
|---|---|---|---|
| small | 35 | 76 | 32 % [24–41] (n=111) |
| medium | 13 | 18 | 42 % [26–59] (n=31) |
| large | 5 | 6 | 45 % [21–72] (n=11) |

Subclass confusion on matched pairs (rows = ground truth, columns = detector):

| GT \ det | circle | ellipse | square | rectangle |
|---|---|---|---|---|
| circle | 21 | 1 | 0 | 0 |
| ellipse | 2 | 1 | 0 | 0 |
| square | 0 | 0 | 10 | 0 |
| rectangle | 0 | 0 | 2 | 16 |

Centre offset histogram (% of diagonal, 0.25 % bins): 0.00+: 39, 0.25+: 9, 0.50+: 4, 0.75+: 1

Size-floor sweep (accepted shapes per image at alternative floors, from the candidate log — no re-run):

| floor | median | p25–p75 | max |
|---|---|---|---|
| 0.10 | 2.0 | 1–3 | 18 |
| 0.15 | 1.0 | 1–3 | 11 |
| 0.20 | 1.0 | 0–2 | 6 |
| 0.25 | 1.0 | 0–1 | 3 |

### apple-vision · file all/medium/all -regions · 18af76

| primitive | TP | FP | FN | recall |
|---|---|---|---|---|
| ellipse | 16 | 18 | 40 | 29 % [18–41] (n=56) |
| rectangle | 10 | 12 | 87 | 10 % [6–18] (n=97) |

| GT size band | TP | FN | recall |
|---|---|---|---|
| small | 14 | 97 | 13 % [8–20] (n=111) |
| medium | 10 | 21 | 32 % [19–50] (n=31) |
| large | 2 | 9 | 18 % [5–48] (n=11) |

Subclass confusion on matched pairs (rows = ground truth, columns = detector):

| GT \ det | circle | ellipse | square | rectangle |
|---|---|---|---|---|
| circle | 13 | 1 | 0 | 0 |
| ellipse | 1 | 1 | 0 | 0 |
| square | 0 | 0 | 4 | 0 |
| rectangle | 0 | 0 | 1 | 5 |

Centre offset histogram (% of diagonal, 0.25 % bins): 0.00+: 19, 0.25+: 5, 0.75+: 2

Size-floor sweep (accepted shapes per image at alternative floors, from the candidate log — no re-run):

| floor | median | p25–p75 | max |
|---|---|---|---|
| 0.10 | 1.0 | 1–2 | 7 |
| 0.15 | 1.0 | 1–2 | 7 |
| 0.20 | 1.0 | 1–2 | 5 |
| 0.25 | 1.0 | 0–2 | 4 |

### apple-vision · file all/medium/all +regions floor 0.100 · 0a949c

| primitive | TP | FP | FN | recall |
|---|---|---|---|---|
| ellipse | 29 | 18 | 27 | 52 % [39–64] (n=56) |
| rectangle | 43 | 48 | 54 | 44 % [35–54] (n=97) |

| GT size band | TP | FN | recall |
|---|---|---|---|
| small | 50 | 61 | 45 % [36–54] (n=111) |
| medium | 15 | 16 | 48 % [32–65] (n=31) |
| large | 7 | 4 | 64 % [35–85] (n=11) |

Subclass confusion on matched pairs (rows = ground truth, columns = detector):

| GT \ det | circle | ellipse | square | rectangle |
|---|---|---|---|---|
| circle | 23 | 2 | 0 | 0 |
| ellipse | 2 | 2 | 0 | 0 |
| square | 0 | 0 | 15 | 1 |
| rectangle | 0 | 0 | 2 | 25 |

Centre offset histogram (% of diagonal, 0.25 % bins): 0.00+: 55, 0.25+: 13, 0.50+: 3, 0.75+: 1

Size-floor sweep (accepted shapes per image at alternative floors, from the candidate log — no re-run):

| floor | median | p25–p75 | max |
|---|---|---|---|
| 0.10 | 3.0 | 1–4 | 26 |
| 0.15 | 2.0 | 1–3 | 17 |
| 0.20 | 1.0 | 0–3 | 7 |
| 0.25 | 1.0 | 0–2 | 4 |

### apple-vision · file all/medium/all

| primitive | TP | FP | FN | recall |
|---|---|---|---|---|
| ellipse | 29 | 18 | 27 | 52 % [39–64] (n=56) |
| rectangle | 43 | 48 | 54 | 44 % [35–54] (n=97) |

| GT size band | TP | FN | recall |
|---|---|---|---|
| small | 50 | 61 | 45 % [36–54] (n=111) |
| medium | 15 | 16 | 48 % [32–65] (n=31) |
| large | 7 | 4 | 64 % [35–85] (n=11) |

Subclass confusion on matched pairs (rows = ground truth, columns = detector):

| GT \ det | circle | ellipse | square | rectangle |
|---|---|---|---|---|
| circle | 23 | 2 | 0 | 0 |
| ellipse | 2 | 2 | 0 | 0 |
| square | 0 | 0 | 15 | 1 |
| rectangle | 0 | 0 | 2 | 25 |

Centre offset histogram (% of diagonal, 0.25 % bins): 0.00+: 55, 0.25+: 13, 0.50+: 3, 0.75+: 1

Size-floor sweep (accepted shapes per image at alternative floors, from the candidate log — no re-run):

| floor | median | p25–p75 | max |
|---|---|---|---|
| 0.10 | 3.0 | 1–4 | 26 |
| 0.15 | 2.0 | 1–3 | 17 |
| 0.20 | 1.0 | 0–3 | 7 |
| 0.25 | 1.0 | 0–2 | 4 |

### apple-vision-register · 01e9cab7f08c

| primitive | TP | FP | FN | recall |
|---|---|---|---|---|
| ellipse | 20 | 30 | 32 | 38 % [26–52] (n=52) |
| rectangle | 5 | 5 | 75 | 6 % [3–14] (n=80) |

| GT size band | TP | FN | recall |
|---|---|---|---|
| small | 11 | 82 | 12 % [7–20] (n=93) |
| medium | 11 | 17 | 39 % [24–58] (n=28) |
| large | 3 | 8 | 27 % [10–57] (n=11) |

Subclass confusion on matched pairs (rows = ground truth, columns = detector):

| GT \ det | circle | ellipse | square | rectangle |
|---|---|---|---|---|
| circle | 16 | 1 | 0 | 0 |
| ellipse | 2 | 1 | 0 | 0 |
| square | 0 | 0 | 3 | 0 |
| rectangle | 0 | 0 | 1 | 1 |

By v1 provenance (`captured` = left standing by the shooter on the viewfinder, `detected` = the file pass / Find shapes):

| source | shapes ≥ floor | TP | FP |
|---|---|---|---|
| captured | 28 | 16 | 12 |
| detected | 32 | 9 | 23 |

Centre offset histogram (% of diagonal, 0.25 % bins): 0.00+: 15, 0.25+: 5, 0.75+: 3, 1.50+: 1, 1.75+: 1

Size-floor sweep (accepted shapes per image at alternative floors, from the candidate log — no re-run):

| floor | median | p25–p75 | max |
|---|---|---|---|
| 0.10 | 2.0 | 1–3 | 4 |
| 0.15 | 2.0 | 1–3 | 4 |
| 0.20 | 2.0 | 1–3 | 4 |
| 0.25 | 1.0 | 1–2 | 3 |

### apple-vision-register · 26f7ceec831c

| primitive | TP | FP | FN | recall |
|---|---|---|---|---|
| ellipse | 20 | 30 | 32 | 38 % [26–52] (n=52) |
| rectangle | 5 | 5 | 75 | 6 % [3–14] (n=80) |

| GT size band | TP | FN | recall |
|---|---|---|---|
| small | 11 | 82 | 12 % [7–20] (n=93) |
| medium | 11 | 17 | 39 % [24–58] (n=28) |
| large | 3 | 8 | 27 % [10–57] (n=11) |

Subclass confusion on matched pairs (rows = ground truth, columns = detector):

| GT \ det | circle | ellipse | square | rectangle |
|---|---|---|---|---|
| circle | 16 | 1 | 0 | 0 |
| ellipse | 2 | 1 | 0 | 0 |
| square | 0 | 0 | 3 | 0 |
| rectangle | 0 | 0 | 1 | 1 |

By v1 provenance (`captured` = left standing by the shooter on the viewfinder, `detected` = the file pass / Find shapes):

| source | shapes ≥ floor | TP | FP |
|---|---|---|---|
| captured | 28 | 16 | 12 |
| detected | 32 | 9 | 23 |

Centre offset histogram (% of diagonal, 0.25 % bins): 0.00+: 15, 0.25+: 5, 0.75+: 3, 1.50+: 1, 1.75+: 1

Size-floor sweep (accepted shapes per image at alternative floors, from the candidate log — no re-run):

| floor | median | p25–p75 | max |
|---|---|---|---|
| 0.10 | 2.0 | 1–3 | 4 |
| 0.15 | 2.0 | 1–3 | 4 |
| 0.20 | 2.0 | 1–3 | 4 |
| 0.25 | 1.0 | 1–2 | 3 |

## Per asset

| asset | name | GT | opencv-reference · dedupe 0.7 TP/FP/FN (acc, cand) | opencv-reference · dedupe 0.9 TP/FP/FN (acc, cand) | apple-vision · file all/medium/all -regions TP/FP/FN (acc, cand) | apple-vision · file all/medium/all +regions TP/FP/FN (acc, cand) | apple-vision · file all/medium/all -regions floor 0.100 TP/FP/FN (acc, cand) | apple-vision · file all/medium/all +regions floor 0.100 TP/FP/FN (acc, cand) | apple-vision · file all/low/all -regions TP/FP/FN (acc, cand) | apple-vision · file all/high/all -regions TP/FP/FN (acc, cand) | apple-vision · file all/low/all +regions floor 0.100 TP/FP/FN (acc, cand) | apple-vision · file all/medium/all +regions regions@1024,2048 floor 0.100 TP/FP/FN (acc, cand) | apple-vision · file all/medium/all -regions · 18af76 TP/FP/FN (acc, cand) | apple-vision · file all/medium/all +regions floor 0.100 · 0a949c TP/FP/FN (acc, cand) | apple-vision · file all/medium/all TP/FP/FN (acc, cand) | apple-vision-register · 01e9cab7f08c TP/FP/FN (acc, cand) | apple-vision-register · 26f7ceec831c TP/FP/FN (acc, cand) |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 017F2704 | 1 photos | 9 | 3/6/6 (9, 415) | 3/6/6 (9, 415) | 2/3/7 (5, 142) | 3/3/6 (6, 142) | 2/3/7 (5, 177) | 3/4/6 (7, 177) | 1/3/8 (4, 77) | 2/3/7 (5, 143) | 2/4/7 (6, 103) | 4/5/5 (9, 179) | 2/3/7 (5, 142) | 6/7/3 (13, 179) | 6/7/3 (13, 179) | 1/0/8 (1, 1) | 1/0/8 (1, 1) |
| 02A0573B | 1 photos | 3 | 1/0/2 (1, 221) | 2/0/1 (2, 221) | 1/0/2 (1, 59) | 1/0/2 (1, 59) | 1/1/2 (2, 166) | 1/1/2 (2, 166) | 1/0/2 (1, 53) | 1/0/2 (1, 59) | 1/0/2 (1, 112) | 1/1/2 (2, 155) | 2/0/1 (2, 59) | 1/1/2 (2, 155) | 1/1/2 (2, 155) | 1/2/2 (3, 4) | 1/2/2 (3, 4) |
| 0BB87681 | 1 photos | 4 | 1/0/3 (1, 21) | 1/0/3 (1, 21) | 1/1/3 (2, 36) | 1/1/3 (2, 36) | 2/1/2 (3, 36) | 2/1/2 (3, 36) | 1/0/3 (1, 24) | 1/2/3 (3, 37) | 0/1/4 (1, 24) | 2/1/2 (3, 38) | 1/2/3 (3, 36) | 2/1/2 (3, 38) | 2/1/2 (3, 38) | 2/2/2 (4, 5) | 2/2/2 (4, 5) |
| 11C2EC0F | 1 photos | 2 | 1/0/1 (1, 278) | 1/0/1 (1, 278) | 0/0/2 (0, 58) | 0/0/2 (0, 58) | 1/0/1 (1, 117) | 1/0/1 (1, 117) | 0/0/2 (0, 50) | 0/1/2 (1, 59) | 1/0/1 (1, 88) | 1/0/1 (1, 118) | 0/0/2 (0, 58) | 1/0/1 (1, 118) | 1/0/1 (1, 118) | — | — |
| 12A65FF8 | 1 photos | 3 | 1/1/2 (2, 375) | 1/1/2 (2, 375) | 0/0/3 (0, 114) | 0/0/3 (0, 114) | 0/1/3 (1, 234) | 0/1/3 (1, 234) | 1/0/2 (1, 67) | 0/1/3 (1, 114) | 1/1/2 (2, 142) | 1/1/2 (2, 241) | 1/0/2 (1, 114) | 2/1/1 (3, 241) | 2/1/1 (3, 241) | 0/0/3 (0, 3) | 0/0/3 (0, 3) |
| 142503DF | 1 photos | 1 | 1/1/0 (2, 236) | 1/1/0 (2, 236) | 1/0/0 (1, 99) | 1/0/0 (1, 99) | 1/0/0 (1, 148) | 1/0/0 (1, 148) | 1/0/0 (1, 64) | 1/0/0 (1, 100) | 1/0/0 (1, 89) | 1/0/0 (1, 143) | 1/0/0 (1, 99) | 1/0/0 (1, 143) | 1/0/0 (1, 143) | 1/0/0 (1, 5) | 1/0/0 (1, 5) |
| 19F20A05 | 1 photos | 3 | 2/0/1 (2, 182) | 2/1/1 (3, 182) | 2/0/1 (2, 94) | 2/0/1 (2, 94) | 2/0/1 (2, 134) | 2/0/1 (2, 134) | 2/0/1 (2, 58) | 2/0/1 (2, 97) | 2/0/1 (2, 68) | 2/1/1 (3, 132) | 2/1/1 (3, 94) | 2/2/1 (4, 132) | 2/2/1 (4, 132) | 2/0/1 (2, 2) | 2/0/1 (2, 2) |
| 2306FD1B | 1 photos | 2 | 2/0/0 (2, 87) | 2/0/0 (2, 87) | 1/0/1 (1, 48) | 1/0/1 (1, 48) | 1/0/1 (1, 75) | 1/0/1 (1, 75) | 0/0/2 (0, 31) | 1/1/1 (2, 48) | 1/0/1 (1, 38) | 1/0/1 (1, 77) | 1/0/1 (1, 48) | 1/0/1 (1, 77) | 1/0/1 (1, 77) | 1/1/1 (2, 2) | 1/1/1 (2, 2) |
| 48F0E90D | 1 photos | 1 | 1/0/0 (1, 278) | 1/0/0 (1, 278) | 1/0/0 (1, 162) | 1/0/0 (1, 162) | 1/0/0 (1, 190) | 1/0/0 (1, 190) | 1/0/0 (1, 75) | 1/3/0 (4, 163) | 1/0/0 (1, 93) | 1/0/0 (1, 196) | 1/0/0 (1, 162) | 1/0/0 (1, 196) | 1/0/0 (1, 196) | 1/1/0 (2, 2) | 1/1/0 (2, 2) |
| 4C493B9A | 1 photos | 3 | 2/1/1 (3, 184) | 2/2/1 (4, 184) | 0/1/3 (1, 94) | 1/2/2 (3, 94) | 0/1/3 (1, 123) | 1/2/2 (3, 123) | 0/1/3 (1, 71) | 0/2/3 (2, 95) | 1/2/2 (3, 89) | 1/3/2 (4, 121) | 0/1/3 (1, 94) | 2/3/1 (5, 121) | 2/3/1 (5, 121) | 0/2/3 (2, 2) | 0/2/3 (2, 2) |
| 50E24192 | 1 photos | 2 | 1/0/1 (1, 206) | 1/0/1 (1, 206) | 0/0/2 (0, 81) | 0/0/2 (0, 81) | 1/0/1 (1, 113) | 1/0/1 (1, 113) | 0/0/2 (0, 50) | 0/0/2 (0, 81) | 1/0/1 (1, 65) | 1/0/1 (1, 108) | 0/0/2 (0, 81) | 2/1/0 (3, 108) | 2/1/0 (3, 108) | 1/0/1 (1, 1) | 1/0/1 (1, 1) |
| 51208197 | 1 photos | 2 | 1/0/1 (1, 31) | 1/1/1 (2, 31) | 0/0/2 (0, 51) | 0/0/2 (0, 51) | 1/0/1 (1, 58) | 1/0/1 (1, 58) | 0/0/2 (0, 35) | 0/0/2 (0, 51) | 1/0/1 (1, 42) | 1/0/1 (1, 57) | 0/0/2 (0, 51) | 1/0/1 (1, 57) | 1/0/1 (1, 57) | 0/0/2 (0, 2) | 0/0/2 (0, 2) |
| 5CEC7AA7 | 1 photos | 5 | 1/1/4 (2, 137) | 1/1/4 (2, 137) | 1/0/4 (1, 54) | 1/0/4 (1, 54) | 1/0/4 (1, 94) | 1/0/4 (1, 94) | 1/0/4 (1, 42) | 1/1/4 (2, 54) | 1/0/4 (1, 73) | 1/0/4 (1, 91) | 1/0/4 (1, 54) | 1/0/4 (1, 91) | 1/0/4 (1, 91) | 1/0/4 (1, 2) | 1/0/4 (1, 2) |
| 5D452591 | 1 photos | 4 | 2/1/2 (3, 320) | 3/1/1 (4, 320) | 1/1/3 (2, 114) | 1/1/3 (2, 114) | 1/1/3 (2, 191) | 1/1/3 (2, 191) | 1/1/3 (2, 60) | 1/2/3 (3, 116) | 1/1/3 (2, 84) | 2/1/2 (3, 190) | 1/1/3 (2, 114) | 2/2/2 (4, 190) | 2/2/2 (4, 190) | 1/3/3 (4, 5) | 1/3/3 (4, 5) |
| 5DF429BD | 1 photos | 2 | 1/2/1 (3, 237) | 1/3/1 (4, 237) | 0/1/2 (1, 109) | 0/1/2 (1, 109) | 0/0/2 (0, 179) | 0/0/2 (0, 179) | 0/0/2 (0, 70) | 0/3/2 (3, 109) | 0/0/2 (0, 101) | 1/2/1 (3, 173) | 0/1/2 (1, 109) | 1/2/1 (3, 173) | 1/2/1 (3, 173) | 0/2/2 (2, 2) | 0/2/2 (2, 2) |
| 606B29B0 | 1 photos | 11 | 3/0/8 (3, 419) | 3/0/8 (3, 419) | 0/0/11 (0, 113) | 0/0/11 (0, 113) | 2/0/9 (2, 201) | 3/0/8 (3, 201) | 1/0/10 (1, 66) | 0/1/11 (1, 115) | 3/0/8 (3, 105) | 3/0/8 (3, 225) | 0/0/11 (0, 113) | 3/0/8 (3, 225) | 3/0/8 (3, 225) | 0/0/11 (0, 3) | 0/0/11 (0, 3) |
| 60FC1F35 | 1 photos | 1 | 0/1/1 (1, 172) | 0/1/1 (1, 172) | 0/1/1 (1, 86) | 0/1/1 (1, 86) | 1/0/0 (1, 155) | 1/0/0 (1, 155) | 0/0/1 (0, 52) | 0/1/1 (1, 86) | 0/2/1 (2, 74) | 0/3/1 (3, 164) | 0/2/1 (2, 86) | 0/3/1 (3, 164) | 0/3/1 (3, 164) | 0/1/1 (1, 1) | 0/1/1 (1, 1) |
| 6426B50C | 1 photos | 2 | 0/0/2 (0, 192) | 0/0/2 (0, 192) | 0/0/2 (0, 65) | 0/0/2 (0, 65) | 0/1/2 (1, 133) | 0/1/2 (1, 133) | 0/0/2 (0, 47) | 0/3/2 (3, 66) | 0/0/2 (0, 85) | 0/1/2 (1, 133) | 0/0/2 (0, 65) | 0/1/2 (1, 133) | 0/1/2 (1, 133) | 0/3/2 (3, 3) | 0/3/2 (3, 3) |
| 69200198 | 1 photos | 0 | 0/0/0 (0, 216) | 0/0/0 (0, 216) | 0/0/0 (0, 89) | 0/0/0 (0, 89) | 0/0/0 (0, 139) | 0/0/0 (0, 139) | 0/0/0 (0, 59) | 0/1/0 (1, 91) | 0/0/0 (0, 91) | 0/0/0 (0, 144) | 0/0/0 (0, 89) | 0/0/0 (0, 144) | 0/0/0 (0, 144) | — | — |
| 7746D41B | 1 photos | 2 | 2/2/0 (4, 296) | 2/2/0 (4, 296) | 1/0/1 (1, 146) | 1/0/1 (1, 146) | 1/1/1 (2, 259) | 1/1/1 (2, 259) | 1/0/1 (1, 82) | 1/0/1 (1, 146) | 1/0/1 (1, 135) | 1/2/1 (3, 262) | 1/0/1 (1, 146) | 2/2/0 (4, 262) | 2/2/0 (4, 262) | 1/0/1 (1, 3) | 1/0/1 (1, 3) |
| 947A57FC | 1 photos | 10 | 2/0/8 (2, 203) | 2/0/8 (2, 203) | 3/2/7 (5, 186) | 3/2/7 (5, 186) | 3/2/7 (5, 267) | 3/2/7 (5, 267) | 3/2/7 (5, 104) | 3/2/7 (5, 186) | 3/2/7 (5, 156) | 4/3/6 (7, 262) | 3/3/7 (6, 186) | 4/3/6 (7, 262) | 4/3/6 (7, 262) | 3/1/7 (4, 8) | 3/1/7 (4, 8) |
| 96752BAC | 1 photos | 10 | 1/2/9 (3, 309) | 1/2/9 (3, 309) | 0/3/10 (3, 112) | 0/3/10 (3, 112) | 1/0/9 (1, 252) | 1/0/9 (1, 252) | 0/0/10 (0, 56) | 1/2/9 (3, 113) | 0/1/10 (1, 115) | 1/1/9 (2, 276) | 0/4/10 (4, 112) | 1/1/9 (2, 276) | 1/1/9 (2, 276) | 1/2/9 (3, 3) | 1/2/9 (3, 3) |
| 9A458778 | 1 photos | 0 | 0/0/0 (0, 362) | 0/0/0 (0, 362) | 0/1/0 (1, 101) | 0/1/0 (1, 101) | 0/1/0 (1, 234) | 0/1/0 (1, 234) | 0/0/0 (0, 57) | 0/2/0 (2, 101) | 0/0/0 (0, 108) | 0/1/0 (1, 233) | 0/1/0 (1, 101) | 0/1/0 (1, 233) | 0/1/0 (1, 233) | 0/2/0 (2, 2) | 0/2/0 (2, 2) |
| 9D619859 | 1 photos | 6 | 3/0/3 (3, 446) | 4/0/2 (4, 446) | 0/0/6 (0, 116) | 0/0/6 (0, 116) | 1/1/5 (2, 224) | 1/1/5 (2, 224) | 0/0/6 (0, 60) | 0/3/6 (3, 116) | 2/0/4 (2, 95) | 1/1/5 (2, 232) | 0/0/6 (0, 116) | 2/1/4 (3, 232) | 2/1/4 (3, 232) | 0/4/6 (4, 5) | 0/4/6 (4, 5) |
| A3B93008 | 1 photos | 1 | 1/0/0 (1, 54) | 1/0/0 (1, 54) | 0/0/1 (0, 30) | 0/0/1 (0, 30) | 1/0/0 (1, 33) | 1/0/0 (1, 33) | 0/0/1 (0, 21) | 0/0/1 (0, 30) | 1/0/0 (1, 22) | 1/0/0 (1, 32) | 0/0/1 (0, 30) | 1/0/0 (1, 32) | 1/0/0 (1, 32) | 0/0/1 (0, 0) | 0/0/1 (0, 0) |
| A7F2AB82 | 1 photos | 2 | 2/1/0 (3, 62) | 2/1/0 (3, 62) | 2/0/0 (2, 60) | 2/0/0 (2, 60) | 2/0/0 (2, 160) | 2/0/0 (2, 160) | 2/0/0 (2, 49) | 2/1/0 (3, 60) | 2/0/0 (2, 109) | 2/0/0 (2, 162) | 2/1/0 (3, 60) | 2/1/0 (3, 162) | 2/1/0 (3, 162) | 2/2/0 (4, 9) | 2/2/0 (4, 9) |
| B46433F9 | 1 photos | 5 | 0/0/5 (0, 226) | 0/0/5 (0, 226) | 0/0/5 (0, 97) | 0/0/5 (0, 97) | 0/0/5 (0, 169) | 0/0/5 (0, 169) | 0/0/5 (0, 53) | 0/0/5 (0, 97) | 0/0/5 (0, 83) | 0/0/5 (0, 176) | 0/0/5 (0, 97) | 0/0/5 (0, 176) | 0/0/5 (0, 176) | 0/0/5 (0, 4) | 0/0/5 (0, 4) |
| B848CA9E | 1 photos | 13 | 8/4/5 (12, 474) | 8/5/5 (13, 474) | 3/4/10 (7, 162) | 6/4/7 (10, 162) | 3/6/10 (9, 220) | 6/11/7 (17, 220) | 3/4/10 (7, 95) | 3/4/10 (7, 163) | 6/11/7 (17, 129) | 6/12/7 (18, 213) | 3/4/10 (7, 162) | 11/15/2 (26, 213) | 11/15/2 (26, 213) | — | — |
| C71D3F3B | 1 photos | 10 | 5/0/5 (5, 237) | 5/0/5 (5, 237) | 1/0/9 (1, 89) | 3/0/7 (3, 89) | 1/0/9 (1, 164) | 3/0/7 (3, 164) | 1/0/9 (1, 62) | 1/1/9 (2, 91) | 3/0/7 (3, 88) | 3/1/7 (4, 176) | 1/0/9 (1, 89) | 4/2/6 (6, 176) | 4/2/6 (6, 176) | 1/2/9 (3, 6) | 1/2/9 (3, 6) |
| CB1B6B0A | 1 photos | 1 | 0/1/1 (1, 168) | 0/1/1 (1, 168) | 1/0/0 (1, 65) | 1/1/0 (2, 65) | 1/0/0 (1, 89) | 1/1/0 (2, 89) | 0/0/1 (0, 41) | 1/0/0 (1, 65) | 0/1/1 (1, 54) | 1/2/0 (3, 81) | 1/0/0 (1, 65) | 1/3/0 (4, 81) | 1/3/0 (4, 81) | 1/1/0 (2, 3) | 1/1/0 (2, 3) |
| D877F2BD | 1 photos | 2 | 1/1/1 (2, 66) | 1/2/1 (3, 66) | 1/0/1 (1, 31) | 1/0/1 (1, 31) | 1/1/1 (2, 33) | 1/1/1 (2, 33) | 1/0/1 (1, 26) | 1/0/1 (1, 32) | 1/1/1 (2, 28) | 1/1/1 (2, 32) | 1/1/1 (2, 31) | 1/3/1 (4, 32) | 1/3/1 (4, 32) | 1/0/1 (1, 1) | 1/0/1 (1, 1) |
| DD08E911 | 1 photos | 17 | 3/3/14 (6, 336) | 4/3/13 (7, 336) | 0/1/17 (1, 91) | 1/1/16 (2, 91) | 4/0/13 (4, 457) | 7/1/10 (8, 457) | 0/0/17 (0, 83) | 1/2/16 (3, 91) | 7/1/10 (8, 222) | 4/2/13 (6, 440) | 0/1/17 (1, 91) | 6/2/11 (8, 440) | 6/2/11 (8, 440) | 1/2/16 (3, 3) | 1/2/16 (3, 3) |
| E0556DD6 | 1 photos | 2 | 1/2/1 (3, 234) | 1/3/1 (4, 234) | 0/0/2 (0, 139) | 0/0/2 (0, 139) | 0/1/2 (1, 220) | 0/1/2 (1, 220) | 0/0/2 (0, 77) | 1/0/1 (1, 139) | 0/1/2 (1, 113) | 1/1/1 (2, 220) | 0/0/2 (0, 139) | 1/2/1 (3, 220) | 1/2/1 (3, 220) | 1/0/1 (1, 1) | 1/0/1 (1, 1) |
| E05D7E04 | 1 photos | 2 | 1/2/1 (3, 104) | 2/2/0 (4, 104) | 1/0/1 (1, 45) | 1/0/1 (1, 45) | 1/0/1 (1, 45) | 1/1/1 (2, 45) | 1/0/1 (1, 32) | 1/0/1 (1, 45) | 1/1/1 (2, 32) | 1/2/1 (3, 47) | 1/0/1 (1, 45) | 2/2/0 (4, 47) | 2/2/0 (4, 47) | 1/0/1 (1, 2) | 1/0/1 (1, 2) |
| E3470B75 | 1 photos | 3 | 1/0/2 (1, 92) | 1/0/2 (1, 92) | 0/1/3 (1, 39) | 0/1/3 (1, 39) | 0/1/3 (1, 62) | 0/1/3 (1, 62) | 0/1/3 (1, 31) | 0/1/3 (1, 39) | 0/1/3 (1, 43) | 1/1/2 (2, 63) | 0/1/3 (1, 39) | 2/1/1 (3, 63) | 2/1/1 (3, 63) | 0/0/3 (0, 0) | 0/0/3 (0, 0) |
| F7EC5F46 | 1 photos | 6 | 5/1/1 (6, 127) | 5/4/1 (9, 127) | 0/2/6 (2, 83) | 1/2/5 (3, 83) | 0/0/6 (0, 106) | 1/0/5 (1, 106) | 0/0/6 (0, 48) | 0/2/6 (2, 85) | 1/0/5 (1, 60) | 1/0/5 (1, 104) | 0/2/6 (2, 83) | 3/2/3 (5, 104) | 3/2/3 (5, 104) | — | — |
| FC1137ED | 1 photos | 1 | 1/0/0 (1, 19) | 1/0/0 (1, 19) | 0/1/1 (1, 34) | 0/1/1 (1, 34) | 0/0/1 (0, 42) | 0/0/1 (0, 42) | 0/0/1 (0, 24) | 0/2/1 (2, 34) | 0/0/1 (0, 32) | 0/1/1 (1, 38) | 0/1/1 (1, 34) | 0/1/1 (1, 38) | 0/1/1 (1, 38) | 0/2/1 (2, 2) | 0/2/1 (2, 2) |
