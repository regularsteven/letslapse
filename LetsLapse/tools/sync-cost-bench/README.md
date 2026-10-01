# PicPlace sync-cost bench

What a library costs to sync, step by step, as a data pack: import photos on
the Mac, edit a few, import `.lapse` projects, edit a few, let the Simulator
pull it all, edit a few there, and see what the Mac then has to fetch. Every
API request and storage transfer is counted by name; the report is written to
`docs/fieldtests/<date>-sync-cost-bench/README.md` with the raw logs beside it.
Run it once as the baseline, then again after each of the agreed sync-cost
jobs (`docs/TODO.md`, "PicPlace sync cost"): it is the before/after.

## What you need

- **Builds with the trace.** The Mac Debug app at
  `~/Library/Developer/LetsLapseRun/dd-mac/Build/Products/Debug/LetsLapse.app`
  (`python3 .claude/skills/run-letslapse/driver.py build mac`) and the
  Simulator Debug app in `dd-sim` (`driver.py build sim --device <udid>`;
  `--install-sim` on the run installs it). Both must include
  `LL_PICPLACE_TRACE` (2026-09-30 or later). The trace is `#if DEBUG`.
- **The synth pair.** Mac library `~/Pictures/LetsLapse/synth`, bound to
  `@synth` on `picplace.test`; Simulator "LetsLapse Fresh"
  (`C8F8FCC2-5DBC-4B87-B7FE-06D1085C7996`), signed in as synth with its one
  library bound to the same server library. Nothing else should be on that
  account while a run is measured.
- **picplace.test up, with storage.** The preflight asks `/status` (expects
  `401`) and the Garage endpoint (expects `403`); a TCP probe is not enough,
  Docker's forwarder accepts and then breaks the pipe (2026-09-30).
- **Steven's own LetsLapse quit**, or at least not on the synth library: a
  second instance on the same library opens read-only and the bench stops at
  once. Pass `--force` only when the other copy is on another library.
- A **personal-access token** for synth. The bench mints one through
  `php artisan tinker` in `~/Sites/picplace` (client `letslapse-bench`) unless
  `--token` is given. It goes in as `LL_PICPLACE_TOKENS`, so the Mac copy never
  reads the Keychain (the SecurityAgent prompt trap).

## Running it

    python3 LetsLapse/tools/sync-cost-bench/bench.py plan --photos <dir> --lapse <dir>
    python3 LetsLapse/tools/sync-cost-bench/bench.py run  --photos <dir> --lapse <dir> --install-sim

`--photos` and `--lapse` take files or folders (folders are walked). Options:
`--edits 3` (how many projects each edit step touches), `--presets`, `--sim-edit
download|preview`, `--steps a,b,c` (a subset), `--quiet 45` (seconds of log
silence that end a step), `--step-timeout 1800`, `--out`, `--mac-root`,
`--sim`, `--device-id` (run a scratch copy of a library as its own device).

The steps, each one launch of the app with the hooks that do its work,
settled until the log has been quiet for `--quiet` seconds, then quit:

| Step | Device | Hooks | What it measures |
|---|---|---|---|
| `mac-baseline` | Mac | `LL_TAB=projects` | a launch and one check |
| `mac-import-photos` | Mac | `LL_IMPORT_STILLS=<a>:<b>…`, `LL_IMPORT_ANSWER=photos` | N photos as separate projects: the push queue, then the originals queue |
| `mac-edit-photos` | Mac | `LL_APPLY_PRESET=<origin>:Cinema@2;<origin>:Matte@4;…` | an edit-only push, three projects in one queue run |
| `mac-import-lapse` | Mac | `LL_IMPORT_ARCHIVE=<a.lapse>:<b.lapse>…` | archives: bundles, blends, many-frame negotiates |
| `mac-edit-lapse` | Mac | `LL_APPLY_PRESET=…` | the same on imported projects |
| `sim-pull` | Simulator | `LL_TAB=gallery` | the first pull of every new project's preview; settles when the pulled count matches |
| `sim-download` | Simulator | `LL_PICPLACE_DOWNLOAD=<o1>,<o2>,<o3>` | the originals of three photos NOT edited on the Mac, as the editor's just-in-time prompt would fetch them (`--sim-edit download`) |
| `sim-edit` | Simulator | `LL_APPLY_PRESET=…` | the second device's edit: poster and records back up |
| `mac-after` | Mac | `LL_TAB=projects` | what the Simulator's edits cost the Mac (the re-pull) |

Projects are addressed by **origin id** on both devices: `LL_APPLY_PRESET`
and `LL_PICPLACE_DOWNLOAD` accept a project's own id or its origin.

With `--sim-edit preview` the download step is skipped and the preset is
written over the preview alone. The push then sends records without a new
poster (a preview-only project's "source" is its poster), which is itself
a finding worth seeing once.

## The two-library scenario

    python3 LetsLapse/tools/sync-cost-bench/bench.py libraries --photos <files> --lapse <files> --install-sim

Mac on library A, Simulator on a NEW library B of the same account: the
Simulator creates B through the phone's Libraries section
(`LL_LIBRARY=new:<name>`, the real door, with its existing session), imports
photos whose bytes A already holds and `.lapse` twins of A's projects, then
each device is launched in turn; one of A's projects is moved to B through the
API (the bench registers itself as a device first — the API refuses a token
without one), and each device is launched again. `--resume-b <folder id>`
carries a stopped run on from the move. The Simulator's library is chosen per
launch with `-storage.activeLibrary`, and library A is written back as its
setting at the end; **library B stays on the account and in the Simulator**.
The first run (2026-10-01) found the launch race in `docs/TODO.md`
("PicPlace libraries leak into each other").

A fresh sign-in is not part of it: the Simulator's own session is used. The
web sheet needs the account's password, which is in no seed file.

## Reading the report

- **API bodies** are JSON bytes without headers; **storage bytes** are the
  object's bytes. The wire cost is higher (the one-photo trace measured
  about 0.9 KB of headers per request on CFNetwork's summaries).
- A step's figures **include the launch's own check**: 5 requests on the Mac
  (`/status` ×4 and the index); on iOS a launch runs a *foreground* check and
  a *launch* check, about 12 requests (measured 2026-09-30, 21:40).
- `404` on `claim` is the normal answer for a brand-new project, not a failure.
- The ledger delta is the server's `letslapse_usage_events` for the account
  between the step's start and end (`ledger.php`, read-only). Claims,
  negotiates, presence and `/status` write nothing there by design.
- `run.json` holds everything the report was built from; `bench.py report
  <out dir>` rebuilds the report from it.

## Traps

- **`.lapse` files exported from projects that already exist on another
  account of the same server** (e.g. Steven's own library, mirrored on
  picplace.test as `regularsteven`) arrive as forks: the log shows
  `is taken by another account — re-minting … as a fork`. Expected, and the
  fork's push is what gets measured.
- A **timer check every 3 minutes** falls inside long steps; its 5 requests
  are in the step's totals. The highlights list each `check (timer)`.
- The **originals queue** is switched on for the run by launch argument
  (`-letslapse.picplace.autoOriginals YES`), never written to the setting;
  the Simulator keeps its own (off, so it pulls previews).
- Every launch **registers the device again** (`POST /device`) because the
  version string carries the build time; a run of the bench adds no device
  rows, a run with `--device-id` adds one.
- Killed mid-step, the bench quits the app it launched; the Simulator app is
  terminated by bundle id. Nothing is written to the libraries beyond what the
  app itself does.

## Files

- `bench.py` — the run, the settle logic and the report.
- `ledger.php` — the read-only server probe (`BENCH_USER`, `BENCH_SINCE`).
