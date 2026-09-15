# Import photos — telling a shoot from a pile of photos

**Status:** SHIPPED 2026-09-15 (path E, code first by Steven's call, signed
off "works as expected", SVG mirrors drawn the same day —
`design/{macOS,iOS}/stills-import.question*.svg`, iPad shared-spec). Kit: `ImportedStills+Reading.swift` +
`ImportReadingTests` (30/30, the shapes of `tools/import-classify/cases.py`,
27/27); app: `StillsImportSheet.swift`, the branch and the photo-batch path
in `AppModel.runStillsImport`, `requestedProjectsFilter` on `ProjectsView`,
`LL_IMPORT_ANSWER`, the library path's invented names. Verified on the Mac
against a scratch root and on an iPhone 16 Pro simulator (§10). **Owed:**
the batch's toast + Undo, *Leave these out* (§4), `lapse classify`, an
iPad run. History: the rule was revised twice on 2026-09-15 after
Steven's review — a shoot must be *clean* (test shots never ride in, a
derivative is a cleanup not a skip), then the type is nominated on a sheet
with Auto as the pre-selection.

## 1. The problem

Create ▸ "Import photos…" takes files, folders or both and registers
**whatever it resolves to** as one project: one file is `Photo · Imported`,
two or more are `Interval · Imported` (`AppModel.runStillsImport` →
`registerImportedStills`, the `sequence.count == 1 ? … : …` line). There is
no test in between. A folder of 117 holiday pictures becomes a 117-frame
interval shoot, opens in the blend flow, and shows a `mode` the shoot never
had.

The brief: inside the import, look at the files. No file-name sequence → not
a shoot, every file is its own photo. A sequence → read the clock: regular
spacing (≤ 60 s) with the other signs of an intervalometer → a shoot;
otherwise photos. A set that holds *both* → ask (import as individual
photos, or cancel and tidy the folder).

Two things Steven added on review, and they set the bar for everything
below:

- **A shoot needs very high confidence, or the app asks.** A folder holding
  a shoot *and* a rendered derivative of one of its frames
  (`_WEX3518-Rendered.dng`) is not a clean shoot; it is a folder that needs
  cleaning up, and the app must not quietly decide which file is the odd one
  out. It says so and asks.
- **Test shots are the common case.** A real shoot starts with a few frames
  30–60 s apart — exposure, framing, focus — and *then* the run. Those
  frames share the stem and the numbering; nothing but the clock separates
  them from the run, and a rule that tolerates "90 % on the beat" imports
  them as frames 1–6 of the timelapse. The rule has to be *every* frame.

## 2. What the sample folders say

Probed the way the app probes (ImageIO header reads: `DateTimeOriginal` +
`SubsecTimeOriginal`, TIFF Make/Model/Software, EXIF exposure) with
`tools/import-classify/probe.swift`. Gaps are between consecutive frames in
name order. *On the beat*: within ±35 % (floor 0.5 s) of the running
median of the run so far — see §3.3.

| set | stills | name stems | modal step | bodies | frames on a beat | days | span · beat | verdict |
|---|---|---|---|---|---|---|---|---|
| `Exports_testing/china` | 117 jpg | 2 (`China Pics-#`, one unnumbered) | 0.14 | A7R II, Lightroom 8.2.1 export | none | 8 | 107 h | **photos** |
| `Exports_testing/japan` | 761 (JPG + 13 DNG) | 2 (`IMG_#`, `APC_#`) | 0.49 | iPhone 16 Pro | none (longest 3) | 15 | 174 h | **photos** |
| `Exports_testing/malaysia` | 380 (+ 288 `.xmp`) | 12 | 0.36 | 5 bodies | none (longest 3) | 44 | 960 h | **photos** |
| `Exports_testing/tram_bouncing` | 5030 jpg | 1 (`frame-#`) | 1.00 | iPhone 16 Pro, via Lightroom Classic 15.5.1 | all 5030 | 1 | 1.40 h · 1.00 s (0.95–1.00) | **shoot** |
| `Source_SONY/Charles_ARW` | 306 ARW + `_WEX3518-Rendered.dng` (+ 1 `.xmp`) | 1 + the derivative | 1.00 | A7 IV | all 306 | 1 | 18 min · 3.62 s (±0.02) | **ask** — a shoot once the derivative is out |

