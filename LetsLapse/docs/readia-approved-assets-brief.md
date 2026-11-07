# Readia: approved LetsLapse assets — the brief

**From:** the LetsLapse app · **Date:** 2026-11-06 · **For:** the Readia developer
**App side:** built on `ios-app`, uncommitted, verified on the Mac against a
scratch library. **No sync against a server has been run yet.**
**Read with:** [approved-assets.md](approved-assets.md) (the app's reference),
and in the Readia repo `docs/letslapse-assets.md` (today's tag-driven
surfacing) and `docs/storage-letslapse-audit/picplace-contract.md` (the API).

## The short version

- In LetsLapse a person can now mark outputs **Approved**: a photo as edited,
  a video's source clip, an edited clip, a blended clip. One project can hold
  several.
- The approvals are **fields in the manifest** the app already PUTs, and the
  approved files are `source` and `blend` assets the app already uploads.
  **No new endpoint, asset kind or feature flag is needed for the app to
  work.**
- Readia's job is to read those fields, list the approved assets at
  `/vue/letslapse/approved`, and let the person take any of them into Assets
  (`/vue/assets`, `/vue/assets/photographs`, `/vue/assets/video`).
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

The signed-in person's approved assets.

- One row or tile per approved asset, not per project.
- Its picture (the file, or the poster while waiting), the project's name, a
  label for what it is (Photo, Video, Edited clip, Timelapse, Image), size,
  length for video, approved when and on which device.
- Waiting items say so, and what will bring them in ("uploads when the
  device is on Wi-Fi").
- Whether it is in Assets, and the action to change that (§3.4).
- A link to the project's page.

### 3.4 Into Assets, by the person's choice

Steven's words: from Readia, a person nominates approved assets for use, and
those appear in `/vue/assets/photographs`, `/vue/assets/video` and the Library
overview. So being approved does not by itself put an asset in Assets.

- An **Add to Assets** action per approved asset, and its reverse. Several at
  once would help: an event shoot can produce dozens.
- The nomination is Readia's own record, not written to the manifest.

### 3.5 Surface one row per approved asset

Today `letslapse_surfaced_items` is unique on `(user_id, project_id)` and
`SurfacedFile::for()` picks the file. For a nominated approved asset:

- The row is keyed by project **and** approval key, so a project with two
  approved renders can be two assets.
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

| Question | Why it matters |
|---|---|
| Do the chosen tags keep putting whole projects into Assets, beside approvals? | The two rules can disagree: a tagged shoot surfaces its newest render, its approval names another. Simplest: where a project holds any approval, only its approved assets can be in Assets |
| Should there be an "add every approved asset to Assets" switch? | The brief assumes a choice per asset, as Steven described |
| Should Readia be able to approve or un-approve? | Not asked for. It would be a manifest write like `ProjectTagWriter`, and for a photo it would have to leave `approvedFile` to the app |

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
| `LL_APPROVED=1` | Opens the Gallery on the Approved view |

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
5. Add an approved asset to Assets, place it in a Studio design, then edit the
   photo in the app. Expect the design to show the new picture.

The app's log says what it did: `approved:`, `render edits:`, `export:`, and
the usual `picplace:` lines for the pushes and uploads.
