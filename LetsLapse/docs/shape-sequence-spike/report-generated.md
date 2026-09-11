# Shape Sequence spike — report

Generated 2026-09-10T16:41:43Z from `/Volumes/letslapse/Projects`.

## Verdict

172 shoots scanned (17 skipped). 60 of 172 (35%) carry at least one accepted anchor — 6 ellipses, 58 quads.

- **Ellipses:** largest viable group is 6 items (ellipse · all); 0 of them need more than 2.00× upscale.
- **Quads:** largest viable group is 30 items (quad · all); 0 of them need more than 2.00× upscale.

Whether the aligned result *reads* as a held shape is a judgement for the proof clips in `clips/`; the numbers below say what the catalogue contains, not how it looks. The human review verdict is appended in the docs copy of this report.

## Inventory

| | count |
|---|---|
| shoots with a representative image | 172 |
| · still | 93 |
| · interval | 79 |
| · representative from blendImage | 10 |
| · representative from blendVideo | 38 |
| · representative from renderedFrame | 18 |
| · representative from rawDecode | 106 |
| unlisted folders used | 2 |
| skipped: no-representative | 1 |
| skipped: video-source | 16 |

## Detection

Settings: detection long edge 1024 px; min native diameter max(400 px, short edge ÷ 6); ellipse residual ≤ 0.03, coverage ≥ 0.70, minor/major ≥ 0.25; contours at contrast 1.0/2.0/3.0 × dark-on-light/light-on-dark; rectangles conf ≥ 0.6, aspect ≥ 0.3, quadrature 30°.

| | ellipse | quad |
|---|---|---|
| assets with ≥1 accepted anchor | 6 | 58 |
| accepted anchors (before one-per-asset) | 6 | 92 |
| candidates recorded | 8267 | 261 |

Detector failures: 0.
Detection time per asset: median 2375 ms, max 28852 ms (includes the representative decode).

### Rejection breakdown

**ellipse** — 8261 rejected (plus contours dropped by the bounding-box prefilter before fitting: see `anchors.json` perAsset.candidates; total candidates reaching a record 8528):

| reason | count |
|---|---|
| residual | 7392 |
| polygonal | 856 |
| duplicate | 13 |

**quad** — 169 rejected:

| reason | count |
|---|---|
| too-small | 165 |
| duplicate | 4 |

Reason glossary: `too-few-points` contour under 24 points; `polygonal` ≤6 vertices after polygon approximation; `fit-failed` no ellipse solution; `open` end points further apart than 5% of the major axis; `residual` mean radial error over 3% of the axis; `coverage` contour spans under 70% of the fitted circumference (arcs); `obliquity` minor/major under 0.25; `too-small` native diameter under the resolution gate; `image-border` the frame itself; `centre-outside` fit centre off-image; `duplicate` heavy overlap with a better-fitting accepted shape.

### Accepted anchors per asset

