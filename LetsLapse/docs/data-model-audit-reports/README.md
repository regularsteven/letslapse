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
