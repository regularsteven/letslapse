# Storage accounting, and the Settings storage card

**Status:** open — not started
**Raised:** 2026-08-21, from a screen recording on the iPhone 12 Pro, confirmed
against the live device container the same afternoon
**Touches:** capture staging lifecycle · project archive export · Settings
storage card · **the armed capture screen's headroom chip** · per-project size
rows · Review large originals
**Design-sync:** yes — the Settings card changes shape on all four platforms

---

## 1. The symptom

A screen recording: Settings shows **Free on this device 57.98 GB**, **LetsLapse
library 26.29 GB** (Originals 26.17 GB, Blended clips 117.7 MB, Cache Zero KB).
Every project is then deleted, one by one. Final frame: **Free on this device
58.06 GB**, **LetsLapse library Zero KB**.

Deleting 26.29 GB freed 0.08 GB. The screen was not lying about free space — it
was lying about the library.

## 2. What is actually true

Measured on the device (`devicectl device info files --domain-type
appDataContainer`) minutes after the recording:

| Location | Contents |
| --- | --- |
| `Library/Application Support/LetsLapse/Projects/` | **empty** — one 102-byte `library.json`. The deletion did exactly what it said. |
| `tmp/` | **44.585 GB across 1554 files**, reported by the app as `Cache Zero KB`. |

The tmp pile breaks down as:

- **~25 GB of capture staging** — `liveblend-dng-1787249388` (738 frames,
  12.598 GB), `liveblend-dng-1787287218` (401 frames, 6.540 GB), and seven more
  from 12 MB to 1.3 GB.
- **19.626 GB of share archives** — `737 photos.lapse` (12.12 GB),
  `400 photos.lapse` (6.25 GB), `39 photos.lapse`, `29 photos.lapse`,
  `11 photos.lapse`, `3 photos.lapse`.

The 0.08 GB that *did* come back matches the blended clips (117.7 MB) — the only
bytes in the whole library that were uniquely the projects'.

### 2.1 The headroom chip is the same number

Confirmed on an iPad Air (M1) the same day. Deleting a 19.59 GB project moved the
armed capture chip from **≈4 420 · 74,79 GB** to **≈4 422 · 74,81 GB** — two more
frames, at ~16.9 MB each, for a 19.59 GB delete.