| asset | source | native | kind | ⌀ native px | obliquity | conf |
|---|---|---|---|---|---|---|
| 06BC719B | rawDecode | 4032×3024 | quad | 1196 | 0.30 | 1.00 |
| 09B487A2 | rawDecode | 4032×3024 | quad | 512 | 0.93 | 1.00 |
| 0B0109D4 | rawDecode | 4032×3024 | quad | 624 | 0.64 | 1.00 |
| 129FEDB6 | rawDecode | 3024×4032 | quad | 903 | 0.95 | 1.00 |
| 12C7C72B | renderedFrame | 3024×4032 | quad | 511 | 0.80 | 1.00 |
| 139F2266 | blendVideo | 3024×4032 | quad | 710 | 0.92 | 1.00 |
| 15BCA175 | rawDecode | 3024×4032 | quad | 540 | 0.81 | 1.00 |
| 18E4571A | rawDecode | 3024×4032 | quad | 922 | 0.54 | 1.00 |
| 1F8DB0DA | rawDecode | 3024×4032 | quad | 686 | 0.89 | 1.00 |
| 21C0B322 | rawDecode | 3024×4032 | quad | 853 | 0.63 | 1.00 |
| 225E61C2 | renderedFrame | 3024×4032 | quad | 554 | 0.91 | 1.00 |
| 22C60834 | blendImage | 3024×4032 | quad | 508 | 0.76 | 1.00 |
| 245E5288 | rawDecode | 3024×4032 | quad | 1004 | 0.66 | 1.00 |
| 25FB849B | rawDecode | 3024×4032 | quad | 660 | 0.73 | 1.00 |
| 27A53544 | renderedFrame | 3024×4032 | quad | 516 | 0.89 | 1.00 |
| 27D19BD7 | rawDecode | 3024×4032 | quad | 1105 | 0.64 | 1.00 |
| 2ACEA94A | rawDecode | 3024×4032 | quad | 1220 | 0.96 | 1.00 |
| 36E1B1C2 | rawDecode | 3024×4032 | quad | 1398 | 0.85 | 1.00 |
| 3F70171F | rawDecode | 3024×4032 | ellipse | 1385 | 0.99 | 0.80 |
| 41EADF93 | rawDecode | 3024×4032 | ellipse | 1245 | 0.95 | 0.58 |
| 44BFC44E | blendVideo | 3024×4032 | quad | 829 | 0.93 | 1.00 |
| 5A9D30B2 | renderedFrame | 3024×4032 | quad | 531 | 0.80 | 1.00 |
| 5BD07D71 | rawDecode | 4032×3024 | quad | 623 | 0.72 | 1.00 |
| 5CEC7AA7 | rawDecode | 3024×4032 | ellipse | 879 | 1.00 | 0.96 |
| 5CEC7AA7 | rawDecode | 3024×4032 | quad | 880 | 0.49 | 1.00 |
| 5EDE6DB9 | blendVideo | 3024×4032 | quad | 525 | 0.95 | 1.00 |
| 6989C559 | rawDecode | 3024×4032 | quad | 1243 | 0.59 | 1.00 |
| 6B6F5BD4 | rawDecode | 4032×3024 | quad | 582 | 0.63 | 1.00 |
| 73C04388 | rawDecode | 3024×4032 | quad | 688 | 0.78 | 1.00 |
| 76BEF654 | blendImage | 4032×3024 | quad | 544 | 0.94 | 1.00 |
| 79D5C4B5 | rawDecode | 3024×4032 | quad | 772 | 0.77 | 1.00 |
| 7F542709 | rawDecode | 3024×4032 | quad | 1258 | 0.93 | 1.00 |
| 83B04C59 | rawDecode | 3024×4032 | quad | 754 | 0.82 | 1.00 |
| 8898B1D5 | rawDecode | 3024×4032 | ellipse | 519 | 0.94 | 0.74 |
| 8898B1D5 | rawDecode | 3024×4032 | quad | 574 | 0.74 | 1.00 |
| 8946C76A | rawDecode | 3024×4032 | quad | 781 | 0.95 | 1.00 |
| 951CDE1D | rawDecode | 4032×3024 | quad | 755 | 0.93 | 1.00 |
| 98C4542D | blendVideo | 3024×4032 | quad | 760 | 0.92 | 1.00 |
| A317E25F | rawDecode | 3024×4032 | quad | 731 | 0.89 | 1.00 |
| A36ABA6D | rawDecode | 4032×3024 | quad | 704 | 0.72 | 1.00 |
| A3B93008 | rawDecode | 3024×4032 | quad | 1379 | 0.81 | 1.00 |
| A55DF0EE | blendImage | 4032×3024 | quad | 562 | 0.73 | 1.00 |
| AA26B0D1 | rawDecode | 4032×3024 | quad | 898 | 0.65 | 1.00 |
| AB4E88AA | rawDecode | 4032×3024 | quad | 654 | 0.88 | 1.00 |
| AD75877D | rawDecode | 3024×4032 | quad | 519 | 0.97 | 1.00 |
| B36623B0 | rawDecode | 3024×4032 | quad | 574 | 0.84 | 1.00 |
| B4F5B092 | rawDecode | 4000×6000 | quad | 2561 | 1.00 | 1.00 |
| B83BDB9F | rawDecode | 3024×4032 | quad | 613 | 0.68 | 1.00 |
| B91FD599 | blendVideo | 3872×2580 | quad | 487 | 0.88 | 1.00 |
| B97F567B | rawDecode | 3024×4032 | quad | 701 | 0.92 | 1.00 |
| BA785B13 | rawDecode | 3024×4032 | quad | 951 | 0.73 | 1.00 |
| BFB1B44A | rawDecode | 4032×3024 | ellipse | 530 | 0.99 | 0.85 |
| BFB1B44A | rawDecode | 4032×3024 | quad | 786 | 0.95 | 1.00 |
| C0CF0E47 | rawDecode | 4032×3024 | quad | 602 | 0.85 | 1.00 |
| C864BBD7 | rawDecode | 3024×4032 | ellipse | 534 | 0.84 | 0.12 |
| C864BBD7 | rawDecode | 3024×4032 | quad | 916 | 0.93 | 1.00 |
| CB861BE8 | rawDecode | 4032×3024 | quad | 793 | 0.80 | 1.00 |
| D0EAFE2C | rawDecode | 3024×4032 | quad | 505 | 0.72 | 1.00 |
| E05D7E04 | rawDecode | 3024×4032 | quad | 1546 | 0.99 | 1.00 |
| E33ED216 | blendVideo | 4032×3024 | quad | 582 | 0.71 | 1.00 |
| E7BAADC0 | rawDecode | 4032×3024 | quad | 868 | 0.55 | 1.00 |
| E9D52934 | blendVideo | 4032×3024 | quad | 932 | 0.41 | 1.00 |
| EF1EECB8 | rawDecode | 4032×3024 | quad | 529 | 0.55 | 1.00 |
| F9F5F3C0 | rawDecode | 3024×4032 | quad | 530 | 0.84 | 1.00 |

## Groups

Target: major axis = 40% of 1080 px frame height (432 px). Minimum group 4, cap 30. Scale factor = output px per native px; over 2.00× is flagged.

