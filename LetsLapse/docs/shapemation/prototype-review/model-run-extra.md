### What the viewer sees: the rendered path's jump Σ|P(i+1) − P(i)| (the board shows Σ J on the natural positions instead) — portrait 83 → 4:5, one pass
| rule | rejected | Σ J (board) | rendered Σ ΔP | largest single step | size-curve breaks |
|---|---|---|---|---|---|
| smallest · w3 | 22 | 3.08 | 2.23 | 0.114 | 20 |
| smallest · w5 | 22 | 3.13 | 1.05 | 0.088 | 23 |
| smallest · w7 | 25 | 3.00 | 0.92 | 0.063 | 22 |
| alignment K3 · w5 | 13 | 3.19 | 2.01 | 0.122 | 25 |
| capture order · w5 | 18 | 3.05 | 1.50 | 0.143 | 32 |

### A size-aware path: target = p + (P − p)·(1 − σ)^γ — the face is pulled to the path only while it is small (γ = 0 is the prototype as built)
| rect | γ | rejected | of which s ≥ 50 % | amber | red kept | mean f | mean L | rendered Σ ΔP | largest step |
|---|---|---|---|---|---|---|---|---|---|
| 4:5 | 0 | 22 of 83 | 6 | 26 | 2 | 13.2 % | 18.6 % | 1.05 | 0.088 |
| 4:5 | 0.5 | 13 of 83 | 1 | 25 | 0 | 11.5 % | 17.0 % | 2.36 | 0.117 |
| 4:5 | 1 | 7 of 83 | 1 | 22 | 0 | 9.9 % | 15.5 % | 3.72 | 0.180 |
| 4:5 | 2 | 4 of 83 | 1 | 15 | 0 | 7.3 % | 13.1 % | 5.67 | 0.249 |
| 3:4 | 0 | 28 of 83 | 8 | 25 | 5 | 16.8 % | 16.8 % | 0.80 | 0.062 |
| 3:4 | 0.5 | 18 of 83 | 2 | 27 | 2 | 14.3 % | 14.3 % | 2.08 | 0.114 |
| 3:4 | 1 | 11 of 83 | 1 | 28 | 1 | 12.7 % | 12.7 % | 3.33 | 0.172 |
| 3:4 | 2 | 4 of 83 | 1 | 18 | 1 | 9.8 % | 9.8 % | 5.50 | 0.238 |
| 9:16 | 0 | 13 of 83 | 4 | 24 | 1 | 11.0 % | 33.2 % | 1.81 | 0.092 |
| 9:16 | 0.5 | 7 of 83 | 0 | 18 | 0 | 8.4 % | 31.3 % | 4.38 | 0.299 |
| 9:16 | 1 | 3 of 83 | 0 | 12 | 0 | 6.8 % | 30.1 % | 6.25 | 0.431 |
| 9:16 | 2 | 0 of 83 | 0 | 7 | 0 | 4.2 % | 28.1 % | 9.35 | 0.524 |

4:5 · γ = 1 keeps AA1E1BE8 (s 24.5 %), F5A24C51 (s 25.3 %), 1F9A89E9 (s 31.2 %), 903F2042 (s 32.5 %), 41AA1ED4 (s 36.2 %), A22695D2 (s 38.7 %), FD4A2922 (s 39.8 %), 5FC8BC17 (s 41.5 %), 9462125C (s 43.6 %), CE897A15 (s 49.9 %), F3DEC7D7 (s 51.7 %), 5D617A53 (s 60.5 %), A5DB12C4 (s 61.2 %), 940EAC89 (s 75.6 %), A37159A5 (s 76.5 %) that γ = 0 rejected; newly rejected: none

At 4:5 the kept path sits at x ≈ 0.53; the 22 rejects' faces are 0.05–0.33 of the frame width off it horizontally (a same-aspect photo pays z = 1.2 → f 30 % at roughly ±0.08).
