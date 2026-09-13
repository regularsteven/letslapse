# `lapse audit` reports

Saved output of `lapse audit <root>` (Phase 1 W1), kept as the before/after
check for every data-model work item. Re-run with:

```bash
LetsLapse/Kit/.build/release/lapse audit /Volumes/letslapse            # text
LetsLapse/Kit/.build/release/lapse audit /Volumes/letslapse --json     # machine form
LetsLapse/Kit/.build/release/lapse audit /Volumes/letslapse --rebuild-index   # Phase 2: the manifest rebuilt from every project.json, diffed (must be IDENTICAL)
LetsLapse/Kit/.build/release/lapse index /Volumes/letslapse --verify          # Phase 3: the SQLite index against the documents
```

| File | Root | Taken | Notes |
|---|---|---|---|
| `mac-before-2026-09-13.{txt,json}` | `/Volumes/letslapse` | 2026-09-13, before any Phase 1 change | reproduces Part 1 Appendix A: 3 orphan folders, 1 record over an empty folder, 7 unlisted renders, 77 `.json` names |
| `mac-after-m1-2026-09-13.txt` | `/Volumes/letslapse` | 2026-09-13, after Milestone 1 (W1 + W5 + metadata import) | byte-identical to the before report except `library.json` one byte smaller (a running app's own persist between the two runs); the real library was not touched — M1 was verified on a scratch root. Hash coverage on this volume rises once a build with the backfill runs against it. |
| `mac-after-m2-2026-09-13.txt` | `/Volumes/letslapse` | 2026-09-13, after Milestone 2 (W2–W12) | still the before report's numbers (one-byte `library.json` difference from a running app's persist): no build with the v4 migration or the backfill has been launched against this volume yet — the first one that is will stamp origins, drop the 77 `.json` names and start hashing; run the audit again then. Both milestones were verified on scratch roots and a copy of this manifest. |
| `mac-after-backfill-2026-09-13.txt` | `/Volumes/letslapse` | 2026-09-13 09:33, after Steven's first launches of the Phase 1 build against the volume | schema 4; `.json` names 77 → 0; `originID` 258 of 258 (257 distinct — one project imported twice); hash coverage **100 %** (56,489 assets, 427.7 GB, 257 projects with `assets.ndjson`, 56,310 records with metadata); the same 3 orphan folders and 1 empty-folder record as before — the Phase 4 build will register the orphans as "Recovered" projects at its first launch, to be kept or trashed; `project.json` 0 (no Phase 2 build has run here yet). Read-only run. |