| # | group | n | scale min / median / max | > 2.00× | edge-excluded centred / aligned | note |
|---|---|---|---|---|---|---|
| 1 | ellipse · all | 6 | 0.31 / 0.65 / 0.83 | 0 | 3 / 3 |  |
| 2 | ellipse · head-on | 5 | 0.31 / 0.49 / 0.83 | 0 | 3 / 3 |  |
| 3 | quad · all | 30 | 0.28 / 0.68 / 0.89 | 0 | 23 / 28 | truncated from 58; median w/h 1.09 |
| 4 | quad · wide | 26 | 0.17 / 0.57 / 0.85 | 0 | 22 / 26 | median w/h 1.75 |
| 5 | quad · wide · head-on | 10 | 0.17 / 0.60 / 0.84 | 0 | 8 / 10 | median w/h 1.85 |
| 6 | quad · wide · moderate | 14 | 0.31 / 0.59 / 0.85 | 0 | 12 / 14 | median w/h 1.84 |
| 7 | quad · square | 13 | 0.31 / 0.75 / 0.85 | 0 | 10 / 12 | median w/h 1.01 |
| 8 | quad · square · head-on | 6 | 0.35 / 0.58 / 0.83 | 0 | 6 / 6 | median w/h 0.95 |
| 9 | quad · square · moderate | 7 | 0.31 / 0.75 / 0.85 | 0 | 4 / 6 | median w/h 1.08 |
| 10 | quad · tall | 19 | 0.36 / 0.62 / 0.89 | 0 | 17 / 18 | median w/h 0.49 |
| 11 | quad · tall · head-on | 7 | 0.47 / 0.59 / 0.89 | 0 | 6 / 7 | median w/h 0.42 |
| 12 | quad · tall · moderate | 11 | 0.39 / 0.69 / 0.77 | 0 | 10 / 11 | median w/h 0.63 |

### Group 1: ellipse · all

| order | asset | captured | ⌀ native | scale | obliquity | cover centred | cover aligned |
|---|---|---|---|---|---|---|---|
| 1 | 8898B1D5 | 2026-09-09 09:26 | 519 | 0.83 | 0.94 | 100% | 100% |
| 2 | 3F70171F | 2026-09-09 09:46 | 1385 | 0.31 | 0.99 | 54% | 54% |
| 3 | BFB1B44A | 2026-09-09 10:07 | 530 | 0.81 | 0.99 | 100% | 100% |
| 4 | C864BBD7 | 2026-09-09 10:14 | 534 | 0.81 | 0.84 | 100% | 100% |
| 5 | 5CEC7AA7 | 2026-09-09 17:15 | 879 | 0.49 | 1.00 | 88% | 88% |
| 6 | 41EADF93 | 2026-09-09 20:18 | 1245 | 0.35 | 0.95 | 70% | 72% |

### Group 2: ellipse · head-on

| order | asset | captured | ⌀ native | scale | obliquity | cover centred | cover aligned |
|---|---|---|---|---|---|---|---|
| 1 | 8898B1D5 | 2026-09-09 09:26 | 519 | 0.83 | 0.94 | 100% | 100% |
| 2 | 3F70171F | 2026-09-09 09:46 | 1385 | 0.31 | 0.99 | 54% | 54% |
| 3 | BFB1B44A | 2026-09-09 10:07 | 530 | 0.81 | 0.99 | 100% | 100% |
| 4 | 5CEC7AA7 | 2026-09-09 17:15 | 879 | 0.49 | 1.00 | 88% | 88% |
| 5 | 41EADF93 | 2026-09-09 20:18 | 1245 | 0.35 | 0.95 | 70% | 72% |

### Group 3: quad · all

