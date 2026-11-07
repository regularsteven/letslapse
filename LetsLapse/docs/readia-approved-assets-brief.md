# Readia: approved LetsLapse assets — the brief

**From:** the LetsLapse app · **Date:** 2026-11-07 (first draft 2026-11-06) ·
**For:** the Readia developer
**App side:** committed on `ios-app` as `42f0e34` and pushed; tested by
Steven on the Mac, run in the iPhone Simulator; the design mirrors are drawn.
**No sync against a server has been run yet** — the first joint run is §6.
**Read with:** [approved-assets.md](approved-assets.md) (the app's reference),
and in the Readia repo `docs/letslapse-assets.md` (today's tag-driven
surfacing) and `docs/storage-letslapse-audit/picplace-contract.md` (the API).
**Scope:** everything in §3 is server logic inside Readia. The app is done and
needs nothing back from the server for approvals to work.
**Handover copy:** the same text as a shared doc, for comments —
https://claude.ai/artifact/BCJwPJ4FXgSWJCHGnHKgzC (this file is the source).

## The short version

- In LetsLapse a person can now mark outputs **Approved**: a photo as edited,
  a video's source clip, an edited clip, a blended clip. One project can hold
  several. Approved is an attribute of an **asset** — a source or an output —
  never of a project.
- The approvals are **fields in the manifest** the app already PUTs, and the
  approved files are `source` and `blend` assets the app already uploads.
  **No new endpoint, asset kind or feature flag is needed for the app to
  work.**
- Readia's job, in Steven's words: a route **`/vue/letslapse/approved`** that
  shows a **curated list — the same list the app's Approved view shows** —
  and from it the person **nominates** what they want available inside
  Assets. The server may hold the nominations as a **white-list** of approved
  assets; what is on the list becomes visible in `/vue/assets/photographs`
  and `/vue/assets/video`.
- This answers the open question in `letslapse-assets.md` §8.1: a project now
  says which of its outputs stands for it, so Readia no longer has to guess
  the newest render.

## 1. Why

Steven wants LetsLapse as the capture and editing tool and Readia as where the
finished pieces are used. Until now the only signal was a tag on a whole
project, and Readia picked a file by rule: the newest render, or the original.
That rule cannot say "this clip, not that one", and for a graded log video it
picks the ungraded original whenever the original has synced.

## 2. What the app sends

### 2.1 The fields

All in the project manifest (`PUT /projects/{uuid}` → `manifest`, the app's
`project.json`). All optional; a project without them has nothing approved.

| Where | Field | Type | Meaning |
|---|---|---|---|
| `capture` | `approvedAt` | ISO-8601, ms, UTC | The project's own picture (a photo) or source clip (a video) is approved |
| `capture` | `approvedBy` | uuid | The device that approved it |
| `capture` | `approvedFile` | string | The asset `name` that stands for that approval: `source/…` or `blends/…`. **Absent** while the app is still making a first render |
| `capture` | `approvedToken` | string | Private to the app. Ignore it |
| `blends[]` | `approvedAt` | ISO-8601 | That output is approved. Its file is the record's `outputFileName` |
| `blends[]` | `approvedBy` | uuid | The device that approved it |
| `blends[]` | `role` | string | `edit`: an edited clip (the source at 1× with the edits baked in and the sound kept). `picture`: the render behind an approved photo. Absent: a blend. Treat any other value as a blend |

### 2.2 An example

A graded photo, approved. The app rendered the finished picture and named it:

```json
{
  "formatVersion": 2,
  "capture": {
    "id": "5A00E994-81E2-4302-88C7-BA14416CE932",
    "kind": "photos",
    "mode": "Photo · Imported",
    "approvedAt": "2026-11-05T23:18:29.665Z",
    "approvedBy": "03533CE8-339D-4689-896F-D1DC75FCF25E",
    "approvedFile": "blends/B92D778F-C032-47B0-9870-BFF71EC81D34.jpg",
    "approvedToken": "e6|Original|1.581,…"
  },
  "blends": [
    {
      "id": "B92D778F-C032-47B0-9870-BFF71EC81D34",
      "kind": "image",
      "role": "picture",
      "outputFileName": "blends/B92D778F-C032-47B0-9870-BFF71EC81D34.jpg",
      "width": 4608, "height": 3072,
      "createdAt": "2026-11-05T23:23:25.717Z",
      "summary": "Approved picture · full size · 4608×3072"
    }
  ]
}
```

A graded video with one approved edited clip:

```json
"blends": [
  {
    "id": "451FB45B-71AE-49E1-8379-F4787AE9B524",
    "kind": "video",
    "role": "edit",
    "outputFileName": "blends/451FB45B-71AE-49E1-8379-F4787AE9B524.mp4",
    "width": 3840, "height": 2160, "outputFPS": 25, "outputFrames": 240,
    "approvedAt": "2026-11-05T23:18:27.505Z",
    "approvedBy": "03533CE8-339D-4689-896F-D1DC75FCF25E",
    "summary": "Edits rendered at 1× · sound kept · 3840×2160 · 25 fps"
  }
]
```

### 2.3 The rule: which assets are approved

For one live project:

1. **Its own approval.** If `capture.approvedAt` is set, the project has one
   approved asset with the key `source`. Its file is the project's confirmed
   asset whose `name` equals `capture.approvedFile`.
2. **Its outputs.** Each `blends[]` record with `approvedAt` set, no
   `deletedAt`, and `role` other than `picture` is one approved asset with
   the key of the blend's `id`. Its file is the confirmed asset whose `name`
   equals `outputFileName`.
3. **The kind** follows the file: an image is a photo, a video is a video
   clip.

An approved asset whose file is absent or not yet confirmed is **waiting**
(§2.5).

**Identity.** Key an approved asset by the server's project uuid plus `source`
or the blend id. Use the uuid from the URL, never `capture.id`, which is a
device's own id for the project and can differ. The key survives everything
that should not change what an asset *is*:

- An approved photo is edited: the key stays `source`, `approvedFile` moves to
  a new `blends/<uuid>.jpg`, and the record of the old render gains
  `deletedAt`.
- An approval is removed and given again: the same key returns.

### 2.4 What each kind of approval looks like

| Project | The approval | `approvedFile` / file | Follows edits? |
|---|---|---|---|
| Photo, untouched, JPEG · PNG · WebP · AVIF · GIF | `capture` | The original, `source/…` (or a stack's `blends/….png`) | Yes: an edit moves it to a render |
| Photo, edited, turned, raw or HEIC | `capture` | A `picture` render, `blends/<uuid>.jpg`, full size, JPEG quality 0.95, EXIF and GPS carried | Yes: a new render per settled edit |
| Video | `capture` | The source clip, `source/…`, as shot. Edits are **not** in it | No |
| Video, graded | `blends[]`, `role: edit` | `blends/<uuid>.mp4` or `.mov` | No: a new edit is a new Render Edits |
| Interval shoot | `blends[]`, no role | `blends/<uuid>.mp4`, or `.png` for an image result | No |

So `capture.approvedFile` for a photo is always something a browser can show.
A raw or HEIC original is never named there.

### 2.5 When the file arrives

The approval and its file travel separately, the approval first.

- The approval is an edit, so it moves the project's revision and goes with
  the next records push. The change feed carries it.
- An approved output is uploaded by the app's blends queue even when the
  person has switched automatic blend uploads off.
- An approved source gets an upload job for the project's originals.
- Both wait for Wi-Fi when *Only on Wi-Fi* is on, and for the app to be
  running.

So Readia will see approvals whose file is not there yet, for seconds or for
hours. Show them as waiting. For a waiting photo the project's poster (the
finished picture at 1280 px) is a fair stand-in.

### 2.6 Removing, deleting, withdrawing

| What the person does in the app | The manifest | The file on the server |
|---|---|---|
| Removes the file from a device to free space | Unchanged: still approved | Kept |
| Removes the approval | The fields go | Kept |
| Deletes an approved clip | The blend gains `deletedAt` | Kept (the app never deletes a blend asset) |
| Deletes the project | The project is tombstoned | As today |

The first row is the one Steven asked for by name: an approved asset can leave
the device and stay available on the server.

## 3. What Readia needs to build

In the order the pieces depend on each other.

### 3.1 Index the fields

- `letslapse_project_index`: `approved_at`, `approved_file` (from `capture`).
- `letslapse_blend_index`: `role`, `approved_at` (from each `blends[]` record,
  in `ProjectIndexer::syncBlends`).
- **Leave `role: picture` records out of anything a person reads as "this
  project's renders"**: `blend_count`, the project page's list of renders.
  They are the approval's own file, not something the person made. The app
  hides them the same way.

A re-index of existing manifests is enough; no device has to re-send.

### 3.2 Derive the approved assets

One service that answers, for an account: every approved asset by the rule in
§2.3, each with its project, key, kind, file (or waiting), size, duration, and
when and by which device it was approved. Keep it in step the way `Surfacer`
is today: model events on the sync API's writes, and the ten-minute pass for
anything missed.

### 3.3 The page: `/vue/letslapse/approved`

The signed-in person's approved assets — **the same list the app shows** in
its Gallery under Library ▸ Approved. "The same" means the same set, the same
unit and the same words; the sort and the dress are Readia's.

**The set and the unit.** One tile per approved asset by the rule in §2.3 —
never one per project. A project with a colour render and a black-and-white
render approved is two tiles; an interval shoot is its approved clip(s), never
its frames. A `role: picture` render is never a tile of its own: it is the file
behind the photo's `source` tile.

**What a tile shows in the app**, so the page can match it:

| On the tile | The app | Readia's equivalent |
|---|---|---|
| The picture | A photo as edited (its grade applied); a source clip's own frame; an output's own frame, or its still when the file is not on the device | The approved file; while **waiting** (§2.5) the project's poster for a photo, and for an output its still — `posters/<blend id>.jpg` inside the records bundle each push sends |
| The badge, bottom-left | One of **Photo · Video · Edited clip · Blended clip · Timelapse · Image · Time slice · Time-slice poster** (table below) | The same word |
| The seal, top-left | `checkmark.seal.fill` in the app's accent `#C36A00`. Never green, which the app reserves for "on this device" | A seal, in the accent if the page follows the app |
| The name | The project's title under the grid (on the Mac, in the pane) | The project's name; a link to its page |
| Where the file is | The holdings pill (device / PicPlace) | Ready, or waiting — and what brings it in ("uploads when the device is on Wi-Fi") |

**The badge words**, from `ApprovedAssetTile.badge`:

| The approved asset | Badge | Belongs in |
|---|---|---|
| `source` of a Photo project | Photo | `/vue/assets/photographs` |
| `source` of a video project | Video | `/vue/assets/video` |
| `blends[]` with `role: edit` | Edited clip | `/vue/assets/video` |
| `blends[]` with `timeSlice`, `kind: video` | Time slice | `/vue/assets/video` |
| `blends[]` with `timeSlice`, `kind: image` | Time-slice poster | `/vue/assets/photographs` |
| `blends[]`, `kind: image` | Image | `/vue/assets/photographs` |
| `blends[]`, `kind: video`, project `kind: video` | Blended clip | `/vue/assets/video` |
| `blends[]`, `kind: video`, project is a shoot | Timelapse | `/vue/assets/video` |

So the file's type decides the Assets route — image → photographs, video →
video — and the badge says what made it.

**Order.** The app lists in the Gallery's current sort (the person's choice,
newest capture first by default), and within a project the project's own
approval first, then its outputs newest first. For the page, newest
`approvedAt` first is the natural default; a sort by project name and by
capture date would mirror the app.