What the numbers settle:

- **The photo folders and the shoots are not close.** The three photo
  folders have no run of even four frames on a beat; the two shoots are on
  the beat from the first frame to the last. The name test alone already
  rejects all three photo folders.
- **Exposure is not a sign.** `tram_bouncing` is a dusk ramp — shutter
  1/170 s → 1.0 s, ISO 32 → 250, 43 distinct triples — and it is the most
  obvious shoot of the five. `Charles_ARW` is locked (3.2 s · f/4.5 · ISO
  100 on every frame). Constant exposure corroborates; varying exposure
  proves nothing; neither gates.
- **Clock precision varies by body.** The A7 IV and the iPhone write
  `SubSecTimeOriginal`; the A7R II in `malaysia` writes whole seconds
  (291 of 380 frames). Whole seconds quantise a 1.2 s beat into 1, 1, 1, 2,
  1… — the tolerance floor has to follow the precision (§3.3) or a real
  shoot on such a body shatters into "photos".

### The two folders asked about

- **`tram_bouncing` → a shoot, silently.** LetsLapse's own `frame-%05d`
  naming round-tripped through Lightroom Classic (the Software tag; the
  `lr_vs_ll.mov` and `frame-00001-graded.psd` beside it say why). One body,
  one size, one focal length, 5029 gaps of 0.95–1.00 s, one evening
  (2026-08-31 17:24–18:48). It lands as `Interval · Imported` with its
  timestamps sidecar — what today's path does with it, now *earned*.
- **`Charles_ARW` → ask, as it stands.** `_WEX3517…3822`, every step +1, an
  intervalometer at 3.62 s ± 0.02, one body, locked exposure, the same
  evening (18:29–18:47 — the Sony beside the iPhone). But
  `_WEX3518-Rendered.dng` is a Lightroom render of frame 3518 — same
  capture time to the millisecond, Software = Lightroom Classic — and
  today it is imported as a **307th frame**, sitting second in the set.
  Under the clean-set rule it is a *stranger by name* (stem
  `_WEX#-Rendered`, and 3518 twice), so the import asks:

  > 306 frames keep a 3.6 s beat. 1 file doesn't belong:
  > `_WEX3518-Rendered.dng`. Without it this folder is a shoot — move it
  > out and import again, or import all 307 files as individual photos.

  Delete the render (the `.xmp` is a sidecar, invisible to the test and
  carried with its raw as today), import again → a shoot, silently.

### The three photo folders

`china`, `japan`, `malaysia` → every file its own `Photo · Imported`
project (117, 761 and 380 projects). All three fail the name test and the
clock finds no beat anywhere, so the verdict is silent (§3.4).

## 3. The classifier — a shoot is a clean set

**A shoot is one name sequence in which every frame sits on one beat, and
the only irregularity is a pause whose beat continues on the far side.**
Anything less is a question, never a silent shoot. *Photos* (one project
per file) is silent only when no beat exists anywhere in the set. Between
those two one-sided cases the app asks, and says exactly why.

A pure function in the Kit beside `ImportedStills.Sequence` — names and
frames in, a reading out — with `tools/import-classify/classify.py` as the
reference it must match and `cases.py` as its fixtures (§9). Under path E
the reading feeds the sheet rather than deciding:

```
struct ImportReading {
    var suggested: Kind?          // .shoot for a clean run ≤ 60 s, .photos when no
                                  // beat exists; nil when the files disagree (§3.4)
    var summary: Summary          // count, formats, camera, span, beat, pauses
    var warnings: [Warning]       // strangers (named), pairs, beatChange, slow, short, noClock
}
```