| order | asset | captured | ⌀ native | scale | obliquity | cover centred | cover aligned |
|---|---|---|---|---|---|---|---|
| 1 | 22C60834 | 2026-07-29 15:22 | 508 | 0.85 | 0.76 | 96% | 0% |
| 2 | AB4E88AA | 2026-08-21 06:30 | 654 | 0.66 | 0.88 | 63% | 0% |
| 3 | 0B0109D4 | 2026-08-22 18:13 | 624 | 0.69 | 0.64 | 100% | 0% |
| 4 | 06BC719B | 2026-08-22 20:30 | 1196 | 0.36 | 0.30 | 44% | 0% |
| 5 | 44BFC44E | 2026-08-23 07:45 | 829 | 0.52 | 0.93 | 62% | 89% |
| 6 | 5EDE6DB9 | 2026-08-25 20:35 | 525 | 0.82 | 0.95 | 100% | 99% |
| 7 | E33ED216 | 2026-08-31 20:48 | 582 | 0.74 | 0.71 | 95% | 0% |
| 8 | B91FD599 | 2026-09-04 20:30 | 487 | 0.89 | 0.88 | 100% | 100% |
| 9 | 12C7C72B | 2026-09-06 18:40 | 511 | 0.84 | 0.80 | 100% | 0% |
| 10 | 5A9D30B2 | 2026-09-08 18:48 | 531 | 0.81 | 0.80 | 100% | 0% |
| 11 | 8946C76A | 2026-09-09 08:38 | 781 | 0.55 | 0.95 | 64% | 73% |
| 12 | 6B6F5BD4 | 2026-09-09 08:42 | 582 | 0.74 | 0.63 | 95% | 0% |
| 13 | E7BAADC0 | 2026-09-09 08:43 | 868 | 0.50 | 0.55 | 78% | 0% |
| 14 | 8898B1D5 | 2026-09-09 09:26 | 574 | 0.75 | 0.74 | 100% | 0% |
| 15 | B36623B0 | 2026-09-09 09:29 | 574 | 0.75 | 0.84 | 100% | 100% |
| 16 | A317E25F | 2026-09-09 09:33 | 731 | 0.59 | 0.89 | 93% | 96% |
| 17 | D0EAFE2C | 2026-09-09 09:56 | 505 | 0.85 | 0.72 | 72% | 0% |
| 18 | B83BDB9F | 2026-09-09 09:57 | 613 | 0.70 | 0.68 | 99% | 0% |
| 19 | 36E1B1C2 | 2026-09-09 10:04 | 1398 | 0.31 | 0.85 | 48% | 48% |
| 20 | BFB1B44A | 2026-09-09 10:07 | 786 | 0.55 | 0.95 | 77% | 88% |
| 21 | 245E5288 | 2026-09-09 10:10 | 1004 | 0.43 | 0.66 | 51% | 0% |
| 22 | 129FEDB6 | 2026-09-09 10:11 | 903 | 0.48 | 0.95 | 75% | 98% |
| 23 | 73C04388 | 2026-09-09 11:18 | 688 | 0.63 | 0.78 | 63% | 0% |
| 24 | C0CF0E47 | 2026-09-09 12:24 | 602 | 0.72 | 0.85 | 62% | 65% |
| 25 | 09B487A2 | 2026-09-09 12:25 | 512 | 0.84 | 0.93 | 63% | 84% |
| 26 | EF1EECB8 | 2026-09-09 12:27 | 529 | 0.82 | 0.55 | 73% | 78% |
| 27 | A36ABA6D | 2026-09-09 16:24 | 704 | 0.61 | 0.72 | 63% | 60% |
| 28 | 21C0B322 | 2026-09-09 16:56 | 853 | 0.51 | 0.63 | 57% | 0% |
| 29 | E05D7E04 | 2026-09-09 17:16 | 1546 | 0.28 | 0.99 | 41% | 40% |
| 30 | A3B93008 | 2026-09-09 20:13 | 1379 | 0.31 | 0.81 | 50% | 52% |

### Group 4: quad · wide

| order | asset | captured | ⌀ native | scale | obliquity | cover centred | cover aligned |
|---|---|---|---|---|---|---|---|
| 1 | B4F5B092 | 2021-10-15 14:07 | 2561 | 0.17 | 1.00 | 29% | 28% |
| 2 | 22C60834 | 2026-07-29 15:22 | 508 | 0.85 | 0.76 | 96% | 0% |
| 3 | 98C4542D | 2026-08-23 07:09 | 760 | 0.57 | 0.92 | 63% | 76% |
| 4 | 27A53544 | 2026-08-23 08:04 | 516 | 0.84 | 0.89 | 67% | 66% |
| 5 | E9D52934 | 2026-08-23 17:02 | 932 | 0.46 | 0.41 | 69% | 0% |
| 6 | 5EDE6DB9 | 2026-08-25 20:35 | 525 | 0.82 | 0.95 | 100% | 99% |
| 7 | 76BEF654 | 2026-08-31 19:24 | 544 | 0.79 | 0.94 | 63% | 63% |
| 8 | E33ED216 | 2026-08-31 20:48 | 582 | 0.74 | 0.71 | 95% | 0% |
| 9 | 12C7C72B | 2026-09-06 18:40 | 511 | 0.84 | 0.80 | 100% | 0% |
| 10 | 951CDE1D | 2026-09-09 08:42 | 755 | 0.57 | 0.93 | 100% | 92% |
| 11 | BA785B13 | 2026-09-09 09:19 | 951 | 0.45 | 0.73 | 72% | 0% |
| 12 | 6989C559 | 2026-09-09 09:20 | 1243 | 0.35 | 0.59 | 56% | 64% |
| 13 | F9F5F3C0 | 2026-09-09 09:25 | 530 | 0.81 | 0.84 | 100% | 96% |
| 14 | 7F542709 | 2026-09-09 09:26 | 1258 | 0.34 | 0.93 | 44% | 52% |
| 15 | 1F8DB0DA | 2026-09-09 09:38 | 686 | 0.63 | 0.89 | 88% | 89% |
| 16 | 245E5288 | 2026-09-09 10:10 | 1004 | 0.43 | 0.66 | 51% | 0% |
| 17 | 73C04388 | 2026-09-09 11:18 | 688 | 0.63 | 0.78 | 63% | 0% |
| 18 | 79D5C4B5 | 2026-09-09 11:19 | 772 | 0.56 | 0.77 | 63% | 56% |
| 19 | 09B487A2 | 2026-09-09 12:25 | 512 | 0.84 | 0.93 | 63% | 70% |
| 20 | EF1EECB8 | 2026-09-09 12:27 | 529 | 0.82 | 0.55 | 73% | 75% |
| 21 | A36ABA6D | 2026-09-09 16:24 | 704 | 0.61 | 0.72 | 63% | 57% |
| 22 | 21C0B322 | 2026-09-09 16:56 | 853 | 0.51 | 0.63 | 57% | 0% |
| 23 | 5CEC7AA7 | 2026-09-09 17:15 | 880 | 0.49 | 0.49 | 77% | 0% |
| 24 | E05D7E04 | 2026-09-09 17:16 | 1546 | 0.28 | 0.99 | 41% | 27% |
| 25 | A3B93008 | 2026-09-09 20:13 | 1379 | 0.31 | 0.81 | 50% | 43% |
| 26 | 18E4571A | 2026-09-10 08:21 | 922 | 0.47 | 0.54 | 65% | 0% |

