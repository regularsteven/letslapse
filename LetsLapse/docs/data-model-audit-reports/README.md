# `lapse audit` reports

Saved output of `lapse audit <root>` (Phase 1 W1), kept as the before/after
check for every data-model work item. Re-run with:

```bash
LetsLapse/Kit/.build/release/lapse audit /Volumes/letslapse            # text
LetsLapse/Kit/.build/release/lapse audit /Volumes/letslapse --json     # machine form
```

| File | Root | Taken | Notes |
|---|---|---|---|
| `mac-before-2026-09-13.{txt,json}` | `/Volumes/letslapse` | 2026-09-13, before any Phase 1 change | reproduces Part 1 Appendix A: 3 orphan folders, 1 record over an empty folder, 7 unlisted renders, 77 `.json` names |
| `mac-after-m1-2026-09-13.txt` | `/Volumes/letslapse` | 2026-09-13, after Milestone 1 (W1 + W5 + metadata import) | byte-identical to the before report except `library.json` one byte smaller (a running app's own persist between the two runs); the real library was not touched — M1 was verified on a scratch root. Hash coverage on this volume rises once a build with the backfill runs against it. |
| `mac-after-m2-2026-09-13.txt` | `/Volumes/letslapse` | 2026-09-13, after Milestone 2 (W2–W12) | still the before report's numbers (one-byte `library.json` difference from a running app's persist): no build with the v4 migration or the backfill has been launched against this volume yet — the first one that is will stamp origins, drop the 77 `.json` names and start hashing; run the audit again then. Both milestones were verified on scratch roots and a copy of this manifest. |