The rest of §3 is unchanged: what a run is, what a stranger is, what a
pause is — the reading has to find them whichever path presents it.

### 3.1 Names

A set is a **name sequence** when one stem pattern (`prefix#suffix`, `#`
the last run of digits) holds ≥ 95 % of the files, its numbers ascend, and
≥ 90 % of the steps equal the most common step. "The modal step" rather
than "+1" because frames named by timestamp (`IMG_20260831_172450`) step by
the interval, and a card with a few deletions steps 2 here and there.

**Strangers by name:** every file outside the dominant stem, or with no
number, or a number that appears twice among singles — `cover.jpg`,
`_WEX3518-Rendered.dng`. **Pairs:** every number appears the same *k* > 1
times — RAW+JPEG, one exposure per *k* files — which is its own answer,
not a list of strangers.

Not a sequence → never a silent shoot (the brief). It is *not* an
automatic "photos", though: the clock still runs, so a sequence hiding
behind a stray file asks instead of silently becoming 5031 photo projects.

The iOS Photos-library path stages files under `photo-0001…` when the
library has lost the camera name; those names are synthetic and must not
count as a sequence (`importLibraryPhotos` knows which it invented).

### 3.2 The clock

**EXIF capture times only.** The probe's fall-back to the file's
modification date is fine for a project's date and poison for this test:
a plain `cp` stamps files seconds apart in copy order and manufactures a
perfect beat. A frame with no EXIF time is a **stranger by clock**; a
sequence with no EXIF times at all is the *no-clock* question.

The clock is read on the files that pass the name test — the folder as it
would be once tidied — so the question can say what the folder becomes.

### 3.3 Runs, pauses, strangers

Walk the gaps in name order. A **run** is a maximal stretch of consecutive
gaps where each gap is on the beat of the run so far: within ±35 % of the
median of the run's previous ≤ 8 gaps, or within the **floor** — 0.5 s
when the frames carry sub-second stamps, 1.0 s when they carry whole
seconds. The running median is what lets a Holy Grail ramp (1.0 → 4.5 s
over 5000 frames) stay one run while a test shot, a pause or a stray breaks
it. A run shorter than **24 frames** is not a run (a continuous-drive burst
of ten is not a timelapse).

Frames covered by a run are **run frames**; every other frame is a
**stranger by beat** — the six test shots before a run, a snap taken
mid-run, a frame with no time.

Two adjacent runs whose beat continues across the join — the median of
the last 8 gaps of one within tolerance of the first 8 of the next — are
one run with a **pause** in it: a battery swap, a card change, a frame
deleted on the card. A pause is any length; it is recorded as today's
`importGap` issue and laid out on the real clock by the timestamps
sidecar. A beat that *changes* across the join (3.6 s → 10 s) is not a
pause: those are two shoots, or one shoot whose interval was changed, and
either way a question.

### 3.4 The verdict, in order (path A) — the pre-selection and the warning line (path E)

| # | evidence | verdict |
|---|---|---|
| 1 | one file | photo (as today) |
| 2 | 2–4 files | photos — too few to be a shoot with any confidence (today: a 2-frame "shoot") |
| 3 | a sequence in pairs (RAW+JPEG) | **ask · pairs** |
| 4 | a sequence, no EXIF clock at all | **ask · no clock** |
| 5 | a sequence, no strangers, one run covering every file, beat ≤ 60 s | **shoot** — silent |
| 6 | as 5, beat > 60 s | **ask · slow** |
| 7 | a sequence, no strangers, one beat, fewer than 24 frames | **ask · short** |
| 8 | no run of 24 frames anywhere | **photos** — silent |
| 9 | a sequence, no strangers, more than one run (the beat changes) | **ask · beat change** |
| 10 | everything else — strangers by name, by clock or by beat | **ask · strangers**, naming them |