### Group 5: quad · wide · head-on

| order | asset | captured | ⌀ native | scale | obliquity | cover centred | cover aligned |
|---|---|---|---|---|---|---|---|
| 1 | B4F5B092 | 2021-10-15 14:07 | 2561 | 0.17 | 1.00 | 29% | 27% |
| 2 | 98C4542D | 2026-08-23 07:09 | 760 | 0.57 | 0.92 | 63% | 74% |
| 3 | 27A53544 | 2026-08-23 08:04 | 516 | 0.84 | 0.89 | 67% | 66% |
| 4 | 5EDE6DB9 | 2026-08-25 20:35 | 525 | 0.82 | 0.95 | 100% | 99% |
| 5 | 76BEF654 | 2026-08-31 19:24 | 544 | 0.79 | 0.94 | 63% | 63% |
| 6 | 951CDE1D | 2026-09-09 08:42 | 755 | 0.57 | 0.93 | 100% | 92% |
| 7 | 7F542709 | 2026-09-09 09:26 | 1258 | 0.34 | 0.93 | 44% | 51% |
| 8 | 1F8DB0DA | 2026-09-09 09:38 | 686 | 0.63 | 0.89 | 88% | 89% |
| 9 | 09B487A2 | 2026-09-09 12:25 | 512 | 0.84 | 0.93 | 63% | 68% |
| 10 | E05D7E04 | 2026-09-09 17:16 | 1546 | 0.28 | 0.99 | 41% | 25% |

### Group 6: quad · wide · moderate

| order | asset | captured | ⌀ native | scale | obliquity | cover centred | cover aligned |
|---|---|---|---|---|---|---|---|
| 1 | 22C60834 | 2026-07-29 15:22 | 508 | 0.85 | 0.76 | 96% | 0% |
| 2 | E33ED216 | 2026-08-31 20:48 | 582 | 0.74 | 0.71 | 95% | 0% |
| 3 | 12C7C72B | 2026-09-06 18:40 | 511 | 0.84 | 0.80 | 100% | 0% |
| 4 | BA785B13 | 2026-09-09 09:19 | 951 | 0.45 | 0.73 | 72% | 0% |
| 5 | 6989C559 | 2026-09-09 09:20 | 1243 | 0.35 | 0.59 | 56% | 64% |
| 6 | F9F5F3C0 | 2026-09-09 09:25 | 530 | 0.81 | 0.84 | 100% | 96% |
| 7 | 245E5288 | 2026-09-09 10:10 | 1004 | 0.43 | 0.66 | 51% | 0% |
| 8 | 73C04388 | 2026-09-09 11:18 | 688 | 0.63 | 0.78 | 63% | 0% |
| 9 | 79D5C4B5 | 2026-09-09 11:19 | 772 | 0.56 | 0.77 | 63% | 55% |
| 10 | EF1EECB8 | 2026-09-09 12:27 | 529 | 0.82 | 0.55 | 73% | 75% |
| 11 | A36ABA6D | 2026-09-09 16:24 | 704 | 0.61 | 0.72 | 63% | 57% |
| 12 | 21C0B322 | 2026-09-09 16:56 | 853 | 0.51 | 0.63 | 57% | 0% |
| 13 | A3B93008 | 2026-09-09 20:13 | 1379 | 0.31 | 0.81 | 50% | 42% |
| 14 | 18E4571A | 2026-09-10 08:21 | 922 | 0.47 | 0.54 | 65% | 0% |

### Group 7: quad · square

