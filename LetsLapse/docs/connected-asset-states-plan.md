# Connected asset states — one app, whatever a device holds

**Raised:** 2026-09-25, Steven's brief (§1, verbatim) · **Working mode:**
code first, SVG mirrors after sign-off (Steven, the same day) · **Status:**
mapped against the code (§2); **stages 1–3 built and verified 2026-09-25,
uncommitted** (§9–§11; stage 2 installed on the iPhone 16 Pro, iPhone 18 Pro
and iPad Air M3 as a Release build) — Steven's look owed, then the mirrors
(§8); D1 yes (built in stage 3), D2 deferred; **the holdings pill —
Direction B, Steven's choice — replaces the tile badges (§12)**; **stage 4's
swipe built and measured on the iPhone 16 Pro (§13)** · **Size:**
large, five stages · **Read with:** [picplace-sync-v2-handover.md](picplace-sync-v2-handover.md),
TODO "PicPlace free up space", TODO "Gallery → editor on iOS".

## 1. The brief (Steven, 2026-09-25)

> **Context.** LetsLapse syncs to PicPlace (opt-in). A given device may hold
> some, all, or none of a project's files. Today, a device without the shoot
> sources gets a crippled experience: previews can't be browsed easily and
> the edit view doesn't behave like it does on the capture device.
>
> The goal: **the app looks and behaves the same regardless of what's on the
> device. Only capabilities change.**
>
> **Terminology.** *Shoot sources*: the original captured files from a shoot
> (JPEG, DNG, ProRes, MP4/MOV). Large. *Previews*: lightweight renditions of
> shoot sources, generated client-side. Always synced. *Blend*: a derived
> clip or image made *from* shoot sources with a given configuration (e.g.
> 10:1, 1:1, no blend / plain sequence). Much smaller and portable.
> *Collection*: an edit built from blends: ordering, in/out points, Ken Burns
> moves, transitions.
>
> **Core rules.**
> 1. Blending requires shoot sources. A blend is created only on a device
>    that has the sources.
> 2. Blends are finished artifacts. They aren't edited in place. A different
>    configuration means a new blend. A project can hold many blends, and
>    users choose among them.
> 3. Blends sync at full quality, not as proxies. They're the portable unit.
> 4. Collections need blends only. A collection can be authored *and
>    rendered* on any device that has the blends — never the shoot sources.
> 5. Metadata edits need nothing local. Description, tags, names, and
>    taxonomy work anywhere.
> 6. Pixel edits need shoot sources. Colour, presets, tonal tuning, and the
>    edit profile generally.
>
> **Capability matrix.**
>
> | Device holds | Browse / swipe previews | Metadata edits | Collection authoring & render | Pixel edits | New blend |
> |---|---|---|---|---|---|
> | Previews only | ✅ | ✅ | ❌ (fetch blends) | ❌ | ❌ |
> | Previews + blends | ✅ | ✅ | ✅ | ❌ | ❌ |
> | Shoot sources | ✅ | ✅ | ✅ | ✅ | ✅ |
>
> **UX requirements.** *One UI, no fork:* there's no separate "cloud-only"
> mode; the project view, the edit view, and swipe left/right browsing are
> identical on every device; unavailable capabilities are **greyed out in
> place** (e.g. the edit-view bottom tabs), with a clear reason and no dead
> ends; swiping through previews must be fast and smooth whether or not the
> shoot sources are local. *Two ways to fetch:* (1) deliberate — the user
> fetches blends or shoot sources from the project level, whenever they
> choose; (2) just-in-time — tapping a greyed capability prompts what's
> missing (blend vs shoot sources), its size (a blend might be tens of MB;
> shoot sources can be several GB), and the options **Download and
> continue** or **Stay as is**; declining returns the user to where they
> were, with state intact. *State visibility:* each project and asset shows
> its local state — previews only, blends local, or sources local; download
> progress is visible and non-blocking, and the user can keep browsing while
> files fetch.

### 1b. The rest of the brief (surfaced 2026-09-25, after stage 4)

The brief pasted at the start ended at *State visibility* (above). Steven's
file (`letslapse-connected-asset-states.md`) goes on — status presentation,
the two-question model, the icon set, a blends badge, the Gallery's PicPlace
filters and four open questions — none of which reached the plan until now.
Verbatim:

> ## Status presentation
>
> ### Current state (iOS & macOS)
>
> - **Gallery tab:** no status shown at all.
> - **Projects tab:** partial. A white cloud outline means the originals are not on this device (the project came from PicPlace). A green solid cloud means the originals are on this device and the project is on PicPlace.
>
> The current green cloud covers only one of the four real states, and Gallery shows nothing.
>
> ### Direction
>
> - Status icons appear in **Gallery**, with the same treatment as Projects.
> - **Projects is being retired.** "Projects" is an internal term, and Gallery replaces it over time. Build status and filters for Gallery first. Projects shares the same components until it's removed.
> - Status only applies when the app is **PicPlace connected**. A standalone device shows no cloud status and no PicPlace filters.
>
> ### The model: two questions per shoot
>
> Each photo, interval, or video shoot answers two independent questions:
>
> 1. **Are the originals on this device?** This decides whether pixel edits are possible here.
> 2. **Are the originals on PicPlace?** This decides whether they're safe and fetchable.
>
> |  | Not on PicPlace | On PicPlace |
> |---|---|---|
> | **Not on this device** | Preview only; originals are elsewhere | Preview only; originals fetchable |
> | **On this device** | Here, **not backed up** | Here and backed up |
>
> "Also on other devices" is deliberately **not** tracked. It would require per-device inventory reporting, and it doesn't change any decision the user makes on this device.
>
> ### Icons
>
> Every state has a **distinct glyph**, so the set works in greyscale and for colour-blind users. Colour reinforces the glyph; it never carries meaning alone. All glyphs are standard SF Symbols.
>
> | State | SF Symbol | Colour | Label (VoiceOver / tooltip / filter) |
> |---|---|---|---|
> | Preview only, originals on PicPlace | `icloud.and.arrow.down` | White | Download available |
> | Preview only, originals not on PicPlace | `icloud.slash` | Grey | Not available to download |
> | On device, backed up | `checkmark.icloud` | Green | Backed up |
> | On device, not backed up | `icloud.and.arrow.up` | Amber | Needs uploading |
> | Transferring | Direction glyph (↑/↓) + progress ring | Orange | Uploading / Downloading |
> | Error | `exclamationmark.icloud` | Red | Needs attention |
>
> Rules:
>
> - **All states show on thumbnails**, including the green backed-up state.
> - **Priority when states stack:** error > transferring > base state.
> - Transferring keeps its direction glyph and adds a progress ring, so upload and download stay distinguishable.
> - The "Needs uploading" state gets a warning colour on purpose, because it's the only state where data can be lost.
> - Labels are shared across VoiceOver, macOS tooltips, and filter names, so the icon and the filter use the same words.
>
> ### Blends badge
>
> - A separate badge on **shoot tiles only** (interval and video shoots), since single photos have no blends. It never merges into the cloud icon.
> - Glyph: `square.stack` with a count.
> - White means blends are on PicPlace only. Green means at least one blend is on this device.
>
> ## Gallery library filters
>
> The Gallery sidebar (left column on macOS and iPadOS, slide-out drawer on iPhone) currently holds **LIBRARY, TAGS, COLLECTIONS, SHAPES**.
>
> - Add a **PICPLACE** section, shown only when the app is PicPlace connected.
> - One shared filter component serves Gallery (and Projects until it's retired).
> - Every icon state is filterable, and filter labels match the icon labels.
>
> | Filter | Shows |
> |---|---|
> | All | Everything |
> | On this device | Originals local; pixel-editable here |
> | Download available | Preview only; originals on PicPlace |
> | Not available to download | Preview only; originals not on PicPlace |
> | Needs uploading | Originals local, not backed up |
> | Has blends | Shoots with one or more blends |
> | Syncing / Needs attention | Transferring or in error |
>
> ## Open questions for the developer
>
> - Blend selection: when a project has several blends, how does a collection pick one, and what's the default?
> - Partial fetch: can a single blend be fetched without all of the project's blends?
> - Eviction: can users free space by removing local shoot sources while keeping blends, and how is that exposed?
> - Collection render output: does the rendered collection sync back as its own asset?

**The brief's words in the app.** *Shoot sources* are what the app's UI
already calls **originals** (the card's *Download originals*, Settings'
*Remove originals already on PicPlace*) — the UI keeps that word. A
*preview* is `poster.jpg` (the project's graded poster, 1280 px) and
`posters/<blend id>.jpg` (a blend's still). A *blend* is a `BlendProject` and
its file under `blends/`. A *collection* is a `LapseCollection`.

## 2. What the app does today (2026-09-25, `1fb746e`)

Mapped by reading, not running; line references are to that commit.

### 2.1 The rules

| Rule | Today | Verdict |
|---|---|---|
| 1 Blending needs sources | Every creation path needs every source frame (`source(for:)` throws on the first missing one, `AppModel.swift:8589`); New blended clip / Guided clip dim without them. Live Blend's averaged windows ARE the sources — no configuration below the capture depth exists. | ✅ (dims give no reason) |
| 2 Blends are finished | Every render is a new `BlendProject` with a fresh id; no path rewrites a blend's file. Records do move: Rotate 90° turns old blends at display (and collections gain `q<n>`), a collection's *replace default crop* edits `defaultCrops`. The JPEG Photo stack is **graded live** in the editor. | ✅ files · note the records |
| 3 Blends sync at full quality | Uploaded as the real files — but only **with the originals** (the card's Upload, Settings' Upload, the originals queue, off by default). No blends-only path, no per-blend still at push (`posters/<id>.jpg` is made only when a blend is removed). | ⚠️ |
| 4 Collections need blends only | Authoring and render read blend files only — never sources, never the grade (`CollectionExporter`). But collections **don't sync** (`Collections/collections.json` is library-level, not in any bundle), take video blends only, and nothing checks a member's file: the picker offers absent blends with blank tiles, an export fails late and whole. | ⚠️ |
| 5 Metadata anywhere | Rename, tags and the IPTC record work on a preview — where they can be reached: on an iPhone a single preview's IPTC fields cannot be (the ⓘ sheet lives in the pager, which a preview never enters). | ⚠️ reach |
| 6 Pixel edits need sources | The editor refuses a preview (`editorAsset`, `EditorLaunch.swift:112`) — but **presets apply without sources** from the Gallery panel, the batch panel and the project's chip strip (`applyPreset`, `AppModel.swift:10738`): the grade changes and syncs, the poster cannot be re-rendered, and the device with the sources can adopt the stale poster. | ❌ |

### 2.2 The UX

- **A fork, not one UI.** A tap on a preview's tile opens the project screen,
  not the editor (`GalleryView.swift:914-929`); a swipe that lands on a
  preview **closes the pager** (`EditorPager.stage`, no message); on the Mac
  the filmstrip and ←/→ stall on it and `LL_ITEM=<preview>` does nothing.
  The editor's tabs are never drawn greyed because the editor never mounts.
- **Dimmed without a reason, and dead ends:** the hero (no Edit, no play,
  *ORIGINAL · N photos* still on it), New blended clip / Guided clip, a blend
  row's Open, the Originals section (Review, Stabilise, *View all photos* →
  grey placeholders, *Save all to Photos* → an error), the tile menu's Edit
  (silent) and New blended clip (an error), Share project (an alert with no
  way forward), *Duplicate as DNG archive* (not checked at all).
- **Swiping is slow even with the sources here:** each settle unmounts one
  editor (a blocking library flush) and mounts the next (grade, overlays,
  shape register, fonts, Lightroom sidecar read on the main thread), then a
  2000 px decode — a RAW demosaic for a DNG — on a single-lane queue; the
  neighbours are 480 px thumbnails, prefetched one page each side only after
  a page mounts; and the pager **grades a preview's poster a second time**.
- **Fetching:** deliberate only — the PICPLACE card's *Download originals*,
  its Blends line, a blend row's Download (which fetches **every** blend of
  the project). No just-in-time prompt anywhere. A pulled JPEG Photo cannot
  fetch its picture: the stack is a blend, the card hides a Photo's Blends
  line and *Download originals* asks for sources only.
- **State:** one boolean per project (`sourcesMissing` — any missing frame
  means all missing; `isPreviewOnly` adds "PicPlace knows it"), uncached for
  a missing project, not observable, not in the index. Shown only as a grey
  cloud on the Projects card; nothing on Gallery tiles or the filmstrip; no
  "blends here" at all. Sizes of what is missing are known offline —
  `assets.ndjson` carries every frame's and blend's bytes — but nothing reads
  them for this.
- **Progress:** downloads run in the background (non-blocking) but a
  preview's originals download **shows no progress**: `state(for:)` answers
  *preview only* before it looks at progress (`PicPlaceController.swift:1529`
  vs `1532`) and `originalsStatus` returns nil while a download runs. The
  Project Syncing drawer shows no downloads. iOS suspends a big one.

## 3. The model

### 3.1 Holdings — what this device holds of a project

`ProjectHoldings` (Kit, pure, tested): from one walk of the project folder,
the project's listed assets and `assets.ndjson`'s sizes —

- **originals**: files listed / here, and the recorded bytes of the missing
  ones (video clips count as here when any of their encodings is);
- **each blend**: here or not, with its recorded bytes;
- **the picture** a Photo capture is edited on: its stack when it has one
  (a JPEG burst), else the photo;
- **a preview**: `poster.jpg` is here.

The **tier** a person reads — **Originals here** · **Blends here** ·
**Preview only** — follows from it: originals when pixel edits can happen
here, blends when at least one blend's file is here, preview otherwise.

`AppModel` keeps one per project, computed off the main actor and published
(`holdingsRevision`), dropped by `noteFilesChanged(for:)` — the one call
every file-changing path already makes (a registration, a delete, a new
blend, an encoding, a rotation, a removal, a pull, a download's end).

### 3.2 Capabilities — the one question every control asks

```
model.availability(of: .pixelEdit, for: capture) → .available | .needs(Shortfall)
```

| Capability | Needs | Doors |
|---|---|---|
| `browse` | nothing (the preview) | tiles, pager, item view, hero |
| `metadata` | nothing | ⓘ / inspector: rename, tags, IPTC, notes |
| `pixelEdit` | the originals (a Photo capture: its picture) | the six groups, Text, Frames, Masks, presets anywhere, Rotate 90°, Auto rename's Stage A read |
| `newBlend` | the originals | New blended clip, Guided clip, *from these settings*, time slicing, Shape-mation's source frames |
| `frames` | the originals | Originals section: View all photos, Review, Stabilise, Save all to Photos |
| `blend(id)` | that blend's file | a blend row's play / Open, Result screen share, a collection member |
| `exportProject` | originals and every blend | Share project (`.lapse`), nearby transfer, DNG archive |

A **shortfall** names what is missing (originals / which blends), how many
files and how many bytes, and whether PicPlace can supply it (signed in,
connected, the project known there). Every greyed control reads the same
answer; none keeps its own file check.

## 4. The UI

### 4.1 The editor on a device without the originals — the preview page

The Gallery (iOS pager, iPad pane, Mac item view + filmstrip + ←/→) opens a
preview-only project **where the editor would be**: the editor's own
chrome and layouts (phone foot / iPad floating row / rail), its tab pill
and six main buttons **drawn greyed in place and still tappable**, over the
project's graded preview (`poster.jpg` as it is — never graded again). A
line over the buttons says why: *Preview · the originals are on PicPlace —
2.4 GB*. ⓘ works (metadata anywhere); clear preview and swiping work; the
page reports `canPage`, so a swipe walks straight through previews.

It is **its own view** (`EditorPreviewPage`), built from the editor's
components (`EditorTabPill`, `EditorGroupBar`, `RailTabBar`,
`EditorMarqueeBadge`, the chrome discs) with a *locked* state added — never
the editor mounted on a poster. The editor has write paths that assume a
source (the 2 s persist net, the white migration that persisted a D65 guess
on 2026-09-23, as-shot reads, the Lightroom sidecar); a page with no write
path cannot repeat that.

### 4.2 Just in time — the prompt

A tap on a greyed control asks, in place:

> **Download the originals?**
> Light needs this shoot's originals — 412 files, 2.4 GB on PicPlace. You
> can keep browsing while they download.
> [Download and Continue] [Stay as Is]

*Stay as Is* returns to exactly where the person was. *Download and
Continue* starts the download (a person's press: any network, as every
download is today), turns the page's line into progress (*Downloading the
originals · 812 MB of 2.4 GB* · Stop), and when the last file lands **opens
what was tapped** — the editor replaces the preview page on its page, with
the Light panel open — if the person is still on that project. Moved on,
nothing jumps: the project simply has its originals when they come back.

When PicPlace cannot supply it the prompt says so and offers what can be
done — *Sign in to PicPlace* (to the Settings card), or *The originals are
only on the iPhone that shot them — they haven't been uploaded to PicPlace
yet* with OK. Never a dead end, never a silent refusal.

### 4.3 State, everywhere

- **Tiles** (Gallery, Projects card, filmstrip) — **the holdings pill**
  (Direction B, Steven 2026-09-25, §12; it replaced the stage-2 badges,
  which hid the norm and left "synced" and "backed up" looking the same):
  one pill, two halves. Left, this device: nothing (the project only —
  records and preview), a camera (every original), layers (blends), both,
  a ring while originals come down, an orange triangle when they are
  neither here nor on PicPlace. Right, PicPlace: nothing (not there), a
  cloud (there), a green cloud-check (everything heavy here verified there),
  amber while sending, the failure tint when a sync failed. A library never
  connected to PicPlace shows only what is not the norm.
- **Per asset:** blend rows wear the same pill for one clip (layers when its
  file is here | PicPlace) and keep their *On PicPlace* line / Download;
  frames follow their project.
- **Progress** is non-blocking and shown where it belongs: the preview
  page's line, the tile's ring, the project card (fixed: progress before
  *preview only*), and the Project Syncing drawer's list of transfers.

## 5. Decisions

**Taken while building (overturn any):**

- **T1** The UI says *originals*, as it already does, for the brief's
  shoot sources.
- **T2** Every editor page but ⓘ needs the originals: the six groups, Text,
  Frames and Masks — and presets from anywhere, and Rotate 90° (a turn
  re-renders the poster, which needs the source).
- **T3** A Photo capture is edited on its picture: the stack when it has
  one, else the photo. Its *Download originals* brings both (the stack was
  unreachable).
- **T4** Part of the originals is not the originals: pixel edits and new
  blends need every file; the prompt offers the rest (*12 files, 70 MB*).
- **T5** ~~Tiles badge *Preview only* and *Blends here*; *Originals here* is
  said in words on the ⓘ sheet and the card.~~ **Superseded** by Steven's
  choice of Direction B, the holdings pill (§4.3, §12): his four states
  (project · + originals · + blends · both) had to be readable on every
  tile, and "synced" had to look different from "backed up".
- **T6** The preview page is its own view, never the editor on a poster
  (§4.1).

**Open — Steven's:**

- **D1 Blends travel on their own — YES (Steven, 2026-09-25).** Rule 3
  makes blends the portable unit, but today a blend reaches PicPlace only
  with the originals. Each blend uploads as it is rendered (with a still),
  under the same Wi-Fi rule as records. Cost: the library's 147 blends are
  13.4 GB, ~90 MB each. Built in stage 3.
- **D2 Preview size — DEFERRED (Steven, 2026-09-25).** `poster.jpg` is
  1280 px: sharp on a phone, soft full screen on a 13″ iPad or the Mac.
  Steven plans a server-side pipeline instead of a bigger poster: PicPlace
  keeps one high-quality, high-resolution master (an HQ JPEG or similar) and
  derives a rendition per device in a light, disposable distribution format
  (HEIC / AVIF / WebP). Deferring saves re-rendering and re-pushing every
  poster twice. What to design around: the master is rendered on a device
  that holds the originals (the look is the grade applied to the source —
  the server can resize and transcode, never regrade, so a settled grade
  change re-uploads the master, as the poster token does today); every
  client is Apple — HEIC decodes in hardware everywhere, AVIF compresses
  best (ImageIO decodes it on the iOS 17 / macOS 14 floor) but is slow to
  encode, WebP buys little; keep the grade's colour space; key renditions by
  content hash and size so a device can drop and re-fetch them freely. Until
  then every reader of the preview goes through one accessor
  (`AppModel.previewPictureURL(for:)`), so the switch is one change.
- **D3 Collections travel.** A collection exists only on the device that
  made it (rule 4's "any device that has the blends" holds for new
  collections only). Syncing them needs the server's account-level record
  (`PUT /library`, an open ask). *Recommended: stage 5.*
- **D4 Stills in collections.** A Photo project contributes nothing to a
  collection today. When stills join, a still member should point at a
  blend (a full-quality graded rendition) so rule 4 holds. *Recommended: a
  job of its own.*
- **D5 Blend records that move.** Rotate 90° turns old blends at display and
  a collection's crop edits `defaultCrops` — records, not pixels. *Recommended:
  keep; rule 2 is about pixels.*

## 6. Stages

1. **One UI — built 2026-09-25 (§9).** `ProjectHoldings` + tests; the capability
   function; `EditorPreviewPage` on phone / iPad / Mac; the Gallery, pager,
   iPad pane, Mac item view, filmstrip and ←/→ open previews; the
   just-in-time prompt with *Download and Continue* for the originals;
   progress on the page and on the card (the ordering fix); a Photo
   capture's picture downloads with its originals; presets and Rotate 90°
   gated with the prompt; the pager's double-graded poster fixed; the
   scratch hook below.
2. **State everywhere — built 2026-09-25 (§10).** Tile badges and rings (Gallery, filmstrip,
   Projects); the ⓘ / inspector *On this iPhone* line; the project screen's
   reasons and its dead ends (Originals rows, New blended clip, Guided clip,
   Share project, DNG archive, the blend menu) through the prompt; downloads
   in the Project Syncing drawer.
3. **Blends as the portable unit — built 2026-09-25 (§11).** A single blend's download; the prompt
   on a blend's play / Open and in the collections picker and export;
   blend stills at push time; blends upload on their own (D1).
4. **Previews.** The server-side master and per-device renditions (D2,
   deferred — Steven's pipeline); swiping on the capture device —
   look-ahead decode of the neighbours, the editor's main-thread mount work
   — **the swipe built 2026-09-25 (§13)**.
5. **Beyond.** Collections travel (D3); background downloads (the iOS
   background session, with the uploads plan); stills in collections (D4).

## 7. Hooks and testing

- `LL_DROP_SOURCES=<uuid|latest>[:originals|blends|all]` (DEBUG, scratch
  roots only): renders the preview a push would (`poster.jpg`, blend
  stills), then deletes the heavy files — a genuine preview-only project on
  a machine with no server. Never on a real library.
- The existing `LL_PICPLACE_REMOVE` / `LL_PICPLACE_DOWNLOAD` on a bound
  scratch root (`tools/picplace-bench/`, throwaway projects,
  `LL_PICPLACE_TOKENS` always) exercise the real round trip: remove the
  originals, open the preview page, press a greyed control, *Download and
  Continue*, watch the progress, land in the editor on that panel.
- Kit: `ProjectHoldingsTests`.

## 8. Mirrors owed after sign-off

`iOS/project-photo.viewer.preview.portrait.svg` (the preview page: greyed
pill and buttons, the reason line), its prompt and downloading states,
`iPadOS` floating and `macOS/gallery.item.preview.svg` (the rail), the
holdings pill (a `components/holdings-pill.*` set — its states in §12 — which
retires `components/picplace-pill.*`), the Gallery tiles and Projects cards
that wear it, the blend rows' pill, and the project card's progress rows.
INDEX rows go 🟡 when stage 1 lands.

**Drawn 2026-09-26** in the §16 scheme — see §16 ▸ *Mirrors*, and the design
INDEX notes of that date.

## 9. Stage 1 — what landed (2026-09-25, uncommitted)

**The model.** `Kit/…/Library/ProjectHoldings.swift` (9 tests,
`ProjectHoldingsTests`): originals by logical name (a converted clip is here
while any encoding is), each blend, a Photo capture's picture (its stack),
the preview; `tier`, `pictureNeed`, `shortfall(for:)` with the files and the
recorded bytes (a floor when a size was never recorded).
`App/ProjectAvailability.swift`: the per-project cache (`holdingsCache`,
walked off the main actor by `loadHoldings(for:)`, dropped by
`noteFilesChanged` — and by the pull and keep-both paths, which cleared the
frame ticket without it), `ProjectCapability`, `availability(of:for:)` (the
whole answer, for a tap) and `isAvailable(_:for:)` (cheap, for a view body).

**The preview page.** `App/EditorPreviewPage.swift`, over the new
`EditorAsset.preview` (`stageEditor(…, allowsPreview: true)`, which the
Gallery's own doors pass): the phone foot, the iPad floating row and the rail,
from `EditorTabPill` / `EditorGroupBar` / `RailTabBar` with a new `locked`
state (greyed, still tappable, hint *Needs the originals*); the status card
says the tier and why (*Preview only — Editing needs the full-size photo — on
PicPlace · 1 file · 3,2 MB · Download*), turns into progress while a download
runs (*Downloading the full-size photo — 3,2 MB to download · Light opens
when it is here · Stop*), and says so when nothing can be fetched (*The
originals aren't on this iPhone*). When the picture arrives while the page is
up — by any door — the real editor takes the page on the page and panel that
was tapped (`EditorPageRequest.group` → the editors' `pendingPanel`).

**Everywhere the editor opens.** The iOS pager stages previews instead of
closing (a swipe walks straight through them); the Gallery's tap, the tile
menu's Edit, the iPad pane and the camera's recent tile open them; the Mac's
item view, filmstrip and ←/→ walk them; `EditorCover` presents one.

**The question.** `App/FetchPrompt.swift`: `FetchNoun` / `FetchPromptContent`
(the words, shared with the page), `FetchPromptRequest` +
`model.request(_:for:subject:then:)` + `.fetchPrompt(_:)` (the tap carried out
once the files are here, while the asker is on screen).
`App/PicPlace/PicPlaceFetch.swift`: `FetchOffer` (download · downloading ·
sign in · connect · not uploaded yet · unavailable) and `fetch(_:shortfall:)`.
Wired: the Gallery panel's Edit (opens the page) / Text / Shapes / New clip /
presets / Share project, the project screen's chip strip and Rotate 90°, the
batch panel's presets (projects without originals are skipped and counted),
the tile menu's New blended clip.

**Fixed on the way.**

- A preview's download showed no progress: `state(for:)` and `listState` now
  answer the download before *preview only*.
- A pulled JPEG Photo could not fetch its picture (the stack is a blend):
  its *Download originals* brings `[.source, .blend]`.
- A blend row's Download fetched every blend of the project: now that blend
  (`PicPlaceDownloadRun.only`).
- The pager graded a preview's `poster.jpg` a second time.
- **The editor's first open of a never-graded project was an edit**: the
  grade write compared the raw fields (all absent) with the editor's
  resolved defaults, stamped `modifiedAt` and synced — one per project the
  pager walked. `AppModel.write(preset:…)` compares resolved values now.

**Verified.** Mac (Debug, scratch root, no server): the item view on a photo
and an interval preview, ←/→ from a preview through the photo and video
editors and back; the iPhone 17 Pro Simulator (throwaway, deleted): the pager
on a preview, a swipe from a real editor onto one, the interval's page with
its *INTERVAL · 20 frames* badge, the *unavailable* prompt. **The round trip
on the bench** (picplace.test, throwaway account `letslapse-two`, a fresh
bound root, a throwaway photo with random bytes appended): upload → *Remove
originals* → the Mac item view → Light → *Download the full-size photo?* →
*Download and Continue* (pressed by AX) → the file down, hash-checked → the
editor on Light; again under `LL_PICPLACE_TRANSFER_OUTAGE` (three failed GETs,
retried, the progress line on screen, then Light); and **the Simulator as the
second device**: linked to the same library, the project pulled as a preview
(*1 heavy file stays on PicPlace*), the phone pager → the prompt → the
download → the phone editor with the Light panel open. The never-graded
first open: 10 s in the editor, the grade fields still absent. Bench
cleaned: the project tombstoned (PicPlace purged it), the token revoked, the
bound root and the Simulator deleted. `letslapse-two` still holds 37
projects from earlier bench sessions and the empty library *assets-bench* —
`printf 'letslapse-two\n' | php artisan letslapse:wipe-account letslapse-two`
clears them.

**Hooks (DEBUG).** `LL_DROP_SOURCES=<latest|uuid>[:originals|blends|all]`
(scratch roots / the Simulator only; run it in one launch, look in the next),
`LL_PREVIEW_PROMPT=<group>|text|frames|masks|line[:download]`.

**Owed from stage 1:** Steven's look (phone, iPad, Mac); the mirrors after
sign-off (§8); the project screen's hero still draws a preview's poster with
no Edit pill (stage 2 gives it the pill → the preview page); the Mac's detail
screen has no window for a preview page (`EditorOpenRequest.open(with:)`
ignores `.preview`; nothing asks for one yet).

## 10. Stage 2 — what landed (2026-09-25, uncommitted)

**The badge** (superseded the same day by the holdings pill, §12).
`App/HoldingsBadge.swift`: the PicPlace pill's dress (22×18,
black 50 %) — a cloud for *Preview only*, a stack for *Blends here*, an amber
ring while the originals come down, a warning triangle when the project is
not on PicPlace either (its files are simply missing); nothing for
*Originals here*. On every Gallery tile (bottom-trailing), the Mac filmstrip
(scaled), and the Projects card, where it takes the PicPlace pill's seat for
a preview or a download. Tiles ask through `requestHoldings(_:)`, gathered
for 80 ms so a grid scrolling in is one walk off the main actor.

**In words.** The Gallery panel, the ⓘ sheet and the Mac inspector gain a
**Here** row under Storage: *Originals and blends* · *Originals · 1 of 3
blends* · *Blends only (2 of 3) — originals on PicPlace* · *Preview only —
originals on PicPlace · 2.4 GB* · *… — originals missing*.

**The project screen, one UI.** The hero of a preview reads *PREVIEW · 20
photos* / *PHOTO · PREVIEW* (it read ORIGINAL over the poster) and carries
the Edit pill again, which opens the preview page — a cover on iOS, a window
on the Mac (`PreviewEditorWindowRequest`, which `EditorOpenRequest.open(with:)`
now opens for `.preview`). Every control that needs files stays in place,
greyed, and asks (`.fetchPrompt`): New blended clip, Guided clip, the
Originals section's View all photos / Save all to Photos / Review, Share
project, Duplicate as DNG archive, a blend row's play (that blend) and Open
(the originals), the blend menu's Open, *New blended clip from these
settings* and Add to collection (that blend). A video's clips on PicPlace
keep their section — one row, *The clips aren't on this iPhone · Tap to
download them* — where the section vanished. `BlendedClipRow` no longer
swallows the tap on a missing clip or a greyed Open: its parents ask.

**Progress in the drawer.** Project Syncing gains a *Downloading from
PicPlace* block beside the uploads: each download's project, bar, *N of M
files · X of Y* and **Stop**.

**Verified.** Mac (Debug, scratch root): the grid's badges, the pane's greyed
action row, the project screen of a preview (PHOTO · PREVIEW, the Edit pill →
the preview window, the greyed chips), New blended clip on an interval
preview pressed by AX → *The originals aren't here — A new blended clip needs
the originals, and they aren't on this Mac or on PicPlace.* iPhone 17 Pro
Simulator (throwaway, deleted): the grid's badges, the interval preview's
project screen (PREVIEW · 20 photos, the Edit pill, New blended clip and the
Originals rows greyed in place). Not driven: the drawer's downloads block and
the badge's ring (a download on the bench — stage 1's run showed the page's
progress; the ring reads the same `progress[id]`).

**Owed from stage 2:** the mirrors after sign-off — a `components/holdings-badge.*`
set, the Projects pill's holdings states (`components/picplace-pill.*`), the
panel's *Here* row (`components/metadata-info.*`), the project screen's
preview state (`iOS/project-detail.*.preview.portrait.svg`), the drawer's
downloads block (`iOS/projects.sharing.downloads.portrait.svg`).

## 11. Stage 3 — what landed (2026-09-25, uncommitted)

**Blends go up on their own (D1).** `PicPlaceSyncPolicy.blends` sends
`blends/` alone (`sendsHeavy(kind:)`). The **blends queue**
(`PicPlaceAutoSync.runBlendsQueue`) walks the library newest first, one
project at a time, under every rule an automatic send keeps (auto-sync, *Only
on Wi-Fi*, Low Power Mode, a shoot being written, the drawer's Pause) and the
new per-device, per-library switch **Upload blends automatically** (Settings ▸
PicPlace, on by default — `PicPlaceLibrarySettings.Switches.autoBlends`, nil in
older files). It waits for the records to be in step (a project that moved is
the push queue's; its blends follow), skips a project whose whole heavy set is
verified there (`heavyDigest`) or whose blends were seen there last time
(`PicPlaceSyncRecord.blendsDigest`), reads PicPlace's list once otherwise,
and sends only what is missing. Armed wherever the originals queue is (after
sends, after each check, on a switch or network change). A blends run leaves
the originals' bookkeeping alone — `heavyDigest` (the removal gate), the
counts of what stays here, a pull's own policy — and a blends failure never
makes the records look unsent (`failedHeavyOnly`, beside the originals').
*A Photo capture's stack is its picture and travels with the originals (T3),
never on its own.*

**A still for every blend at push time.** Every records push makes
`posters/<blend id>.jpg` for each blend here that lacks one, so it rides the
records bundle: a device that pulls the project shows every blend row with a
picture. *Known limit:* a blend made before this build gets its still at its
project's next edit (a still alone moves no revision, so no device re-reads
the bundle for it).

**One blend at a time.** `downloadOriginals(_:kinds:only:)` (stage 1) is the
blend row's Download, the collection's, the picker's.

**Collections on a device that may not hold the clips** (rule 4,
`App/CollectionAvailability.swift`): the builder keeps every member in place
with its still and a cloud where the play glyph was; a banner over the
timeline says *1 clip isn't on this iPhone — Playing, trimming and exporting
need them here · 410 KB — Download*, then *Downloading from PicPlace…*; a
play, a trim / start point and **Export** ask first (*Download this clip? —
Exporting needs the clip — it's on PicPlace · 410 KB …*, **Download and
Continue** exports once the last clip lands); the **Add clips** picker shows a
missing clip's still badged ON PICPLACE and asks before it joins
(`.fetchPrompt`), picking it once it is here. Sizes come from `assets.ndjson`,
else PicPlace's own list (read as the banner appears).

**Verified.** Mac, scratch root (no server): a collection whose clip's file
was dropped (`LL_DROP_SOURCES=<uuid>:blends`) — the banner, the still and
cloud on the row and the preview, Export pressed by AX → *This clip isn't
here*. **The bench** (picplace.test, `letslapse-two`, library
*assets-bench3*): device A registered a video, pushed; a blend added (as a
render would, with random bytes) → the launch check pushed the records with
the blend's still in the bundle (2 members), then **the blends queue sent the
blend alone** (1 file, 410 KB; the source stayed, originals off) — record:
policy still *minimal*, `heavyDigest` nil, `blendsDigest` set, counts kept.
Device B (a second library linked to the same server library) pulled the
project as a preview **with the blend's still**, seeded a collection from the
blend, the banner's Download → *Download this clip?* → **Download and
Continue** (AX) → the blend alone came down (410,465 bytes, no source), the
banner went, the row plays. Cleaned up: the project tombstoned, the token
revoked, both bench roots deleted. Mac and iOS Simulator builds clean.

**Owed from stage 3:** the mirrors after sign-off — the Settings row
(`components/picplace-account.signed-in.phone.svg`), the collection builder's
missing-clip states (`iOS/collection-detail.*`, the picker
`iOS/collection-picker.portrait.svg`, `macOS` collections); per-blend
presence (which device holds which blend — the server's presence is
per-project today); collections themselves still don't travel (D3).

## 12. The holdings pill — Direction B (2026-09-25, uncommitted)

**Why.** Steven's 18 Pro screenshots of one photo (*Photo 25. 9. at 11:26*):
just captured — no badge; synced — the green cloud-check; original uploaded —
the same green cloud-check; original removed — no badge at all. Two moments
looked alike, one lost its badge, and his four states (a project here · +
originals · + blends · both) could not be read anywhere. Three directions
were drawn over six moments; **Steven chose B** and asked for it on **both
the Gallery and Projects tabs**.

**The pill** (`App/HoldingsPill.swift`, in the old PicPlace pill's dress — 18
high, black at 50 %): left half from `ProjectHoldings`, right half from the
PicPlace record, a hairline between. Gallery tiles bottom-right, Projects
cards top-right (the old `PicPlacePill` seat — that pill and `listState` are
gone), the Mac filmstrip at 0.8.

| Moment | Pill |
|---|---|
| Just shot (not on PicPlace yet) | camera |
| Synced (records on PicPlace) | camera \| cloud |
| Backed up (originals verified there) | camera \| green cloud-check |
| Freed up (originals removed here) | green cloud-check |
| Blends only | layers \| green cloud-check |
| A new blend not yet up | camera layers \| cloud |
| Downloading | ring \| cloud-check |
| Sending / failed | … \| amber arrow / failure tint |
| Files gone, not on PicPlace | orange triangle |

Rules: *camera* is the tier (`.originals`) — every original, a Photo
capture's picture counting as its original; *layers* is a blend here other
than that picture (the glyph is `square.3.layers.3d` — `square.stack` is the
Projects tab's own); the **green tick** = the heavy set's marker
(`heavyDigest`) matches what is here now (`ProjectHoldings.localHeavyDigest`,
path and size, the digest of nothing when nothing heavy is here), or — with
nothing heavy here and no marker (a pull) — PicPlace holds originals
(`serverHeavyFiles`). A library never connected shows only layers / the
triangle. `HoldingsPillState` + `AppModel.holdingsPillState(for:holdings:)`
are the one reading; `isBackedUp(_:holdings:)` is shared with the Gallery
panel's **Here** row, whose words now say the same (*Originals · backed up on
PicPlace* / *not backed up*; *originals on PicPlace* only when PicPlace holds
them, else *originals not on PicPlace yet*).

**Blend rows** (`BlendedClipRow` — the project screen and the Gallery panel)
wear `BlendHoldingsPill`: layers when the clip's file is here | PicPlace from
its own entry in PicPlace's list when a card has read it (`serverHeavy`), else
the markers (the whole set, or every blend here — `localBlendsDigest` against
`blendsDigest`), else a cloud for a clip that is not here. The collection
builder keeps its own ON PICPLACE / cloud marks (stage 3).

**The tick stays true** — changes to the blends queue
(`PicPlaceAutoSync.runBlendsQueue`): a project whose originals went up (or
were seen there — `heavyDigest` or `originalsMovedAt`) is checked **whole**,
so a set that only gained a blend is marked backed up again once the blend is
there (checked again right after the queue sends it), and one PicPlace was
still reading back when its upload ended is marked when it has — the walk runs
90 s after any heavy run that left files unverified
(`scheduleHeavyRecheck`), whether or not the originals queue is on. **A set
another device sent** is checked whole too (2026-09-25, Steven's *Stack 21. 9.
at 19:50* on the 16 Pro: PicPlace held all 301 files — the iPad's upload — the
card said *Here and on PicPlace*, and the Here row, the pill and the Gallery's
*Needs uploading* said *not backed up*, because only a set this device sent or
fetched was ever checked — three projects on that phone; verified on it
2026-09-26: *Needs uploading* 683 → 680, exactly those three, the rest
genuine — 678 with none of their files on PicPlace): admitted when PicPlace's
count of the project's heavy files (`serverHeavyFiles`, from the check's
pulls) is at least what this device had at its last push, and checked when it
covers what is here now — fewer there means something here is missing, and
costs no read. The walk
now runs under every automatic rule but *Upload blends automatically*, which
holds only its uploads (`heavyChecksAllowed`). A set found incomplete for
want of something the queue does not send is not read again until it moves
(`heavySetMissing`). `shutDown` now cancels the blends queue too (it did
not).

**The 11:32 bug** — a tile lost its badge after *Remove originals*:
`noteFilesChanged` drops the project's holdings, and the badge asked only
when it first appeared. The pill (and the **Here** row) ask again whenever
their project's answer is dropped (`HoldingsAsk` keys the ask on the store's
revision while the cache is empty), and show the last answer meanwhile
(`ProjectHoldingsStore.shown`) so nothing blinks.

**Verified** on the bench (picplace.test, `letslapse-two`, library
*assets-bench4*, Mac Debug): a photo registered → **camera**; pushed →
**camera | cloud**; Upload → **camera | green**; Remove originals → **green**
alone (the 11:32 case), on both tabs; a video uploaded, a blend added while
PicPlace was unreachable → **camera layers | cloud**; back online → the
records push, the blends queue sent the blend and re-checked the whole set
(`heavyDigest` rewritten) → **camera layers | green**; Remove originals →
**layers | green**; the project screen's blend row → **layers | green**. An
unconnected scratch library: no pill on normal projects, the triangle on the
two whose files were dropped. iPhone Simulator (a copy of the bench library,
requests cut off): the pill fits the phone's Gallery tiles and Projects
cards. Kit `ProjectHoldingsTests` pass. Cleaned up: projects tombstoned, token
revoked, bench roots deleted.

**Installed** as a Release build on the iPhone 18 Pro, iPhone 16 Pro and iPad
Air M3 (after checking none was mid-shoot). One wording fix after that build
— the project screen's PicPlace card said *Preview only* over a project whose
blend is still here; it now says *Blends here*, as the pill's layers do — went
to the iPhone 16 Pro and iPad Air M3 in a second build at 12:35, and to the
18 Pro once it was free — all three now run the same build.

**Owed:** Steven's look on his devices; the mirrors (§8); per-blend presence
across devices is still per-project on the server.

## 13. Stage 4 — the swipe on the capture device (2026-09-25, uncommitted)

**Measured first.** Every page turn now logs one line (`PageTurnTrace`,
`App/EditorLaunch.swift`): `pager: turn → <title> · <kind>: slide · exit ·
mount · seed · … · handover = total; main thread longest stall N ms (from
<phase>, +t)`. The stall probe (`MainThreadStallProbe`, `EditorPager.swift`) is
a display link pinned to 60 Hz — **trap:** left to itself iOS slows an idle
link (nothing animating between the slide and the picture), and a slowed link
reads as a stall that never happened; the first measurements had it.

**Where a turn's time went** (iPhone 16 Pro, its own 12 MP DNG and 48 MP
JPEG shoots, Release): the slide (~240 ms, the 0.22 s animation), then the
editor waited — a 100 ms debounce meant for slider bursts, a metadata size
probe and an as-shot read one after the other (up to 380 ms on a 48 MP JPEG),
the strip's clock read for an interval shoot (100–200 ms), then the decode and
grade from nothing (100–155 ms) — while a blurred grid thumbnail stood in, and
the Gallery behind the cover re-selected and scrolled its grid on every turn.

**What landed:**

- **Look-ahead** (`App/EditorLookAhead.swift`): once a page's picture is up,
  the pager makes the pages either side (the way it last turned first) on a
  lane of its own below everything a person waits on
  (`MediaWorkQueue.lookAhead`, one wide, utility): a still's opening render
  through exactly the grader call the editor's first render makes
  (`EditorOpeningRender`: the frame it opens on — an interval shoot's first
  frame on the strip at position 0 — the grade there less the crop, the white
  declared there, 2000 px), a preview's picture decoded
  (`PreviewPictureCache`, which the preview page reads first). The page that
  slides in is the real picture, not the grid's thumbnail, and the editor that
  mounts finds its first render in the grader's cache (0–1 ms).
- **The first picture waits for nothing** (`PhotoViewerView`): no debounce for
  the first render; the render goes as soon as the grade is seeded (a legacy
  relative white is migrated first); the size probe and the as-shot read run
  alongside it (the render never needed them — the grader resolves the as-shot
  white itself; the readouts' anchor is refreshed after the picture); the
  strip's clock loads behind the first picture.
- **The Gallery follows a page once it rests** (`EditorPager.follow`, 0.8 s):
  never during a turn; a run of quick swipes follows once; Back lands the grid
  either way.
- **The handover is said outright** (`EditorPagingContext.onPicture`, and
  `EditorPagingState.captureID`): the pager waited for a blank frame from the
  new editor, and a picture served from the cache landed before any was
  published — the poster sat over the editor until its 1.5 s safety net. The
  preview page's decode moved into the shared cache; a preview with no poster
  settles at once.
- **The video editor's player item and grade composition are made off the
  main actor** (the composition's initializer loads the asset's tracks
  synchronously).

**Measured** (the same walks, before → after, the corrected probe):

| Turn | Before | After | Longest main-thread stall |
|---|---|---|---|
| Photo, 12 MP DNG | 530–647 ms | 350–357 ms | 140 → 17 ms |
| Interval, 25 frames DNG | 700 ms | 351 ms | 213 → 17 ms |
| Interval, 2,425 frames DNG | 734 ms | 345 ms | 210 → 17 ms |
| Photo, 48 MP JPEG | 765–782 ms | 444–455 ms | 275–414 → 17 ms (one 210) |
| Preview page | 426–462 ms; one 1,907 ms (timed out) | 289–373 ms | up to 157 → 17 ms |
| Into a 4K video | 705 ms | 645 ms | 424 → 219 ms |

About 240 ms of every "after" is the slide animation itself; with the
look-ahead the picture on screen at its end is already the right one.

**Bench** (hands-free, Steven's own library untouched): a Release build with
the DEBUG hooks on (`SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG $(inherited)'`
— optimised, unlike a Debug build), launched by `devicectl … -e
'{"LL_TAB":"gallery","LL_ITEM":"<uuid>","LL_PAGE":"next@4x12",
"LL_PICPLACE_NETWORK":"cellular"}' com.regularsteven.letslapse --
-letslapse.picplace.wifiOnly YES` (PicPlace held for the run: Only on Wi-Fi
for that launch, never written, and a pretend mobile path — nothing sent,
nothing marked failed); app arguments go after `--`, or `devicectl` reads them
as its own; the phone must be unlocked. Pull `Logs/` and read the
`pager: turn` lines. `LL_PAGE` takes `x<turns>` (2026-09-25).

**Installed** as a Release build on the iPhone 16 Pro, iPhone 18 Pro and iPad
Air M3 (2026-09-25).

**Owed:** the video page — entering one still stalls the main thread ~220 ms
as the slide ends (the video editor's mount; the Simulator shows it too, and
Instruments could not attach on the 16 Pro to say more); the editor's own
first picture lands ~70–165 ms after its mount while the main thread settles
the new editor (the look-ahead's poster already shows the same pixels, so this
is time to the first slider, not to the picture); the first photo editor after
a launch mounts in ~95 ms; the Mac's item view (filmstrip, ←/→) could take
the same look-ahead.

**Leftovers, worked the same day (Steven: "focus on the filters next and
stage 4 left overs, and stage 5"):**

- **The video page.** Sampling the Simulator app across a turn into a video
  shows the app's main thread idle: the ~120–220 ms display gap as the slide
  ends is the system setting up the new player's video surface, not app
  work. What the app can shorten is the wait for the first frame: the
  look-ahead now opens a neighbouring movie's asset and reads its length
  (`VideoAssetCache`) — the ~300 ms `asset` phase on the 16 Pro — and the
  video editor takes it (`asset made ahead` in the trace; 0 ms on the
  Simulator).
- **The editor after its picture.** Not a blocked main thread (never over
  17 ms on the 16 Pro): the editor answers touches throughout; only its own
  copy of the picture (the same pixels as the look-ahead's poster) is
  applied a little later. Nothing to fix.
- **The Mac's item view** (filmstrip, ←/→) warms the same caches a beat after
  each move (`EditorLookAheadRunner`) and logs the same trace line: moves on
  the M4 Max land their picture in 82–99 ms, a preview's from the look-ahead.

## 14. The Gallery's PicPlace filters (2026-09-25, uncommitted)

From the brief's *Gallery library filters* (§1b). Steven kept the icons as
built (the holdings pill) and asked for the filters next.

**What.** In a library connected to PicPlace the Gallery sidebar — the Mac's
column, the phone's Library sheet — has a **PicPlace** section under
Library: *All · On this device · Download available · Not available to
download · Needs uploading · Has blends · Syncing / Needs attention*, each
with its count over what the kind, tags, words and shapes leave, and each
narrowing the grid (and so the pager's set). A standalone library has no
section. The holdings pill's VoiceOver labels now use the same words.

**How** (`App/ProjectStatus.swift`). A filter needs every project's state, a
tile only its own: a **status sweep** walks the library off the main actor
the first time the Gallery shows in a connected library — each project's
document and folder, the tile's own `ProjectHoldings` — and keeps a summary
per project (originals here, blends here, the heavy set's digest), published
in batches and remembered in `Index/local-status.json`; later sweeps re-walk
only a project whose `project.json`, `source/` or `blends/` moved (a
signature of their modification dates). Tiles' holdings feed the same
summaries; `dropHoldings` re-walks one project a beat later. The PicPlace
half reads the record: *Download available* needs PicPlace to hold the
**originals** — its own list when a card has read it, else the new
`PicPlaceSyncRecord.serverSourceFiles` (recorded at a pull, a pull-update, a
card's refresh and the check before a removal), else the backed-up marker,
else the heavy count; *Needs uploading* is originals here not backed up
(`heavyDigest`); *Syncing / Needs attention* is a transfer under way, a
failed sync or a conflict. The grid's filtered rows and the counts are
cached per question until the store or the index moves.

**Verified** (bench on picplace.test, library *assets-bench5*, one project
per state): the counts and every filter's grid on the Mac — On this device
= {B, D}, Download available = {C}, Not available to download = {A}, Needs
uploading = {D}, Has blends = {C}, Syncing / Needs attention = {A} while its
failure was staged (then 0 once the app's own check retried it); the phone's
Library sheet (`LL_SIDEBAR=1`) shows the section with the same numbers. Long
names wrap in a narrow sidebar rather than truncate. Hooks:
`LL_PICPLACE_FILTER=<onDevice|downloadAvailable|notAvailable|needsUploading|hasBlends|attention>`,
`LL_SIDEBAR=1`.

**Owed:** the Projects tab sharing the component (the brief: until Projects
is retired); Mac tooltips on the pill (a tooltip needs the pill to take the
pointer, which would swallow clicks on the tile's corner); the mirrors (the
Gallery sidebar on the Mac, the phone's Library sheet); the sweep's time on
a thousand-project phone (measured below when run).

## 15. Stage 5 (2026-09-25, in progress)

- **Background transfers — Stage 1 of the uploads plan, and downloads**
  (`PicPlaceBackgroundActivity`, `PicPlaceContinuedTransfer`, iOS 26+): a
  person's download and a person's upload job ask iOS for a *continued
  processing* task (`com.regularsteven.letslapse.transfer.*` in
  `BGTaskSchedulerPermittedIdentifiers`, a handler registered for each
  request's own identifier just before it): LetsLapse keeps running after
  it leaves the screen or the phone locks, for as long as iOS allows, the
  transfer's title and *N of M files* on the Lock Screen. While it holds the
  app the thirty-second grant running out stops nothing; its own expiry stops
  an upload between files (held, resumed in front, as before) and a download
  (what landed stays). Automatic syncs, and jobs resumed on their own (launch,
  network, retry), keep the thirty seconds.
  **2026-09-25, 16:32: the first build crashed Steven's iPad at every
  launch** — it registered one handler for the wildcard at launch (refused
  by design: `register` returned false), then submitted anyway, which
  BackgroundTasks answers with an assertion, not an error; the waiting
  upload job re-asked at every launch. Fixed the same day (per-request
  registration, no request without it, presses only, `processing` mode) —
  the rules and sources are in
  [picplace-background-uploads-plan.md](picplace-background-uploads-plan.md)
  Stage 1. Device check without a transfer: `LL_CONTINUED_PROBE=<seconds>`.
- **D3 Collections travel — app side built, dormant** (Steven: *write the
  ask*; [picplace-collections-ask.md](picplace-collections-ask.md)): PicPlace
  keeps one collections document per library behind a revision
  (`GET/PUT /libraries/{uuid}/collections`, 409 on a stale write,
  `features["collections"]` in /status). `App/PicPlace/PicPlaceCollectionsSync.swift`
  pulls it at every check and merges collection by collection — the later
  change wins, a deletion counting as one (Kit `LastEditMerge`, 7 tests) —
  writes here what moved, and pushes 4 s after a change here (a 409 pulls,
  merges and sends again once); the document travels exactly as
  `collections.json` is written (`ProjectDocumentFormat`). Nothing runs
  until the server says it can; untested against a server.
- **D4 Stills in collections — built** (Steven: 4 s, a gentle move by
  default, *any photo*): a collection member may be an image blend, with a
  length (`Entry.stillSeconds`, `LapseCollection.defaultStillSeconds`) instead
  of trim points, and its own Ken Burns move dealt as it joins — whatever
  the collection's mode. The exporter cuts a still from a short movie of its
  picture (`App/StillClipMaker.swift`: one frame held for the length, 5120 px
  long edge, cached) and gives it its move as a transform ramp in a plain
  collection too; in Ken Burns' consistent mode a still takes the target
  and never caps it (a stills-only timeline takes its shortest still's
  length). A photo without a still gets one made when picked
  (`App/CollectionStills.swift`: its picture through its grade, a JPEG blend
  of its project — so it travels like every blend — only where the original
  is, else the fetch prompt). The picker has a **Photos** group (ids from the
  index, records read as tiles scroll in), stills are no longer locked; a
  still's row reads *Still · 4.0s · gentle move* with a length menu (2–10 s)
  where the trim button was, and plays full screen as a picture; a photo's
  still is labelled *Still*, not *Long exposure*; the recipe carries a
  still's length and move. **Verified** on the Mac (`LL_COLLECTIONS=still`,
  `still-kb`): a 3:4 collection from a photo's still exported 4.00 s at
  2160×2880 with the move (first vs last frame), and the same in Ken Burns
  Auto mode; the picker's Photos group. **Owed:** a mixed clip + still
  export on a library with a video blend; the mirrors (the picker, the
  still row).
- **A clip that is not here claims only what PicPlace holds** (2026-09-26,
  *Victory Bridge Sunset* on the 18 Pro: its six blends were never uploaded —
  PicPlace held its records and poster only — yet each row said *On
  PicPlace* and offered Download, which failed four times and left the
  project marked failed). One rule, `PicPlaceController.blendAvailability`:
  PicPlace's list for the project once read (`serverHeavy`), else a count of
  none (`serverHeavyFiles == 0`) says not there, else unknown — claimed
  neither way. The blend row asks for the list as it shows a missing clip
  (`askForListing`, once a minute per project) and reads *On PicPlace* /
  *Not available to download* / nothing; its Download only when the list
  holds the file; the blend pill claims nothing while unknown; the picker
  badges *ON PICPLACE* / *NOT AVAILABLE* / *NOT HERE* from what is known (it
  asks nothing — its by-project view is not lazy); the builder's and the
  preview page's offer takes the count too. A download PicPlace has nothing
  for (`PicPlaceDownloadRun.NotThere`) is not a failure on the record, and one
  recorded before is cleared when the list is next read. **Verified** on the
  18 Pro: six rows *unknown* → *not on PicPlace* 3.5 s after the detail
  opened (DEBUG `blend row:` log); the record's four failures cleared. The
  words are interim — Steven's copy pass (TODO).


## 16. Status glyphs — green means here, one cloud (2026-09-26, signed off)

Steven's review of the shipped pill (eleven screenshots of one project's
life) found a green tick meaning *backed up*, an outline cloud meaning four
things, an upload arrow over *Freeing up space*, a card with a green tick
above *only on this device — Upload*, and a blend that vanished from the pill
when it was only on PicPlace. The scheme that replaced it was drawn first on
the canvas **Holdings Pill States**
(https://claude.ai/artifact/7zbnCfyZLsMC2huVLY7A4T — revision 2 is the
signed-off one: the rule, his A/B/C scenario of a raw DNG timelapse and its
lossy copy, his moments at actual size on bright and dark photos, every
surface). A first proposal (colour = here, *fill* = safe on PicPlace) failed
Steven's own test: fill is the weakest channel carrying the most important
meaning, and it must be taught.

**The rule** (`StatusGlyph`, `StatusGlyphView`, `App/HoldingsPill.swift`):

- **Asset glyphs say where each thing is.** Camera = the originals, layers =
  the blends (shown only when the project has blends; a Photo's stack is its
  picture, not a blend). **Green = here, ready to edit or play**; grey = on
  PicPlace, download it; grey and slashed = nowhere reachable. Green means
  nothing else, anywhere. Blends are green only when every one is here.
- **One cloud, never green, says whether what is HERE is safe**: ✓ everything
  heavy here verified on PicPlace; ↑ something here isn't up yet; amber ↑ ↓ ↻
  while uploading, downloading, checking (free up space); a paused cloud
  while a job waits (paused, Wi-Fi, stopped by iOS); red ! for attention
  (a failure, a conflict — red, not the old `levelOff` orange beside the
  amber); no cloud when nothing heavy is here or there is no PicPlace.
  **A records-only sync draws nothing** (only a heavy run has an upload stop
  signal). Which asset needs uploading is the detail panel's to say.
- **One vocabulary everywhere**: the pill (Gallery tiles, Projects rows,
  the Mac item view), the blend rows' pill, the PicPlace card's glyph (its
  rest state is the pill's cloud; `icloud.slash` only for signed out / not
  connected), the editor's preview banner (grey camera; slashed when
  PicPlace lacks the originals; amber ↓ while downloading), and the Library
  filters (each filter's glyph is its state's: green camera *On this
  device*, grey *Download available*, slashed *Not available*, cloud ↑
  *Needs uploading*, amber cloud *Syncing / Needs attention*).
- **Symbols**: `camera.fill`, `square.3.layers.3d.top.filled` (no fully
  filled layers exists), `square.3.layers.3d.slash`, `checkmark.icloud.fill`,
  `icloud.and.arrow.up.fill`, `icloud.and.arrow.down.fill`,
  `arrow.clockwise.icloud.fill`, `exclamationmark.icloud.fill`; composed:
  the slashed camera (a slash knocked through `camera.fill`) and the paused
  cloud (pause bars knocked out of `icloud.fill`). Pill: 18 pt, glyphs 9 pt
  semibold, the cloud 10 pt.
- **Checks**: `LL_PILL_SHEET=1` (DEBUG) renders every pill state and the
  filter glyphs on the device at its own scale into `Logs/pill-sheet.png`;
  `LL_DUMP_PILLS=1` logs each drawn pill's words (`pill: <title> — …`).

**Two corrections the same day** (Steven, on the 16 Pro/18 Pro builds):

- **The tick stays when the originals leave.** The first rule drew no cloud
  when nothing heavy was here, so *Remove originals* turned green camera · ✓
  into a lone grey camera — as if the project had lost something. The cloud
  now answers *does PicPlace hold everything this project has*: ✓ also when
  nothing heavy is here and PicPlace holds the originals (and no blend is
  nowhere). Freeing space greys the camera; the tick stays.
- **No ↑ right after an upload.** Every upload ends *"N original(s)
  confirmed, PicPlace still checking them"*; the marker came only from a
  look 90 s later, gated on the automatic rules, then the 3-minute check —
  one to five minutes of ↑ beside *Originals: Here and on PicPlace*. Now the
  push marks the record (`verifyPendingSince`), the pill and the card show
  amber ↻ *checking*, the filters count it under *Syncing / Needs
  attention*, and `verifyAfterUpload` looks at that project every 10 s for
  two minutes, every 30 s to five, every minute to thirty
  (`PicPlaceSyncRecord.verifyWindow`), whatever the automatic rules; a check
  resumes a look the app was closed in. A read that fails is *not known
  yet*, no longer *missing*. **Verified on the iPad** (a one-photo upload,
  11.1 MB): *Uploading* → *Checking with PicPlace* the instant the upload
  ended → *Backed up* 63 s later on the first schedule (5/15/30/60 s —
  PicPlace finished between the last two looks, hence the 10 s cadence).

**Mirrors — drawn 2026-09-26** (Steven: "do the mirrors"): everything §8,
§10–§15 owed, in this scheme — the pill as a generated component set
(`design/components/holdings-pill.make.py`, 25 states; `picplace-pill.*`
deleted), every tile / card / filmstrip / blend row wearing it, the Library
filters (phone sheet, Mac sidebar), the *Here* row, the preview page on
phone / iPad / Mac (the item view and the separate window), its prompt and
progress, the project screen's preview state, the PicPlace card's glyphs and
its `checking` / `preview-only` states, the drawer's downloads block,
collections (banner, a clip on PicPlace, a still member, the picker's
badges) and the Settings card's auto-sync switches. The design INDEX notes of
that date list the files. **What the drawing found** (for Steven, no code
changed): the pill is drawn over the type badge where they meet — on a
3-column phone grid an *Interval* badge loses 4–19 pt under a 46 / 60 pt pill;
`HoldingsHereRow.line` and the *Has blends* filter count a Photo's picture
stack as a blend while the pill does not (a JPEG-burst photo reads
*Originals and blends* with a camera-only pill, and sits under *Has blends*
without layers); the downloading caption drops *· Light opens when …* until
the first byte lands (`+` binds tighter than `?:` in `EditorPreviewPage.status`);
*Share project* is not greyed on a preview though it asks — the last three are
the TODO entry *Connected asset states — three small faults found drawing the
mirrors* (Steven: "mark issues 2–4 as to-do"); the badge overlap is his open
question. The mirrors the pass left are the TODO entry *Design mirrors left
after the 2026-09-26 connected-asset-states pass*. **Still owed:** the copy pass (TODO) — and watch
whether *checking* after an upload reads as "the upload failed".