**Narrowing.** In the app the Approved row is a switch beside the other
filters: it narrows with the library's search, tags, PicPlace state and media
kind. The page can offer the same — a search box, the project's tags, a
Photographs / Video split — but the first version needs only the list.

**Per tile, beyond what the app shows:** size, length for video, approved when
and on which device (`approvedBy` is a device uuid; `GET /devices` has the
names), **whether it is on the white-list**, and the action to change that
(§3.4).

### 3.4 Into Assets, by the person's choice: the white-list

Steven's model, 2026-11-07: approval is the app's act and means "cleared for
use"; **nomination** is Readia's act and means "use it here". Being approved
puts an asset on `/vue/letslapse/approved`; being nominated puts it in Assets.

- Keep the nominations as a **white-list of approved assets**: a row per
  approved-asset key (§2.3 — project uuid + `source` or blend id), Readia's own
  record, never written to the manifest.
- An asset on the list is visible in `/vue/assets/photographs` or
  `/vue/assets/video` by its file type (table in §3.3), and in the Library
  overview as a surfaced row (§3.5).
- A **Nominate** action per tile on the Approved page, and its reverse.
  Several at once would help: an event shoot can produce dozens.
- Steven has also said the server "may wish to white-list any approved asset"
  — that is, put every approved asset on the list without a nomination. The
  brief treats that as an account-level switch to add later if wanted (§4), not
  the default: the default is the person's choice per asset, as he described
  the flow.