| order | asset | captured | ⌀ native | scale | obliquity | cover centred | cover aligned |
|---|---|---|---|---|---|---|---|
| 1 | 225E61C2 | 2026-08-23 07:44 | 554 | 0.78 | 0.91 | 81% | 81% |
| 2 | 139F2266 | 2026-08-23 21:39 | 710 | 0.61 | 0.92 | 78% | 98% |
| 3 | 5A9D30B2 | 2026-09-08 18:48 | 531 | 0.81 | 0.80 | 100% | 0% |
| 4 | 8946C76A | 2026-09-09 08:38 | 781 | 0.55 | 0.95 | 64% | 75% |
| 5 | E7BAADC0 | 2026-09-09 08:43 | 868 | 0.50 | 0.55 | 78% | 0% |
| 6 | 8898B1D5 | 2026-09-09 09:26 | 574 | 0.75 | 0.74 | 100% | 0% |
| 7 | B36623B0 | 2026-09-09 09:29 | 574 | 0.75 | 0.84 | 100% | 100% |
| 8 | AD75877D | 2026-09-09 09:32 | 519 | 0.83 | 0.97 | 64% | 68% |
| 9 | 15BCA175 | 2026-09-09 09:50 | 540 | 0.80 | 0.81 | 95% | 0% |
| 10 | D0EAFE2C | 2026-09-09 09:56 | 505 | 0.85 | 0.72 | 72% | 0% |
| 11 | 36E1B1C2 | 2026-09-09 10:04 | 1398 | 0.31 | 0.85 | 48% | 50% |
| 12 | 2ACEA94A | 2026-09-09 10:10 | 1220 | 0.35 | 0.96 | 56% | 72% |
| 13 | 129FEDB6 | 2026-09-09 10:11 | 903 | 0.48 | 0.95 | 75% | 98% |

### Group 8: quad · square · head-on

| order | asset | captured | ⌀ native | scale | obliquity | cover centred | cover aligned |
|---|---|---|---|---|---|---|---|
| 1 | 225E61C2 | 2026-08-23 07:44 | 554 | 0.78 | 0.91 | 81% | 82% |
| 2 | 139F2266 | 2026-08-23 21:39 | 710 | 0.61 | 0.92 | 78% | 96% |
| 3 | 8946C76A | 2026-09-09 08:38 | 781 | 0.55 | 0.95 | 64% | 74% |
| 4 | AD75877D | 2026-09-09 09:32 | 519 | 0.83 | 0.97 | 64% | 67% |
| 5 | 2ACEA94A | 2026-09-09 10:10 | 1220 | 0.35 | 0.96 | 56% | 69% |
| 6 | 129FEDB6 | 2026-09-09 10:11 | 903 | 0.48 | 0.95 | 75% | 95% |

### Group 9: quad · square · moderate

| order | asset | captured | ⌀ native | scale | obliquity | cover centred | cover aligned |
|---|---|---|---|---|---|---|---|
| 1 | 5A9D30B2 | 2026-09-08 18:48 | 531 | 0.81 | 0.80 | 100% | 0% |
| 2 | E7BAADC0 | 2026-09-09 08:43 | 868 | 0.50 | 0.55 | 78% | 0% |
| 3 | 8898B1D5 | 2026-09-09 09:26 | 574 | 0.75 | 0.74 | 100% | 0% |
| 4 | B36623B0 | 2026-09-09 09:29 | 574 | 0.75 | 0.84 | 100% | 100% |
| 5 | 15BCA175 | 2026-09-09 09:50 | 540 | 0.80 | 0.81 | 95% | 0% |
| 6 | D0EAFE2C | 2026-09-09 09:56 | 505 | 0.85 | 0.72 | 72% | 0% |
| 7 | 36E1B1C2 | 2026-09-09 10:04 | 1398 | 0.31 | 0.85 | 48% | 48% |

### Group 10: quad · tall

| order | asset | captured | ⌀ native | scale | obliquity | cover centred | cover aligned |
|---|---|---|---|---|---|---|---|
| 1 | AB4E88AA | 2026-08-21 06:30 | 654 | 0.66 | 0.88 | 63% | 0% |
| 2 | 5BD07D71 | 2026-08-21 06:37 | 623 | 0.69 | 0.72 | 59% | 0% |
| 3 | 0B0109D4 | 2026-08-22 18:13 | 624 | 0.69 | 0.64 | 100% | 0% |
| 4 | CB861BE8 | 2026-08-22 20:04 | 793 | 0.54 | 0.80 | 50% | 47% |
| 5 | 06BC719B | 2026-08-22 20:30 | 1196 | 0.36 | 0.30 | 44% | 0% |
| 6 | 44BFC44E | 2026-08-23 07:45 | 829 | 0.52 | 0.93 | 62% | 70% |
| 7 | B91FD599 | 2026-09-04 20:30 | 487 | 0.89 | 0.88 | 100% | 90% |
| 8 | A55DF0EE | 2026-09-04 20:46 | 562 | 0.77 | 0.73 | 92% | 0% |
| 9 | 27D19BD7 | 2026-09-09 08:38 | 1105 | 0.39 | 0.64 | 62% | 71% |
| 10 | 6B6F5BD4 | 2026-09-09 08:42 | 582 | 0.74 | 0.63 | 95% | 0% |
| 11 | B97F567B | 2026-09-09 09:27 | 701 | 0.62 | 0.92 | 94% | 100% |
| 12 | 25FB849B | 2026-09-09 09:30 | 660 | 0.65 | 0.73 | 64% | 0% |
| 13 | A317E25F | 2026-09-09 09:33 | 731 | 0.59 | 0.89 | 93% | 77% |
| 14 | 83B04C59 | 2026-09-09 09:34 | 754 | 0.57 | 0.82 | 51% | 0% |
| 15 | B83BDB9F | 2026-09-09 09:57 | 613 | 0.70 | 0.68 | 99% | 0% |
| 16 | BFB1B44A | 2026-09-09 10:07 | 786 | 0.55 | 0.95 | 77% | 77% |
| 17 | C864BBD7 | 2026-09-09 10:14 | 916 | 0.47 | 0.93 | 74% | 74% |
| 18 | C0CF0E47 | 2026-09-09 12:24 | 602 | 0.72 | 0.85 | 62% | 57% |
| 19 | AA26B0D1 | 2026-09-09 16:57 | 898 | 0.48 | 0.65 | 55% | 0% |

