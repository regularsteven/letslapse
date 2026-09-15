# PicPlace sync v2 — handover

**Date:** 2026-09-15 · **Branch:** `ios-app`, commits `52a078d` → `6178c06`
(eleven, all on top of v1's `0b5d545`) · **State:** stages 1–5 of the plan
and the first half of §4.7 (auto-sync) are built, verified and committed;
Steven has lived with it across his Mac and the iPhone 16 Pro Simulator for
a day against `picplace.test`. Nothing has touched `picplace.co` or a
physical device yet. · **Working mode:** code-first by decision (plan D12);
every screen's SVG mirror is owed.

Read in this order: this file → [picplace-sync-v2-plan.md](picplace-sync-v2-plan.md)
(the model and the twelve decisions, then §9–§14 for what each stage landed
and found) → [picplace-sync-v2-server-asks.md](picplace-sync-v2-server-asks.md)
(the server contract as agreed; the PicPlace repo's `docs/letslapse-sync-v2.md`
is the developer's answer, ask by ask) → `CLAUDE.md` for the `LL_PICPLACE_*`
hooks.

## 1. What is complete

| Stage | What a person gets | Where |
|---|---|---|
| 1 | A library **belongs to an account**: `<root>/PicPlace/account.json` keyed by `(server.id, user.uuid)`; the Mac nests into `<root>/<host>/<username>/` by rename and relaunches; iOS binds in place; tokens per account in the Keychain; the session follows the library; Connect / Disconnect; sign-out keeps everything | plan §9, `PicPlaceController`, `PicPlaceBinding` (Kit), `StorageRoot.nest` |
| 2 | **The minimal dataset**: one `records.aar` (deterministic Apple Archive of the registry's records and sidecars), one `poster.jpg`, hash-deduped LUTs; sources and blends stay; `originID` is the server key; the manifest cap and its overflow shape | plan §10, `PicPlaceSyncPolicy`, `PicPlaceSyncRun`, `PicPlacePoster` |
| 3 | **The first connection** (clean · fresh · merge) and **the pull**; preview-only projects (the poster stands in, editor refuses) | plan §11, `PicPlaceLibrarySync` |
| 4 | **The merge, continuously**: a check at launch / foreground / every 3 min / on demand over the whole index with tombstones; every §4.4 row; conflicts with a sheet (keep this device's / PicPlace's / both); tombstones both ways; `uuid_taken` re-mint | plan §12, `PicPlaceChangeSync`, `PicPlaceConflictsView` |
| 5 | **Originals per project**: Upload (policy `originals`) and Download (pages of presigned URLs, resumable); presence tiers | plan §13, `PicPlaceDownloadRun` |
| §4.7 (part) | **Auto-sync**: settled edits pushed after 20 s, the timer check, the originals queue behind switches; **only on Wi-Fi/Ethernet for everything automatic**, a person's press on any connection; unchanged copies of deleted projects trashed on their own; posters converge | plan §14, `PicPlaceAutoSync` |

Also: the Simulator signs in (`App/LetsLapse-Simulator.entitlements`,
`tools/sim-fresh.sh`), the two-device bench (`tools/picplace-bench/`), and
the design index rows marked 🟡.

## 2. What is in progress / owed

- **SVG mirrors for every PicPlace screen** (design-sync debt, D12): the
  Settings card's LIBRARY / SYNC / check / review rows, the project card's
  seven states + the Originals line, the Projects pill's preview-only
  state, the conflicts sheet (no mirror at all), the connect question's
  case copy. `docs/design/iOS/INDEX.md` and `macOS/INDEX.md` say what is
  stale; `LL_PICPLACE=<state>`, `LL_PICPLACE_BIND`, `LL_PICPLACE_REVIEW`
  stage them.
- **iOS background transfers**: uploads and downloads are foreground
  `URLSession` tasks — they pause when the app is backgrounded and resume
  at the next foreground. A `URLSessionConfiguration.background` session
  with the per-file upload/download tasks is the next real piece of work
  before phones are trusted with big originals.
- **`updated_since`** is stored (`sync-state.json` → `meta.serverTime`)
  but deliberately unused: an incremental index misses a project only this
  device edited. Use it only alongside a local "moved since base" pass.
- **The M4 adopt trap** (TODO's data-model entry): `StorageRoot.check`
  recognises a library by `Projects/library.json`; fix before M4 retires
  the export or re-nominating the volume is offered as a 431 GB move.
- **`ref/`** is not a registered project folder and is skipped by the
  minimal policy (one project on the volume holds hand-dropped reference
  pictures). Register it or accept.
- The server's **`status.projects.count` counts tombstones** and one
  **MySQL cache deadlock 500** on `/status` were reported to the developer.

## 3. What is next (recommended order)

1. **Real-world run on `picplace.co`** (§5 below) — before more features.
2. **Background transfers on iOS** (§2).
3. **Eviction** — "free up space": the presence tier says which device
   holds originals; evict to preview only after the server confirmed the
   hash (Part 3 §10.6). Then **replace-local / replace-server** (plan D9)
   become honest.
4. **Per-blend posters** (66 projects on the volume have blends; a pulled
   blend row is a placeholder today) and blend playback refusal when the
   file is absent.
5. **The mirrors** (§2), once the screens have settled with Steven.
6. Server follow-ups with the developer: `PUT /library` for the account
   bundle (presets, ladders, blend profiles, collections), multipart over
   5 GB, an `updated_since` you can trust, the two nits.

## 4. What was problematic (so the next agent does not re-learn it)

Client, found and fixed on the way:

- **Keychain**: an unentitled build's `save` fell back to the login
  keychain but `load` only fell back on two error codes → every relaunch
  signed out (stage 1's first hand test). Both fall back on anything short
  of success now. And an **unsigned Simulator build has no entitlements at
  all** → `-34018`; the project scoped its iOS entitlements to `iphoneos*`
  and the run skill built with `CODE_SIGNING_ALLOWED=NO`.
- **`bytes: null`** on a first negotiate (server; documented as `0`) —
  latent since v1, never hit because v1's test project pre-existed.
- **The index response grew `server_time`** → the old `[String: [PPProject]]`
  decode failed silently (`PPProjectIndex` now).
- **Apple Archive is not deterministic** with the default field set (ctime
  of every hard link) → a content-only set (`TYP,PAT,DAT`) or the bundle
  re-uploads on every sync.
- **Revision rounding**: the document encoder rounds stamps to the
  millisecond; `Int(ms)` truncated → a device read its own document back
  1 ms off and re-pushed every launch. `revision(of:)` rounds.
- **The lazy controller**: created by the first card drawn — an empty
  library's Projects tab never drew one, so a fresh library never synced.
  Created at the end of the launch now.
- **`updated_since` alone cannot drive the check** (§2).
- **A tombstone's write is an edit to the persister** → the auto-push tried
  to sync a folder in the trash. The auto-push ignores tombstones; errors
  have their own non-spinning line.
- **"Deleted on PicPlace" was always a decision** — Steven expected an
  unchanged copy to just go. It goes (to the trash) unless edited since.
- **Posters did not converge**: a project in step since before posters
  existed never got one. Two rules now (plan §14 addendum).
- **Scratch runs borrowed the install's session** at first (the session
  pointer is per install) — a test refreshing tokens rotates the pair under
  the person's own instance. Unbound scratch roots never borrow it now, and
  a refused refresh re-reads the Keychain before signing out.
- **A test renamed a real project once** (China City) through the funnel;
  reverted within a minute. The bench README says it in bold: throwaways only.
- **The harness raced the app** (read the previous launch's log); the
  bench's `launch_wait.sh` waits for a new log file.
- Cosmetic, open: the disabled *Download originals* draws in the accent
  colour; the Library row's date format is the locale's.

Server side (the developer's, reported): first-negotiate `bytes: null`
(fixed there too), `status.projects.count` includes tombstones, one
`SQLSTATE[40001] Deadlock … insert ignore into cache` from `/status`.

## 5. How it was tested, and what needs the real world

**Against `picplace.test` + Garage (Docker S3) — done:**

- Steven's own hand: Mac sign-in via the browser, connect → nest →
  relaunch; two projects pushed under v1 then re-synced minimal; sign-out /
  sign-in; the Simulator as a true second device (erased, signed in,
  connected, fresh case, four projects pulled); rename round trips both
  ways; metadata title/caption both ways; junk projects deleted on the Mac
  and trashed on the Simulator; Perf bench's poster converging.
- The two-device bench (`tools/picplace-bench/`, scratch roots bound to
  the account, a second device id by launch argument): every §4.4 row in
  both directions; keep newest and keep both (a fork); tombstones both ways;
  originals up (1.9 MB) and down (1 file; 1,480 files / 86 MB in 8 s, a
  second run moving nothing); the auto-push after a funnel rename; the
  timer check; the originals queue; the Wi-Fi holds and their release
  (simulated path); unchanged copies trashed; the poster push.
- Kit tests: `PicPlaceBindingTests` (4), `ProjectFileRegistryTests` (3),
  `DirectoryArchiveDeterminismTests` (1).

**Not tested — needs the real world:**

- **`picplace.co`**: Hetzner Object Storage (presigned PUT/GET against a
  real endpoint, CopyObject dedupe, the 15-minute GET lifetime under real
  latency), real TLS, nginx's 16M body cap, the per-device rate limits, the
  reaper timing, `server.id` minted on deploy. The Release build defaults
  there; the Debug build points at `.test` — verify the Server row before
  the first sign-in.
- **Physical iPhone / iPad**: `ASWebAuthenticationSession` on device, the
  Keychain on device, **real cellular** for the Wi-Fi rule (only simulated
  so far), Low Power Mode, backgrounding (transfers pause today), storage
  headroom on a phone for a big download, thermals during an originals
  upload after a shoot, and the capture guard (a check must not run while a
  shoot writes — the `stage == .processing` test has not seen a real shoot).
- **The volume library** (365 projects, 431 GB): the clean case pushing
  every project's bundle + poster (365 poster renders from DNGs — minutes),
  the manifest cap on the biggest interval documents, the nest of a
  drive-root library, thumbnail keys after the nest, and the M4 trap.
- **Two accounts**: `uuid_taken` and the connect-refusal for another
  account's library (needs the throwaway account asked for).
- **The `unrelated` conflict kind** (a `.lapse`/LAN twin with no base) —
  same branch as both-edited, never exercised.
- **A Mac on a phone's hotspot** (`isExpensive` from `NWPathMonitor`).
- **Blends**: a project with rendered clips pulled to another device (the
  rows are placeholders; playback of an absent file is not refused).
- **Multipart** (> 5 GB objects) — the server refuses at negotiate; no
  such object exists yet.

## 6. Running it

- Mac Debug (hooks): build with `xcodebuild … -configuration Debug
  -destination 'platform=macOS' -derivedDataPath
  ~/Library/Developer/LetsLapseRun/dd-mac-picplace`; launch the binary
  with `-storage.libraryRootPath <root> -ApplePersistenceIgnoreState YES`
  and `LL_*` env. Never point a run at `/Volumes/letslapse`.
- Simulator: `tools/sim-fresh.sh` (`--keep` to reinstall over a library).
- Bench: `tools/picplace-bench/README.md`.
- Steven's real instances: the Release build from Xcode on the play-pen
  (`~/Library/Application Support/LetsLapse/picplace.test/regularsteven`)
  and the iPhone 16 Pro Simulator `B7DFFBA0-…`. Their logs are the truth
  of what a check decided (`Logs/console-*.log`, grep `picplace:`).
- Server: `~/Sites/picplace`, `php artisan tinker` for the registry;
  Garage via `dev/garage/`.