- A nomination outlives the asset's file: if the approval is removed in the
  app the row leaves Assets (§3.5) but the white-list entry can stay, so a
  re-approval brings the asset straight back.

### 3.5 Surface one row per approved asset

Today `letslapse_surfaced_items` is unique on `(user_id, project_id)` and
`SurfacedFile::for()` picks the file. For a white-listed approved asset:

- The row is keyed by project **and** approval key, so a project with two
  approved renders can be two assets.
- It lands in `/vue/assets/photographs` or `/vue/assets/video` by the file's
  type (§3.3), and in the Library overview.
- The file is the approval's file, not a rule's pick.
- When an approved photo is edited, the same Assets row and the same link
  serve the new file. A Studio design or a Producer timeline holding it should
  show the new picture, so the link needs a way past any cache.
- A waiting asset, a removed approval, a deleted clip and a deleted project
  all withdraw the row as a removed tag does today, and it comes back under
  the same id.

Everything else about a surfaced row can stay as `letslapse-assets.md` §4 has
it: no file on Readia's disk, served from Readia's origin, not renamed or
deleted in Assets.

### 3.6 Retire superseded photo renders (smaller)

Each settled edit of an approved photo leaves the previous render in the
bucket, listed in the manifest as a deleted blend with `role: picture`. Nothing
refers to it again. Deleting those objects once the manifest no longer names
them live would stop the bucket growing by a few megabytes per edit. The app
does not need it.