### Group 11: quad · tall · head-on

| order | asset | captured | ⌀ native | scale | obliquity | cover centred | cover aligned |
|---|---|---|---|---|---|---|---|
| 1 | AB4E88AA | 2026-08-21 06:30 | 654 | 0.66 | 0.88 | 63% | 0% |
| 2 | 44BFC44E | 2026-08-23 07:45 | 829 | 0.52 | 0.93 | 62% | 67% |
| 3 | B91FD599 | 2026-09-04 20:30 | 487 | 0.89 | 0.88 | 100% | 84% |
| 4 | B97F567B | 2026-09-09 09:27 | 701 | 0.62 | 0.92 | 94% | 98% |
| 5 | A317E25F | 2026-09-09 09:33 | 731 | 0.59 | 0.89 | 93% | 66% |
| 6 | BFB1B44A | 2026-09-09 10:07 | 786 | 0.55 | 0.95 | 77% | 72% |
| 7 | C864BBD7 | 2026-09-09 10:14 | 916 | 0.47 | 0.93 | 74% | 62% |

### Group 12: quad · tall · moderate

| order | asset | captured | ⌀ native | scale | obliquity | cover centred | cover aligned |
|---|---|---|---|---|---|---|---|
| 1 | 5BD07D71 | 2026-08-21 06:37 | 623 | 0.69 | 0.72 | 59% | 0% |
| 2 | 0B0109D4 | 2026-08-22 18:13 | 624 | 0.69 | 0.64 | 100% | 0% |
| 3 | CB861BE8 | 2026-08-22 20:04 | 793 | 0.54 | 0.80 | 50% | 50% |
| 4 | A55DF0EE | 2026-09-04 20:46 | 562 | 0.77 | 0.73 | 92% | 0% |
| 5 | 27D19BD7 | 2026-09-09 08:38 | 1105 | 0.39 | 0.64 | 62% | 80% |
| 6 | 6B6F5BD4 | 2026-09-09 08:42 | 582 | 0.74 | 0.63 | 95% | 0% |
| 7 | 25FB849B | 2026-09-09 09:30 | 660 | 0.65 | 0.73 | 64% | 0% |
| 8 | 83B04C59 | 2026-09-09 09:34 | 754 | 0.57 | 0.82 | 51% | 0% |
| 9 | B83BDB9F | 2026-09-09 09:57 | 613 | 0.70 | 0.68 | 99% | 0% |
| 10 | C0CF0E47 | 2026-09-09 12:24 | 602 | 0.72 | 0.85 | 62% | 60% |
| 11 | AA26B0D1 | 2026-09-09 16:57 | 898 | 0.48 | 0.65 | 55% | 0% |

## Proof clips

1920×1080 H.264 30 fps unless the pass says otherwise, hard cuts, no blending; caption per frame = asset · native ⌀ · scale · obliquity · variant.

### Render pass: edge policy `letterbox`, rotation `none`, tag `letterbox-norot`

