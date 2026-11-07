# Approved assets and Render Edits

**Built:** 2026-11-05/06, code first (Steven's call), on `ios-app`, uncommitted.
**Signed off:** 2026-11-06, on the running Mac app.
**Verified:** on the Mac build against a scratch library of six real projects,
and displayed in the iPhone Simulator (§8). **Not run:** a sync against a
server, a physical device, an iPad (§9). **Design mirrors:** drawn (§10).
**Server side:** [readia-approved-assets-brief.md](readia-approved-assets-brief.md).

## 1. What it is

A project is a source and what a person made of it. **Approved** is the person
saying which of those is cleared for use downstream. Readia lists approved
assets and lets them be taken into its own Assets.

Several approvals per project are fine: a colour render and a black and white
one of the same clip are two approved assets.

| Project | What can be approved | The file that goes downstream |
|---|---|---|
| Photo, untouched, a format a browser shows (JPEG, PNG, WebP, AVIF, GIF) | The photo | The source file itself |
| Photo, edited, turned, raw or HEIC | The photo, as the editor shows it | A full-size JPEG of the finished picture, rendered by the app and rendered again after every edit |
| Video | The source clip, as it is | The source file itself |
| Video, graded | An **edited clip** (Render Edits) | The render |
| Interval shoot | A blended clip, an image result, a time slice | That output's file |

An interval shoot's source is frames, so the shoot itself is never approved.
A scan is never approved.

## 2. Render Edits

A video project's **Render Edits** renders the clip at 1× with the editor's
edits baked in (look, white balance, level, crop, quarter turns) and **the
sound kept**. The result is an *edited clip*, stored and synced exactly like a
blended clip and listed apart from them.

- It replaces the old workaround of a 1× blend, which re-timed the frames and
  stripped the sound.
- It runs outside the blend flow. The panel shows progress and a Cancel.
- With no edits on the clip the button is dimmed: there is nothing to bake,
  and the source itself can be approved.
- Encoding is the app's existing graded-export pass, unoptimised by decision:
  H.264 High 8-bit at the source's size and rate, the container the source
  used. A 9.6 s 4K clip took 7 s on the M4 Max and came to 55 MB.
- **Photos and interval shoots have no Render Edits.** A photo's approval
  already follows its edits; a shoot's output is a blend.

### The sound fault this found

`CompositionExporter` copied sound only into a QuickTime movie. For an `.mp4`
it gave the writer no format hint, so the writer refused the track and the
copy came out silent, with nothing logged. Every graded `.mp4` export had this
fault (Save to Photos included).

Now the sound is passed through where the container carries the codec as a
player expects it (AAC into `.mp4`, anything into `.mov`) and encoded as AAC
otherwise (a Sony camera's PCM). A copy that still ends up silent logs an
`ALARM`.

## 3. Where it is in the app

**Gallery sidebar.** An **Approved** section between Library and PicPlace: one
row with the number of approved assets. Lit, the grid shows one tile per
approved asset (a project with two approved renders is two tiles; a shoot is
its approved clip). It is a switch like a tag row, so it narrows with Library,
PicPlace, Tags, Shapes and the search.

**Gallery tiles.** A project with anything approved wears the seal in its
top-left corner, in grid mode and in timeline mode. Selection circles take
that corner while a selection is being made.

**The panel** (the pane beside the grid, the item view's left column, and the
phone's ⓘ sheet in the editor): **Output** now sits above Info and Metadata in
every dress. The phone has no Finder button, and its approval captions end
*Tap to remove.* where the Mac's say *Click*.

1. New clip (interval, video) · Render Edits (video) · Share project
2. The project's own approval, for a photo or a video
3. Edited clips
4. Blended clips

Every clip row ends in the approve seal. A row's menu approves it, shows it in
the Finder and deletes it. The footer's Share button went, since Share project
is now in Output in both dresses.

**One glyph:** `checkmark.seal.fill` in the accent. Never green, which is the
holdings pill's "on this device".

## 4. The records

Everything is in `project.json`. All fields are optional, so older documents
read unchanged.

| Field | On | Meaning |
|---|---|---|
| `approvedAt`, `approvedBy` | `capture` | The project's own picture or clip is approved (when, by which device) |
| `approvedFile` | `capture` | The file that stands for that approval, relative to the project folder. Kept current by the app. Absent while a first render is still being made |
| `approvedToken` | `capture` | What `approvedFile` was made from: `source`, or the finished picture's fingerprint. Private to the app |
| `approvedAt`, `approvedBy` | `blends[]` | That output is approved. Its file is `outputFileName` |
| `role` | `blends[]` | `edit` for an edited clip, `picture` for an approved photo's render. Absent on a blend. A string, so a value a later build adds never fails this build's decode |

- An approval is an edit: it stamps `modifiedAt` and rides the next push.
- A `picture` render is the approval's plumbing. `ProjectStore.blends(for:)`
  leaves it out, so no list, picker, hero or holdings line shows it, and the
  index does not count it as a blend.
- The index has `projects.approved_count` (schema 5). A schema-4 database
  gains the column in place, with no rebuild: no document held an approval
  before, so 0 was already true of every row.

### How an approved photo follows its edits

1. Any write of an approved photo made on this device schedules a settle
   2.5 s later.
2. The settle compares `approvedToken` with the picture's fingerprint now (the
   poster's token, so whatever re-renders the poster re-renders this).
3. If it moved, the finished picture is rendered at full size into
   `blends/<new id>.jpg`, `approvedFile` points at it, and the render before
   it is deleted like any blend (to the trash, a tombstone in the manifest).
4. If the edits were reset and the source is a browser format, `approvedFile`
   goes back to the source.
5. A render the app was closed before, or that iOS stopped in the background,
   is tried again six seconds after the next launch.

A device with neither the originals nor a working copy cannot render, and logs
that it could not.

## 5. Sync

Nothing new is asked of the server.

- **The approval** is in the manifest every records push already sends.
- **The file** is a `source/` or `blends/` file the existing uploads carry.
- **An approved output** goes up through the blends queue whatever *Upload
  blends automatically* says, and so does a Photo capture's approved render
  (the queue otherwise never sends a photo's blends on their own).
- **An approved source** gets an upload job, as the card's Upload would make
  one, once the project's records are on the server and in step. It is started
  by the app, never as a person's press, so iOS is asked for no continued
  task. The job waits for Wi-Fi under *Only on Wi-Fi* and survives a relaunch.
  The job sends the project's originals and its blends.

**Removing is not deleting.**

| Action | This device | The manifest | The server's file |
|---|---|---|---|
| The PicPlace card's Remove (free up space) | The file goes | Unchanged: still approved | Kept |
| A clip row's Delete… | To the trash | A tombstone: no longer approved | Kept |
| Remove approval | Unchanged | The approval goes | Kept |

## 6. The Save as Preset prompt

Gone, as the small job asked. Leaving an edited project no longer raises
"Save these edits as a preset?" on any platform, and the Mac's inline card
that stood in the Presets footer is gone with it. **Save as Preset** under the
Presets tiles is the one door. `EditorExitRequest` lost its
`offersPresetSave` field.

## 7. Launch hooks (Debug)

| Hook | What it does |
|---|---|
| `LL_APPROVED=1` | Lights the sidebar's Approved row from launch |
| `LL_APPROVE=<latest\|uuid>:<source\|newest\|blend uuid>[:off][@<s>][;…]` | Approves through `setApproved`, 2 s after launch or at that delay. `source` is the project's own picture or clip, `newest` its newest output. `:off` removes the approval |
| `LL_RENDER_EDITS=<latest\|uuid>[@<s>]` | Presses Render Edits |
| `LL_INFO=1\|large[@<s>]` | iOS, with `LL_ITEM`: presses ⓘ in the editor — the project's sheet at its medium height, or tall enough to hold Output |
| `LL_APPROVED=1 LL_QUERY=<nothing>` | The Approved view's empty state |

The log's `approved:`, `render edits:` and `export:` lines say what happened.

## 8. What was verified

On the Mac Debug build against
`~/Library/Developer/LetsLapseRun/libraries/approved-scratch` (APFS clones of
six projects from `webexpo-local`, no `PicPlace/` folder):

| Check | Result |
|---|---|
| Log video (Sony XAVC S, PCM sound): Cinema preset, Render Edits | An edited clip, 3840×2160, 25 fps, 9.6 s, AAC stereo sound |
| The same before the exporter fix | Silent, and the new ALARM line said so |
| Stock clip approved | `approvedFile` = its source `.mp4` |
| Untouched JPEG approved | `approvedFile` = its source `.jpg` |
| Edited ARW approved | Full-size JPEG (4608×3072) in 4 s, matching the poster's look once the scratch library had the LUT file |
| The ARW turned a quarter turn, then back | Re-rendered each time within 4 s (3072×4608, then 4608×3072); the render before it went to the trash |
| Two interval shoots' blends approved | Approved; a shoot's own source is refused |
| The ARW's approval removed | The fields cleared, its render tombstoned and moved to the trash |
| The graded video's source approved beside its edited clip | Two approved assets from one project; the caption says the edits are not in the source |
| A library opened read-only (another instance held the lock) | The write is refused and the log says *the library did not take the change*; nothing is retired or sent |
| A plain relaunch | Nothing re-rendered: the tokens are stable |
| Sidebar count and Approved view | 6, six tiles: Timelapse ×2, Photo ×2, Edited clip, Video |
| No-server sync dry run on the ARW | The render is classified `heavy:blend`; the manifest carries the approval |
| Kit tests | `LibraryIndexTests` 25 pass (two new: the count's rule, the schema step), neighbouring suites pass |
| iOS Simulator target | Compiles (arm64) |
| Timeline mode (2026-11-06) | Tiles wear the seal, as in grid mode (the timeline grid had left it out) |
| The Approved view with nothing left by the filters | *Nothing approved*, centred above the tab bar |

In the iPhone 16 simulator (iOS 18.6), the same six projects cloned into its
library, 2026-11-06. The approvals were made on the Mac; the phone displayed
them.

| Check | Result |
|---|---|
| Gallery grid | The seal top-left on the five tiles whose projects hold an approval |
| Library sheet | The APPROVED section between Library and Tags, count 6 |
| Approved row lit | Six tiles (Timelapse, Photo, Video, Edited clip, Timelapse, Video); the ▤ button reads accent |
| ⓘ sheet on the graded video | Output above Info: New clip · Render Edits · Share project, the source's approval, EDITED CLIPS · 1 with the seal |
| ⓘ sheet on the ARW | Share project alone, *Approve this photo*, then INFO from the file |
| ⓘ sheet on an interval shoot | New clip · Share project, BLENDED CLIPS · 2, the filter wrapping to two rows, the approved clip's seal |
| The approval caption | Ends *Tap to remove.* (it said *Click* until this run) |

## 9. Not verified, and known limits

- **No sync was run against a server.** A bound bench root needs account
  tokens. The manifest fields and the dry run's classification are verified;
  an approved file actually arriving on Readia or PicPlace is not.
- **Nothing was run on a physical device or an iPad.** The phone's screens
  were seen in the Simulator; no approval was made and no edit rendered
  there. The iPad pane takes the Mac's code and is unseen.
- **Every device needs this build.** An older build drops fields it does not
  know when it writes a project, so an edit made there loses the project's
  approvals. This is true of every new field in `project.json`.
- **Superseded photo renders stay on the server.** Each settled edit of an
  approved photo leaves the previous render's file there (the manifest lists
  it as deleted). The brief asks Readia to retire them.
- **Render Edits in the background on iOS** will fail, as any GPU work does
  there. The panel shows the failure; it is not resumed.
- **A multi-segment video capture** renders its primary clip only, which is
  what the editor opens.
- **8-bit H.264 only.** A 10-bit log clip is rendered to 8-bit. Encoding
  choices are the later optimisation job.
- **Other devices keep a stale copy** of an approved photo's render until they
  download the new one; nothing fetches it for them.
- **The Projects tab** lists edited clips in its one clips list, titled
  *Edited clip N*, with the seal. It has no Output block.

## 10. Design mirrors

Drawn 2026-11-06, after sign-off of the running app, from the Debug build's
own frames (accessibility on the Mac, Simulator captures on the phone). The
per-file record is in each platform's `INDEX.md`.

- **macOS:** 24 Gallery files redrawn — the sidebar's Approved section, the
  tile seals, and the pane and inspector whole (which also drew the
  2026-09-27 reorder and the picture-fitted thumbnail, both overdue). New:
  `gallery.approved.svg` and `gallery.approved.empty.svg`.
- **iOS:** `gallery.portrait.svg` (seals), `gallery.library-sheet.portrait.svg`
  (the section); new `gallery.approved.portrait.svg` and
  `editor-pager.info.portrait.svg` (the ⓘ sheet, drawn for the first time).
- **Components:** `blended-clip-row.*` (the seal on all twelve; new `approved`,
  `edited`, `edited.approved`), `output-actions.*` (new `video`,
  `video.no-edits`, `video.rendering`, `clip.preview`), new
  `output-approval.*`, new `picplace-status.preview-only.narrow`.

Left marked in the indexes: two retired phone mirrors (the Gallery preview
sheet the phone dropped on 2026-09-21), the Mac inspector's PicPlace card
drawn at rest in the six preview files, and no iPad file (none draws the
Gallery).

Drawn at once, because the prompt's removal was an instruction and not a
proposal: `macOS/photo-viewer.presets.svg` and the notes of the seven other
files that described the prompt.