## 4. Decisions for Steven before or while this is built

Settled on 2026-11-07: the unit is the approved **asset** (a source or an
output), the page is `/vue/letslapse/approved`, it shows what the app's
Approved view shows, and the person nominates from it. Still open:

| Question | Why it matters | The brief's default |
|---|---|---|
| Does approval alone put an asset into Assets, or only a nomination? | Steven described nomination as the person's act, and then said the server "may wish to white-list any approved asset". Both can be true: a per-account switch *Add every approved asset to Assets* on top of the per-asset choice | Nomination per asset; the switch is a later addition |
| Do the chosen tags keep putting whole projects into Assets, beside approvals? | The two rules can disagree: a tagged shoot surfaces its newest render, its approval names another | Where a project holds any approval, only its approved assets can be in Assets; the tag rule stays for projects with none |
| Should Readia be able to approve or un-approve? | Not asked for. It would be a manifest write like `ProjectTagWriter`, and for a photo it would have to leave `approvedFile` to the app | No: approval stays the app's act, nomination Readia's |
| Does removing an approval in the app also drop the nomination? | A re-approval could then come straight back into Assets, or need a second nomination | The white-list entry stays; the Assets row is withdrawn while the approval is gone (§3.5) |

## 5. Facts to rely on, unless you say otherwise

- The fields ride the manifest verbatim; the app strips only `sizeBytes` and
  `sizeMeasuredAt` before a PUT.
- `approvedAt` is written in the same ISO-8601 form as `modifiedAt`.
- `capture.approvedFile` always equals an asset `name` the app has uploaded or
  will upload under kind `source` or `blend`.
- A `picture` render's blend id and file name change with every re-render.
  The approval's key (`source`) does not.
- An edited clip is H.264 High 8-bit at the source's size and frame rate, with
  AAC sound (or the source's own AAC), in the source's container: `.mp4` for
  an `.mp4` source, `.mov` otherwise. Measured: 55 MB for 9.6 s of 4K at
  25 fps. An approved source is whatever was shot or imported: a 224 MB stock
  clip went through as it is.
- **Files are large and unoptimised by decision.** Steven has said smaller
  encodes and caching are a later job. Web-friendly copies made on Readia's
  side are Readia's call.
- **An older app build drops these fields.** A device that has not been
  updated and edits a project writes the manifest back without the approvals.
  Readia would see the approvals disappear, and should simply follow. They
  come back when re-approved.

## 6. Testing it together

The app's Debug hooks press the real paths with no hand on the device:

| Hook | What it does |
|---|---|
| `LL_APPROVE=<latest\|uuid>:<source\|newest\|blend uuid>[:off][@<seconds>]` | Approves, or with `:off` removes the approval |
| `LL_RENDER_EDITS=<latest\|uuid>[@<seconds>]` | Renders a video's edits to an edited clip |
| `LL_APPROVED=1` | Opens the Gallery on the Approved view — the list the page should match |
| `LL_INFO=1\|large` (iOS, with `LL_ITEM`) | Opens the phone's project panel, where Output lives |

What has been run so far: the app on the Mac against a scratch library
(approve, re-edit, Render Edits, remove), and the Simulator showing the same
library's approvals. **No push of an approval to any server yet.**

A first joint run, in the "LetsLapse Readia QA" Simulator against
`readia.test`, on throwaway projects only:

1. Import a JPEG, approve it (`:source`). Expect the manifest fields, then the
   original as a `source` asset, then a ready item on the Approved page.
2. Apply a preset to it. Expect `approvedFile` to move to a `blends/….jpg`,
   a `picture` blend record, and the same approved item now showing the
   graded picture.
3. Import a video, apply a preset, `LL_RENDER_EDITS`, then approve `:newest`.
   Expect a `role: edit` blend with sound and one approved video.
4. Remove an approval (`:off`). Expect the item to leave the page and its
   Assets row to be withdrawn.
5. Nominate an approved asset, see it in `/vue/assets/photographs`, place it
   in a Studio design, then edit the photo in the app. Expect the design to
   show the new picture.
6. Nominate an edited clip and see it in `/vue/assets/video`; play it and
   hear the sound.

The app's log says what it did: `approved:`, `render edits:`, `export:`, and
the usual `picplace:` lines for the pushes and uploads.