This is not a second bug. `CaptureHeadroom.Reading.frames` is
`freeBytes / cost.bytes` ([CaptureHeadroom.swift:190](../App/CaptureHeadroom.swift#L190))
over the same `volumeAvailableCapacityForImportantUsage` the Settings card reads.
The chip refreshed correctly and truthfully reported that the delete bought
nothing.

**It fails safe.** The chip under-reports room the operator never had, rather
than promising room that isn't there — so no shoot has run out of disk because of
this. That is the only reason this has stayed invisible for so long, and it is
why the fix is about honesty rather than about a broken forecast.

### 2.2 The iPad, mid-crime

The same walk on the iPad Air (M1) shows the clone pairs directly — staging
folders sitting beside their projects, byte-for-byte, one file apart:

| Project folder | tmp twin |
| --- | --- |
| `F727637E…` 9.781 GB, 753 files | `liveblend-dng-1787249253` 9.781 GB, 752 |
| `1AB1A034…` 7.789 GB, 507 files | `liveblend-dng-1786991128` 7.744 GB, 505 |
| `C0F047A8…` 5.546 GB, 336 files | `liveblend-dng-1786771006` 5.545 GB, 335 |
| `0AB37ECF…` 4.382 GB, 227 files | `liveblend-dng-1786943538` 4.302 GB, 225 |
| `F437B19F…` 0.998 GB, 53 files | `liveblend-dng-1786769452` 0.998 GB, 52 |

And at the top of tmp, with **no project twin**: `liveblend-dng-1787286522`,
**18.679 GB across 993 files** — the 991 frames and two sidecars of the project
deleted in the screenshots above, beside its `992 photos.lapse` archive at
17.700 GB. Container total **126.179 GB** against a reported library of 35.5 GB:

```
 51.673 GB  3179 files  tmp: liveblend staging
 38.459 GB     9 files  tmp: .lapse archives
 35.453 GB  2288 files  Projects  <- the only part the app reports
  0.594 GB   237 files  everything else
```

**Roughly 57 GB of that is reclaimable without losing a project** — the 38.5 GB
of archives plus the 18.7 GB orphan. The remaining staging folders are clones, so
deleting them frees nothing while their projects live: double-counted, not
double-stored. Stage 2's sweep must know the difference, or it will report a
reclaim far larger than the volume actually gives back.

## 3. Root causes

Four independent defects that happen to compound.

### 3.1 Adoption clones the staging, and the staging is never released

RAW interval shoots write DNGs into `tmp/liveblend-dng-<ts>/`
([CameraController.swift:6925](../App/CameraController.swift#L6925)); the JPEG
path writes to `tmp/liveblend-<ts>/`
([CameraController.swift:6728](../App/CameraController.swift#L6728)).
`registerCapture` then **copies** each frame into the project's `source/` folder
([AppModel.swift:5312](../App/AppModel.swift#L5312)), and the staging directory
is removed **only when a run is discarded or produced no frames** — both
controllers, [LiveBlendRawController.swift:1319](../App/LiveBlendRawController.swift#L1319)
and [LiveBlendController.swift:866](../App/LiveBlendController.swift#L866). A
successful shoot keeps its staging forever.

On APFS `FileManager.copyItem` is a **clone**: no new blocks. So the project and
the staging folder are two names for one set of physical bytes. Delete the
project and the bytes stay, held by the twin in tmp.

This is the whole of the reported symptom. Everything else below is a defect
found on the way to it.

> **Not a blanket "move instead of copy".** `registerCapture` is shared by the
> camera and by imports. For an import the source is a security-scoped file
> outside the container — copying is correct there and deleting it would be
> destroying someone else's file. The fix has to distinguish *we own this
> staging* from *this is a file we were handed*.

### 3.2 Share archives are never deleted

`exportProject` writes the `.lapse` into `temporaryDirectory`
([AppModel.swift:5933](../App/AppModel.swift#L5933)) and nothing ever removes
it. The share sheet's Done button clears a binding
([ProjectArchiveShare.swift](../App/ProjectArchiveShare.swift)). Every "Share
project" leaves a full second copy of the project on disk, permanently — 19.6 GB
of them on this device.

### 3.3 The cache filter doesn't match the app's own litter

`isCacheItem` ([AppModel.swift:3158](../App/AppModel.swift#L3158)) matches only
`letslapse*`, `.letslapse*`, `live-capture*`, `picked-*`, `import-*`. It does
**not** match `liveblend-dng-*`, `liveblend-*`, or `NN photos.lapse` — so the
two biggest things the app puts in tmp are neither counted in the Cache legend
nor reachable by Clear cache. Hence a disabled `Clear cache (Zero KB)` button
sitting on top of 44.6 GB.

A name-prefix allowlist is the wrong shape for this. Anything in our own tmp is
ours; the question is only whether it is still in use.

### 3.4 The library total is assembled from two folders

`computeLibraryStorage` ([AppModel.swift:3100](../App/AppModel.swift#L3100))
walks `<project>/source` and `<project>/blends` and nothing else. Anything the
app stores outside those two paths — Thumbnails, Logs, CaptureLogs, everything
in tmp — is invisible to the total *by construction*, so any future leak is
silent in exactly the same way this one was.

### 3.5 Two smaller accounting notes

- `directorySize` sums `totalFileAllocatedSize`
  ([AppModel.swift:3165](../App/AppModel.swift#L3165)), which charges a clone
  full price. That is the right number for "how big is this shoot" and the wrong
  number to print next to a delete button.
- The same walk passes `.skipsHiddenFiles`, so hidden files are never counted
  anywhere in the app's storage figures.
- Per-project sizes in Projects and in **Review large originals** inherit the
  same allocated-size accounting, so they were inflated too.

## 4. The clone proof

Foundation on APFS, measured with `df`:

```
after making 400MB src : 135898 MB free
after FileManager copy : 135898 MB free   ← the copy cost 0
after deleting the copy: 135898 MB free   ← deleting the "project" freed 0
after deleting the src : 136298 MB free   ← deleting the staging freed 400 MB
```

That is the video, at 1/65th scale.

## 5. What best practice looks like

Storage UI has one job: answer *"what do I delete to keep shooting?"* Everything
here falls out of that.

1. **One byte, one owner.** Fix the model, not the label. No amount of clever
   wording makes "delete 26 GB → free 118 MB" acceptable. Exclusive-bytes
   accounting is for *deliberate* sharing, never for covering litter.
2. **Measure the container, derive the buckets.** Total from a whole-container
   walk; named buckets subtracted from it; the remainder shown as a real line.
   Under-reporting becomes structurally impossible.
3. **Next to a delete button, show reclaimable — never allocated.** Any figure
   adjacent to a destructive action is a promise about what pressing it returns.
4. **Put the number at the moment of the decision.** "Delete project? This frees
   12.6 GB", then "Freed 12.6 GB" afterwards. The Settings card is a lagging
   indicator; the confirmation sheet is where the choice is made.
5. **Temp is the app's problem.** Clear cache is an apology for littering. If it
   routinely has work to do, that is a bug report from our own UI.
6. **Bytes are not the unit people think in.** "~2 h 10 m of 4K" beats "58 GB",
   and the capture headroom chip already speaks that language.
7. **Don't invite a comparison you'll lose.** `volumeAvailableCapacityFor-
   ImportantUsage` includes purgeable space and will never match Settings ▸
   iPhone Storage. Right answer for "can I shoot this?", wrong thing to present
   as a ledger — so round it (58 GB, not 57,98 GB) and frame it as headroom.

## 6. Target design

```
STORAGE
Room to shoot          ~2 h 10 m of 4K · 58 GB free
LetsLapse is using     44.6 GB
   ▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬
   ● Originals 26.2 GB   ● Blended clips 118 MB   ● Working files 18.3 GB
Working files          18.3 GB · safe to delete        [ Free up ]
Review large originals                                          ›
```

Three deliberate choices: the forward-looking line comes first because it is the
only one that changes a decision; "LetsLapse is using" is one measured number
with a legend that sums to it exactly; and the reclaimable bucket carries its own
verb, so freeing space is one tap from the number that motivated it.

`Clear cache` is replaced by `Free up`, which states what it will delete and
reports what it freed.

## 7. The work

### Stage 1 — stop the leaks

- Give the live controllers an explicit **release** step: once
  `registerCapture` has adopted a run, delete its staging directory. Both the
  DNG and JPEG paths. Only on successful adoption — a throw must leave the
  staging intact, because at that moment it is the only copy of the shoot.
- Prefer `moveItem` where the staging is ours, so the bytes are never accounted
  twice even briefly. Sidecars travel too (`frames.timestamps`,
  `capture_log.json`, `frames.exposure`, Scanner siblings) — see the sidecar
  block in `registerCapture` and `copyScannerSiblings`.
- Delete the `.lapse` archive when the share sheet dismisses, plus a
  launch-time sweep for archives left behind by a crash or a kill.

**Acceptance:** shoot, adopt, delete the project → free space rises by the size
of the shoot, **and the armed capture chip's frame count rises to match**. A
shoot interrupted between capture and adoption still has its frames on disk.

### Stage 2 — one-time reclaim for existing installs

Every device already carrying orphans (this one: 44.6 GB) needs them cleared.
A launch-time sweep of our own tmp that removes anything not owned by a run in
progress. Surface it once: "Reclaimed 44.6 GB of leftover working files."

**Acceptance:** on the bench iPhone 12 Pro, tmp drops from 44.585 GB to
approximately zero and the volume's free space rises to match. On the iPad Air
(M1), the sweep reclaims ~57 GB — and reports ~57 GB, not the 90 GB that a naive
sum of tmp would claim, because most staging is cloned against a live project.
Report what the volume gave back, not what was deleted.

### Stage 3 — honest accounting

- `computeLibraryStorage` walks the **whole container**; named buckets are
  subtracted; the remainder becomes a visible "Working files" line.
- Add a **reclaimable** figure distinct from allocated, and use it everywhere a
  delete affordance is adjacent: the delete-project sheet, bulk delete, the
  Review large originals rows.
- Replace `isCacheItem`'s prefix allowlist with an in-use test.
- Decide on `.skipsHiddenFiles` — almost certainly should be counted.

**Acceptance:** the app's total equals a container walk to within a rounding
step; every legend entry sums to the total; a deliberately orphaned file shows
up in Working files rather than vanishing.

### Stage 4 — the card, and the design mirrors

Implement §6. Per the design-sync contract, the Settings SVGs for iOS, iPadOS,
macOS and watchOS (where applicable) are updated in the same unit of work, and
each platform folder's `INDEX.md` is re-stamped.

Copy fixes that belong here: **"Zero KB"** is `ByteCountFormatter`'s output and
reads like a bug — use "None" or "—". Keep decimal GB (`.file`) to match iOS
Settings. Show "Calculating…" during the walk rather than last visit's number.
Bulk destructive actions state the total: "Delete 14 projects (26.3 GB)?"

### Stage 5 — verification on device

The bench recipe, on a device with a real library:

```bash
xcrun devicectl device info files --device <udid> \
  --domain-type appDataContainer \
  --domain-identifier com.regularsteven.letslapse
```

Before and after a shoot, an adoption, a delete and a share. Cross-check the
app's own figures against the walk. `ideviceinfo -q com.apple.disk_usage`
(`AmountDataAvailable`) gives the volume side independently of the app.

## 8. Traps and decisions

- **Adoption order.** Adopt, persist, *then* release staging. Never the reverse
  — a crash between the two must lose the temp copy, not the shoot.
- **The share archive may still be open.** A share extension can be reading the
  `.lapse` when the sheet dismisses. Delete on dismissal *and* sweep at launch;
  don't delete while the sheet is up.
- **Imports are not ours.** Security-scoped sources get copied and left alone.
  `picked-*` / `import-*` staging in tmp *is* ours (see
  [MediaPickers.swift:16](../App/MediaPickers.swift#L16)) and can be released
  after adoption like any other.
- **Runs in progress.** The launch sweep must never touch a directory an active
  controller owns. Simplest safe rule: sweep at launch only, before any capture
  can have started.
- **Watch out for `Zero KB` as a truthiness test.** `storage?.cacheBytes ?? 0 ==
  0` currently disables Clear cache; with honest numbers that guard starts
  behaving differently.

## 9. Open questions

- Does "Working files" want a per-item breakdown, or is one line plus a verb
  enough? (Leaning: one line. The triage screen is Review large originals.)
- Should Review large originals become the single storage-triage screen —
  projects *and* working files, sorted by reclaimable?
- Is there a case for keeping staging deliberately (fast re-adoption after a
  failed blend), and if so, does it need a visible age-out policy rather than
  being invisible forever?