The 60 s cap is Steven's. Under path A rows 5 and 8 are the silent
verdicts and each needs one-sided evidence. Under path E row 5 pre-selects
*Interval shoot*, row 8 (and 2) pre-selects *Photos*, and every other row
is a warning line with no pre-selection. Corroborating signs — one body, one pixel size,
one focal length — are recorded in the session log's issues and quoted in
the question, never gated on.

### 3.5 What the rule does with the shapes a card takes

From `cases.py` (timings synthesised from Charles's own 3.62 s run):

| shape | verdict |
|---|---|
| clean 306-frame run · tram's 5030 · a Holy Grail ramp 1.0 → 4.5 s · 4 frames deleted on the card · a 600 s or a 3-day pause · whole-second stamps at 1.2 s · timestamp-named frames | **shoot** |
| 6 test shots 40–61 s apart then the run · 5 test shots that happen to be 40–43 s apart · a stray snap mid-run · the rendered derivative beside its frame · `cover.jpg` in the tram folder · 40 snaps then the run (a mixed card) · 3 frames missing their times · whole-second stamps with test shots | **ask · strangers** (the files named) |
| two shoots in one folder (3.62 s, a 2 h hole, 10 s) · the interval changed at frame 200 | **ask · beat change** |
| 120 s × 300 · 15 min × 100 | **ask · slow** |
| 12 clean frames | **ask · short** |
| RAW+JPEG for the whole run | **ask · pairs** |
| numbered frames with no capture times | **ask · no clock** |
| china · japan · malaysia · 400 iPhone snaps in numbered order · a 10-frame burst among 50 snaps · 3 files | **photos** |

## 4. The sheet (path E)

After the pick, before the copy — the moment the app has read the files
and the person has not yet spent anything. A sibling of `ProjectImportSheet`
(`App/ProjectImport.swift`, the `.duplicate` phase asks the same way):
root-presented, blocking, Cancel always reachable.

- **Title and summary:** "Import 307 photos" · `Charles_ARW · ARW, DNG ·
  Sony ILCE-7M4 · 18 min`. What was picked, as the files describe it.
- **The choice, two rows:** *Interval shoot — one project of 306 frames,
  3.6 s apart* / *Photos — 306 separate projects*. Each row says what it
  makes, in numbers, so "Photos" on a 5030-file folder reads as the 5030
  projects it would be.
- **Auto is the pre-selection, not a third row.** When the reading is
  clean the matching row is pre-selected and tagged *Detected*; Import is
  the default action and the sheet costs one tap. A three-way
  Auto/Shoot/Photos would make the person guess what Auto will do; the
  pre-selected row *is* the answer, shown.
- **When the files disagree, an amber line and no pre-selection:** "306
  frames keep a 3.6 s beat. 1 file doesn't belong:
  `_WEX3518-Rendered.dng`. Without it this folder is a shoot — move it out
  and import again." Import stays inert until a row is chosen. The brief's
  answer (cancel, tidy the folder, import again) is the obvious move; the
  other two are available, informed. The lines, one per reading:
  strangers by name (files listed, what remains without them) · strangers
  by beat ("6 files don't keep the beat: `_WEX3511`–`3516`, 30–61 s apart
  before the run") · pairs ("every frame is here twice, ARW and JPG") ·
  beat change ("the interval changes at `_WEX3717`: 3.6 s, then 10 s") ·
  slow ("one every 2 min — slower than a shoot is recognised at") · short
  · no clock.
- **One file:** no sheet, a photo, as today.

Choosing *Interval shoot* over a warning imports the strangers as frames —
the app does not drop files it merely copied; Bad Frames is where a frame
is dropped, by someone looking at it. The natural follow-up once the sheet
exists is a *Leave these out* switch on the warning line — the person
editing the set, visibly, without the Finder round trip. Not v1.

Headless: `LL_IMPORT_ANSWER=shoot|photos|cancel` beside
`LL_IMPORT_STILLS=<path>[:<path>…]`; `LL_IMPORT_STILLS` alone stages the
sheet for screenshots.

## 5. Paths considered

**E. Nominate the type in the import, Auto pre-selects (recommended —
Steven's proposal, 2026-09-15).** §4. The sheet always appears for two or
more files; the reading pre-selects the row when the set is clean and
warns when it is not. What this simplifies is *where the confidence comes
from*: the classifier no longer has to be right silently — it has to be a
good default and an honest warning — so the two one-sided silent verdicts
of path A, and the thresholds that made them safe, stop being load-bearing.
Seven case lines collapse into one sheet with an optional amber line. The
cost is one tap on every multi-file import, including the 5030-frame
folder that could not be anything else; the tap buys a confirmation before
761 projects exist and a look at the reading before a copy starts. If it
grates, "skip the sheet when the reading is clean" is a one-line change
later. Not simplified away: the strangers must still be found and named,
or a person picking *Interval shoot* for a folder they believe is clean
imports the test shots silently — the exact case Steven raised.

Where the control cannot live: *in the picker window*. `UIDocumentPicker`
has no accessory view; `NSOpenPanel` has one but `.fileImporter` does not
expose it (and `CreateView` deliberately runs one importer for its three
jobs); and a choice made before the files are seen cannot be pre-set by
the reading, so the sheet would still be needed after the pick. After the
pick is the only place that is both portable and informed.

**A. Classify at import, silent verdicts.** §3.4's table as the decider:
clean shoots and plain piles land silently, everything in between asks.
Fewer taps than E for the clean cases; the thresholds carry the product.
Superseded by E — the same classifier, now advising a sheet instead of
deciding.

**B. Ask every time there is more than one file.** No heuristics, nothing
to tune — and a sheet in front of every 5030-frame folder that could not be
anything else. Cheap fallback if A ever misbehaves; not the product.

**C. Two rows on Create — "Import photos…" and "Import a shoot…".** The
operator says what it is before picking; the classifier only *warns* when
the files disagree. One more row on Create, and "Import a shoot…" on a
folder with six test shots in it still has to warn after the pick — so C
is E with the choice made earlier and blind. E's row-in-the-sheet is the
same choice, made with the reading in front of the person.

**D. Import as today, offer "Split into photos" on the project.** The
761-frame "shoot" is still born wrong and opens in the blend flow.
Rejected.

## 6. The photo-batch path (new)

N files → N `Photo · Imported` projects. `registerImportedStills` already
does everything a one-photo project needs (own folder, own `createdAt`
from EXIF, the file's own name, one-line sidecars); the batch calls it once
per file. New:

- **One progress card, one activity** — "Importing photo 212 of 761…".
  `ProjectStore.insert` is per-project (`project.json` + an index row), so
  761 inserts are fine; `waiting: false` keeps the card moving.
- **`autoTagIfEnabled` spawns a Vision pass per project.** 761 at once is
  contention for nothing; the batch tags serially after the copies.
- **Landing.** Not `show(capture)` ×761. The Projects list or the Gallery
  filtered to photos, sorted by capture date, with a toast "761 photos
  imported" — and **Undo** on the toast, through the tombstone path, since
  a wrong answer to the sheet is 761 projects. UI: design-sync applies.
- **RAW+JPEG pairs never reach this path silently** (row 3 asks). If the
  operator answers "Import as photos", each file is its own project — the
  app does not pick a rendition.
- **Order and dates.** Each photo's `createdAt` is its own shutter time, so
  the batch spreads across the library's timeline as the holiday happened.

## 7. Where the code goes

- Kit: `ImportedStills+Classification.swift` — `stemAndTail`,
  `nameSequence`, `findRuns`, `classify` — a port of `classify.py`, tested
  against `cases.py`'s 27 fixtures plus the real five (name lists + gap
  arrays, not the pictures). Pure; no I/O beyond what `probe` already did.
- `lapse classify <folder|files>` — the verdict and the numbers from the
  shell; retires `tools/import-classify/probe.swift`.
- App: the branch in `runStillsImport` after the probe; the batch path;
  the question sheet; `LL_IMPORT_ANSWER`; the synthetic-name flag on the
  Photos-library path.
- Verification: `LL_IMPORT_STILLS=/Volumes/letslapse/Source_SONY/Charles_ARW`
  → the sheet, strangers case, naming `_WEX3518-Rendered.dng`; the same
  folder without it → one `Interval · Imported` of 306 frames, no sheet;
  `…/Exports_testing/china` → 117 `Photo · Imported`, no sheet;
  `…/tram_bouncing` → one shoot of 5030, no sheet; a staged copy of
  Charles with six earlier `_WEX` snaps → the sheet naming the six.

## 8. Open decisions (Steven)

1. Path E as drawn (§4) — confirm. In particular: the sheet on *every*
   multi-file import, or skipped when the reading is clean?
2. No pre-selection when the files disagree (Import inert until a row is
   chosen), versus pre-selecting the likelier row with the warning shown.
   Drawn as the former: it is the "ask", and the cheapest wrong answer.
3. The numbers still shape the default: 60 s (yours), 24 frames as the
   shortest beat that counts, 5 files as the fewest that can be a shoot,
   ±35 % / 0.5 s (1.0 s on whole-second bodies). Less load-bearing now — a
   wrong default is one tap.
4. *Leave these out* on the warning line — v1, or the follow-up (§4)?
5. The batch's landing and Undo (§6): with the sheet as the confirmation,
   is Undo still owed for v1?
6. Design first or code first — the sheet is UI (design-sync applies), and
   it is the first import screen since `create-home.importing`.

## 9. Tools

`tools/import-classify/` (2026-09-15, uncommitted):

- `probe.swift` — `swiftc -O -o probe probe.swift && ./probe <folder> > x.csv`;
  one row per still with the fields the app's probe reads, in the app's
  name order.
- `classify.py` — the reference rule; `python classify.py x.csv…` prints
  the verdict and the numbers per folder.
- `cases.py` — 27 shapes with their expected verdict; exits non-zero on a
  miss. `python cases.py [charles.csv tram_bouncing.csv]` uses the real
  timings when given.

The five probe CSVs are not kept (they are one `./probe` away and the
volume is mounted); the numbers in §2 were read from them on 2026-09-15.

## 10. Verification (2026-09-15, Mac, Debug build)

Against a scratch library root and with PicPlace auto-sync off, so neither
the real library nor the cloud saw any of it:

```
LL_IMPORT_STILLS=<folder> [LL_IMPORT_ANSWER=shoot|photos|cancel] \
  LetsLapse.app/Contents/MacOS/LetsLapse -ApplePersistenceIgnoreState YES \
  -storage.libraryRootPath <scratch>/library -letslapse.picplace.autoSync NO
```

- `Source_SONY/Charles_ARW`, no answer → the sheet: "Charles_ARW · ARW, DNG ·
  SONY ILCE-7M4 · 18 min", no row pre-selected, amber: *306 frames keep a
  3.6 s beat. 1 file doesn't belong: `_WEX3518-Rendered.dng`. Without it
  this folder is a shoot — move it out and import again.* Import inert.
- a clean 30-frame slice of the same, no answer → *Interval shoot ·
  Detected*, pre-selected, no amber; `LL_IMPORT_ANSWER=shoot` → one
  `Interval · Imported` project, 30 frames, `createdAt` 2026-08-31 18:29:27,
  the three sidecars, the blend flow open ("30 photos → 30 frames", 1:45).
- `Exports_testing/china`, `LL_IMPORT_ANSWER=photos` → 117 `Photo · Imported`
  projects, each its own name and 2019 date, Lightroom keywords as chips,
  landed on Projects filtered to *Photos 117*.
- `LL_IMPORT_ANSWER=cancel` → nothing made, the app idle.
- iPhone 16 Pro simulator (a throwaway device beside Steven's): both
  states as on the Mac — full-height sheet, buttons anchored above the home
  indicator. iPad not yet run.
