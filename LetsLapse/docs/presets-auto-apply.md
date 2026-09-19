# Auto apply — presets and LUTs on new shoots

*Built 2026-09-19, app code first (Steven's call); the SVG mirrors follow
sign-off. Plan: `~/.claude/plans/inside-the-homescreen-of-hazy-wreath.md`.*

A preset or LUT can be **assigned automatically to every new capture that
matches a capture context**, from its own screen under Create ▸ Manage
presets. Forward-only: nothing already in the library changes. Metadata-only:
the new project is stamped with the preset's state and rendered through it
wherever a grade is rendered today — Gallery tiles, the Projects list's cards,
the project screens, the PicPlace poster — and never at capture. The capture
screen shows a small preset mark while a rule holds the next shoot.

## The model

Eight atomic capture contexts — **slots** — each with at most one owner:

| Slot | Mode | Context |
|---|---|---|
| `photo.jpegStandard` | Photo | JPEG, Capture Flat off |
| `photo.jpegFlat` | Photo | JPEG, Capture Flat on |
| `photo.dng` | Photo | DNG (never flat — the flat grade is a JPEG save-time step) |
| `interval.jpegStandard` | Interval | JPEG, Capture Flat off |
| `interval.jpegFlat` | Interval | JPEG, Capture Flat on |
| `interval.dng` | Interval | DNG |
| `video.flatOff` | Video | Capture Flat off |
| `video.flatOn` | Video | Capture Flat on (Apple Log where the hardware has it, else the software bake) |

What the screen offers are *sets* of slots: Everything = all 8; Photo
shoots · All = 3; · JPEGs = 2; a single filter = 1; Video shoots · All = 2.
A preset's configuration is **derived** from the slots it owns, so the
cleanup is automatic: assigning a set overwrites those slots' owners, and the
other presets' rules shrink to what they still own. A leftover no filter
names (JPEG Standard + DNG after another preset took JPEG Flat) is labelled
as a comma list.

Scans are never a target. Photo and Interval share one Capture Flat toggle
(`captureSettings.stills.flatEnabled`), so a flat rule on both is one switch.

Code: `Kit/Sources/LetsLapseKit/Grading/AutoApplyRules.swift` (`AutoApplyMode`,
`AutoApplySlot`, `AutoApplyFilter`, `AutoApplyRules` — pure, tested in
`AutoApplyRulesTests`), `App/AutoApplyStore.swift` (the file, the context,
what a rule resolves to), `App/AutoApplySection.swift` (the section),
`App/AutoPresetChip.swift` (the mark).

## The file

`<library root>/auto_apply.json`, beside `custom_presets.json` — the ids it
names are that library's, so `AutoApplyStore` re-roots with the preset store
on a library switch (`LibrarySwitch.rerootStores`). Not synced to PicPlace,
as the presets themselves aren't.

```json
{ "version": 1, "owners": { "photo.dng": "<preset uuid>", "video.flatOn": "<preset uuid>" } }
```

Built-ins by their fixed ids (`PhotoPreset.presetID`), saved presets and LUT
presets by `CustomPreset.id`. A key or id the reader doesn't know is skipped.
`CustomPresetStore.delete` releases the deleted preset's slots whichever door
deleted it; a rule whose preset is gone anyway — or whose LUT's cube isn't in
this library's store — resolves to nothing and is pruned at registration.

## The screen

Section **AUTO APPLY** on a preset's screen (after WHAT IT CHANGES) and a
LUT's (after STRENGTH; only when the cube is in the store):

- **Auto apply to** · a menu: `None` · `Everything – All shoots` · ─ ·
  `Photo shoots` · `Interval shoots` · `Video shoots`. The three mode items
  are toggles (✓ while the preset holds any slot of that mode): on takes the
  whole mode, off lets it go. None releases everything; Everything takes all
  8. The value reads `None`, `Everything – All shoots`, `Photo shoots`,
  `Photo & Interval shoots`, `Photo, Interval & Video shoots`.
- **{Mode} shoots for** · one row per mode held · a single-select menu:
  Photo/Interval `All · JPEGs · JPEG Standard · JPEG Flat ON · DNG`; Video
  `All · Capture Flat OFF · Capture Flat ON`. The value is the filter's name,
  or the comma list of what is left after a trim.
- Footer: *New shoots that match start on this preset. Nothing already in
  your library changes.* (a LUT: *…start on this LUT at the strength above.*)
- **Conflict** — only when the slots being *added* belong to another preset;
  narrowing and None never ask: a confirmation titled *Apply Sunny Nature to
  Photo shoots?* (or *…to every shoot?*, or *…to Photo shoots · DNG?*) with
  *Doing this removes: “Flat Day” on Photo shoots · JPEG Flat ON. “Punchy” on
  Interval shoots · All. “Flat Day” keeps Photo shoots · JPEG Standard.* —
  **Apply** / Cancel. The choice is held until the dialog answers, so Cancel
  needs no rollback.

## The capture screen

`AutoPresetChip`: the Manage presets row's glyph (`camera.filters`) in a
31 pt camera-chrome circle with a green tick badge, ahead of the headroom
chip in the portrait top bar and under it in the landscape rail (iPad and
Mac). A readout, not a button. Drawn only while a rule holds the context the
next shoot would register with — predicted from the mode, `wantsPhotoDNG`
(the format pill's own test) and the mode's Capture Flat; nothing for a
Scanner run. In the top bar's `ViewThatFits` ladder it gives way after the
headroom chip's free-space half and before the shot count.

## Registration

The finish closures in `CaptureView` build an `AutoApplyContext` at the top
of each closure, synchronously, before the screen goes — the mode, whether
the frames that landed are DNG (the extension, not the dial: a DNG dial on a
source with no RAW shoots JPEG, and a Holy Grail run takes RAW through the
timer path), and the mode's Flat — and pass it to `setSource` /
`setSequenceSource` / `processPhotoBurst` → `registerCapture` /
`registerSequenceCapture`, where `stampAutoApply` sets `selectedPreset`,
`adjustments` and `presetState = .named(id, snapshot)` on the record
**before** its first write: one document, no `modifiedAt` (nobody edited
anything), and the index counts the preset from the start. The format sheet
is locked while capturing, so the chip's prediction and the outcome agree.

Never auto-graded: Scanner shoots, imports, device transfers, PicPlace pulls,
archive clones — every path but the camera's passes no context.

A consequence worth knowing: a blend clip rendered from an auto-graded shoot
bakes the look, as it does for any graded project. The captured files are
never touched.

## Hooks

- `LL_AUTOAPPLY="photo:dng:Sunny Nature;interval:Sunny Nature;video:flatOn:Teal and Orange"`
  — rules staged in memory (never written): `<photo|interval|video|all>[:<filter>]:<name>`
  per entry, filters `all|jpegs|jpegStandard|jpegFlat|dng|flatOff|flatOn`,
  names the seeded presets' (`ManagePresetsView.debugSeed`) or a built-in's.
- `LL_PRESETS=autoapply` — Natural's screen, where AUTO APPLY sits above the
  fold with a rule or two on it.
- With `LL_CAPTURE=1 LL_MODE=photo|interval|video` the chip shows when a
  staged rule holds the predicted context.
- `LL_REGISTER=<photo|interval|video>:<path>[,<path>…][:flat]` — registers
  the files as if the camera had just made them: the finish closures' own
  `processPhotoBurst` / `setSource` with the auto-apply context a shoot of
  that kind carries (DNG read off the extensions, Flat by the trailing
  token), two seconds after launch. The registration path's one door on a
  machine without a camera — the Simulator has none, and a driver-launched
  Mac copy is refused it. The files are copied to a staging folder first
  (a registration discards the folder its frames came from). Pair with
  `LL_AUTOAPPLY` and read the new project's `project.json`.

## Verification

- Kit: `cd LetsLapse/Kit && swift test --filter AutoApplyRulesTests` (10 tests).
- Simulator: the screens and the chip through the hooks above.
- The registration path: `LL_REGISTER` with `LL_AUTOAPPLY` on the Simulator
  (a Photo JPEG with a Photo·JPEGs rule → `presetState.named` in the new
  `project.json`, the Gallery tile and Projects card graded, "Used on" +1;
  a DNG with a JPEG-only rule → Original). A driver-launched Mac copy is
  refused the camera (TCC), and `$HOME` doesn't redirect its library; a
  device goes over the Camera remote, never by asking for hands.

## Not included

An "Auto" caption on the Manage presets list rows; a tap on the chip;
syncing the rules through PicPlace; a remote-vocabulary `setAutoApply` (the
way to set a rule on a device without a finger, if a device run is wanted).