| clip | group | variant | order | items in / out | seconds |
|---|---|---|---|---|---|
| group-01-centred-letterbox-norot.mov | 1 | centred | chrono | 6 / 0 | 6 |
| group-01-aligned-letterbox-norot.mov | 1 | aligned | chrono | 6 / 0 | 6 |
| group-01-centred-sizeorder-letterbox-norot.mov | 1 | centred | size | 6 / 0 | 6 |
| group-02-centred-letterbox-norot.mov | 2 | centred | chrono | 5 / 0 | 5 |
| group-02-aligned-letterbox-norot.mov | 2 | aligned | chrono | 5 / 0 | 5 |
| group-03-centred-letterbox-norot.mov | 3 | centred | chrono | 30 / 0 | 30 |
| group-03-aligned-letterbox-norot.mov | 3 | aligned | chrono | 30 / 0 | 30 |
| group-03-centred-sizeorder-letterbox-norot.mov | 3 | centred | size | 30 / 0 | 30 |
| group-04-centred-letterbox-norot.mov | 4 | centred | chrono | 26 / 0 | 26 |
| group-04-aligned-letterbox-norot.mov | 4 | aligned | chrono | 26 / 0 | 26 |
| group-05-centred-letterbox-norot.mov | 5 | centred | chrono | 10 / 0 | 10 |
| group-05-aligned-letterbox-norot.mov | 5 | aligned | chrono | 10 / 0 | 10 |
| group-06-centred-letterbox-norot.mov | 6 | centred | chrono | 14 / 0 | 14 |
| group-06-aligned-letterbox-norot.mov | 6 | aligned | chrono | 14 / 0 | 14 |
| group-07-centred-letterbox-norot.mov | 7 | centred | chrono | 13 / 0 | 13 |
| group-07-aligned-letterbox-norot.mov | 7 | aligned | chrono | 13 / 0 | 13 |
| group-08-centred-letterbox-norot.mov | 8 | centred | chrono | 6 / 0 | 6 |
| group-08-aligned-letterbox-norot.mov | 8 | aligned | chrono | 6 / 0 | 6 |
| group-09-centred-letterbox-norot.mov | 9 | centred | chrono | 7 / 0 | 7 |
| group-09-aligned-letterbox-norot.mov | 9 | aligned | chrono | 7 / 0 | 7 |
| group-10-centred-letterbox-norot.mov | 10 | centred | chrono | 19 / 0 | 19 |
| group-10-aligned-letterbox-norot.mov | 10 | aligned | chrono | 19 / 0 | 19 |
| group-11-centred-letterbox-norot.mov | 11 | centred | chrono | 7 / 0 | 7 |
| group-11-aligned-letterbox-norot.mov | 11 | aligned | chrono | 7 / 0 | 7 |
| group-12-centred-letterbox-norot.mov | 12 | centred | chrono | 11 / 0 | 11 |
| group-12-aligned-letterbox-norot.mov | 12 | aligned | chrono | 11 / 0 | 11 |

Items excluded by the edge policy or errors: 0.

### Render pass: edge policy `exclude`, rotation `major`

| clip | group | variant | order | items in / out | seconds |
|---|---|---|---|---|---|
| group-01-centred.mov | 1 | centred | chrono | 3 / 3 | 3 |
| group-01-aligned.mov | 1 | aligned | chrono | 3 / 3 | 3 |
| group-01-centred-sizeorder.mov | 1 | centred | size | 3 / 3 | 3 |
| group-02-centred.mov | 2 | centred | chrono | 2 / 3 | 2 |
| group-02-aligned.mov | 2 | aligned | chrono | 2 / 3 | 2 |
| group-03-centred.mov | 3 | centred | chrono | 7 / 23 | 7 |
| group-03-aligned.mov | 3 | aligned | chrono | 2 / 28 | 2 |
| group-03-centred-sizeorder.mov | 3 | centred | size | 7 / 23 | 7 |
| group-04-centred.mov | 4 | centred | chrono | 4 / 22 | 4 |
| group-04-aligned.mov | 4 | aligned | chrono | 0 / 26 | 0 |
| group-05-centred.mov | 5 | centred | chrono | 2 / 8 | 2 |
| group-05-aligned.mov | 5 | aligned | chrono | 0 / 10 | 0 |
| group-06-centred.mov | 6 | centred | chrono | 2 / 12 | 2 |
| group-06-aligned.mov | 6 | aligned | chrono | 0 / 14 | 0 |
| group-07-centred.mov | 7 | centred | chrono | 3 / 10 | 3 |
| group-07-aligned.mov | 7 | aligned | chrono | 1 / 12 | 1 |
| group-08-centred.mov | 8 | centred | chrono | 0 / 6 | 0 |
| group-08-aligned.mov | 8 | aligned | chrono | 0 / 6 | 0 |
| group-09-centred.mov | 9 | centred | chrono | 3 / 4 | 3 |
| group-09-aligned.mov | 9 | aligned | chrono | 1 / 6 | 1 |
| group-10-centred.mov | 10 | centred | chrono | 2 / 17 | 2 |
| group-10-aligned.mov | 10 | aligned | chrono | 1 / 18 | 1 |
| group-11-centred.mov | 11 | centred | chrono | 1 / 6 | 1 |
| group-11-aligned.mov | 11 | aligned | chrono | 0 / 7 | 0 |
| group-12-centred.mov | 12 | centred | chrono | 1 / 10 | 1 |
| group-12-aligned.mov | 12 | aligned | chrono | 0 / 11 | 0 |

Items excluded by the edge policy or errors: 294.
Distinct assets excluded: 59; shortfall range 1%–100% of the frame.

## Method notes

- One representative image per shoot: rendered blend (image, or the mid frame of a blend clip) → rendered source frame (middle of the run) → RAW decode as a last resort (logged per asset).
- Ellipses: Vision contours (6 passes) → polygon-approximation reject → direct least-squares conic fit (Halir–Flusser) → gates. Quads: `VNDetectRectanglesRequest`.
- Un-skew (aligned variant): ellipses get the affine stretch that maps the fitted ellipse onto a circle (no camera intrinsics assumed); quads get the full homography onto a rectangle of the group's median width/height, which also levels them.
- Rotation: ellipses rotate their major axis to horizontal (`--rotation major`, the brief's rule) or keep the world upright (`--rotation none`); quads always level their top edge rather than laying a doorway on its side.
- Coverage = fraction of the output frame that receives source pixels under the item's transform; the default edge policy excludes anything under 99.5%.
