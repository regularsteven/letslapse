# LetsLapse iOS UX Brief

> **Status (2026-08-01): superseded — kept for history.** This was the brief for the 2026-07 redesign, which has shipped: the app now uses a Create · Gallery · Projects · Collections · Settings shape (this document's Capture/Job/Library/Blends inventory no longer exists), gained a Photo capture mode, and renamed generated outputs from "versions" to **blended clips**. The current designer brief is [`letslapse-collections-ux-brief.md`](letslapse-collections-ux-brief.md); the current-state handover is `LetsLapse/docs/letslapse-app-overview.md`.

Prepared for a product/UI designer to review the current LetsLapse iOS app and propose a clearer, more polished user experience. This brief describes the current screens, flows, interaction model, and known design decisions from the app implementation. It is intended to be used alongside screenshots of the app as it exists today.

## Context

LetsLapse is a native SwiftUI app for creating time-based visual effects from captured or imported media. Users can:

- Capture video on iPhone and blend consecutive frames into a motion-blurred timelapse or speed-ramped clip.
- Capture interval photos and stack them into a synthetic long exposure still image.
- Import existing videos or photo sequences from Photos.
- Save, share, browse, preview, and re-blend previous source captures and generated outputs.

The app is currently a proof-of-concept with strong technical capability, but the UX still exposes much of the processing model directly. The redesign goal is to make the product feel approachable for creators while preserving the power needed for advanced timelapse and long-exposure work.

## Designer Assignment

Review the current LetsLapse app, using this brief and the attached screenshots, then propose an improved end-to-end UX for iPhone.

Primary goals:

- Clarify the product promise in the first-run and source-selection experience.
- Make capture, import, blend setup, processing, result review, and re-blending feel like one coherent creative workflow.
- Reduce technical friction without removing advanced controls.
- Improve hierarchy, copy, terminology, affordances, empty states, and error states.
- Define a more polished visual system for camera controls, job controls, library browsing, and results.
- Identify any missing screens or states needed for a production-quality iOS app.

Expected designer output:

- Revised information architecture and navigation model.
- Wireframes or high-fidelity mocks for all core screens.
- Recommended screen states for loading, empty, error, permission, recording, processing, success, and saved states.
- Interaction notes for the capture controls, blend controls, library, result actions, and re-blend flow.
- Copy recommendations for user-facing terminology.
- A prioritized UX improvement list for implementation.

## Current App Structure

The iOS app uses a native `TabView` with five tabs:

- **Capture**: Source entry point for recording or importing media.
- **Job**: Active job state machine: empty, configure, processing, result.
- **Library**: Saved original captures.
- **Blends**: Saved generated outputs.
- **Settings**: Default blend and performance preferences.

The app model has four main job stages:

- **Home**: No active source selected.
- **Configure**: A source is selected and blend options are editable.
- **Processing**: Blend or stack work is running.
- **Done**: Output is available for preview, sharing, saving, and re-blending.

## Audience Assumptions

Likely users include:

- iPhone creators who want stylized timelapse or motion blur without desktop editing.
- Photographers experimenting with synthetic long exposure.
- Technical/enthusiast users who understand frame rates, blend windows, and high-FPS capture.
- Future casual users who may only understand the desired result, not the underlying frame math.

The current UX leans toward the technical/enthusiast user. The redesign should decide how much of that complexity remains visible by default.

## Core Concepts To Preserve

- **Source capture**: The original video or photo set is preserved in the app library.
- **Blend output**: Each generated result is stored separately and linked to the original source.
- **Re-blend**: A user can return to the original source and generate a new output with different settings.
- **Video blending**: Several source frames are averaged into one output frame.
- **Window/ramp**: The number of averaged source frames can stay constant or ramp over time.
- **Photo stacking**: Multiple stills are averaged into one image.
- **Linear-light averaging**: A higher-quality technical default that should probably remain available, but may need friendlier wording.

## Current Screen Inventory

### 1. Capture Tab: Source Selection

Current purpose:

- Introduces what the app does.
- Allows iOS users to open the camera capture flow.
- Allows importing a video or multiple images from the Photos picker.
- Displays import progress and source-selection errors.

Current content:

- A descriptive paragraph: "Capture or import footage, then blend..."
- Section: Capture
- Button: "Capture video or interval photos"
- Section: Import
- Photos picker: "Import a video"
- Photos picker: "Import photos to stack"
- Progress row: "Importing..."
- Error row in red, if import fails.

Current design decisions:

- Uses a simple native list/form style.
- Treats capture and import as equivalent ways to create a source.
- Immediately advances to the Job tab after a source is selected.

UX considerations:

- The opening paragraph explains the engine, but may be dense for first-time users.
- "Capture", "Import", "Blend", "Stack", "window", and "linear-light" need a clearer vocabulary system.
- The app may benefit from effect-first choices, such as "Motion-blurred timelapse", "Speed ramp", and "Long exposure still", before exposing source mechanics.

Screenshot to attach:

- `capture-tab-empty.png`
- `capture-tab-importing.png`
- `capture-tab-error.png`

### 2. Capture Modal: Camera

Current purpose:

- Full-screen iPhone camera interface for recording video or interval photos.
- Offers technical camera format control before capture.
- Supports paired Apple Watch start/stop for video recording.

Current states:

- Camera authorized.
- Camera access denied.
- Idle video capture.
- Actively recording video.
- Idle interval capture.
- Actively capturing interval photos.

Current layout:

- Black full-screen background.
- Camera preview, either full-screen crop or contained window.
- Top-left `Cancel` button.
- Top-right active format readout, for example capture resolution, FPS, and stabilization status.
- Bottom control panel with segmented controls, pickers, toggles, sliders, and record/stop action.

Current controls:

- Preview layout: Fullscreen / Window.
- Capture mode: Video / Interval.
- Lens: Ultra Wide / Wide / Telephoto, depending on device support.
- Stabilization toggle for video.
- Resolution picker, such as 4K, 1080p, 720p, depending on device support.
- Frame rate picker, such as 24, 25, 30, 50, 60, 100, 120, 240, depending on device support.
- Video action: Record / Stop Recording.
- Interval timing slider: every 0.5 to 10 seconds.
- Interval action: Start Interval Capture / Finish.

Current design decisions:

- Camera controls prioritize technical accuracy and hardware capability.
- Recording and interval mode lock format controls while active.
- The idle timer is disabled during recording or interval capture.
- Orientation is tracked and applied to video/photo capture.
- Stabilization filters available camera formats when enabled.

UX considerations:

- Fullscreen camera is appropriate, but the control stack is dense.
- The app may need a clear distinction between "simple capture" and "advanced camera settings".
- The active format readout is useful for experts but may be visually noisy.
- Interval capture uses photo count as feedback, but may need elapsed time, estimated output, or stop guidance.
- Permission-denied state should include a direct path to iOS Settings if possible.

Screenshot to attach:

- `camera-video-idle.png`
- `camera-video-recording.png`
- `camera-interval-idle.png`
- `camera-interval-running.png`
- `camera-window-preview.png`
- `camera-permission-denied.png`

### 3. Job Tab: Empty State

Current purpose:

- Shows when no source is active.
- Sends user back to Capture tab.

Current content:

- Wand icon.
- Title: "No Active Job"
- Body: "Capture or import a source to start blending."
- Button: "Go to Capture"

Current design decisions:

- The Job tab is always present, even before a job exists.
- Empty state keeps the app shell stable instead of hiding the tab.

UX considerations:

- "Job" is implementation-oriented language. A creator may expect "Create", "Edit", "Blend", or "Project".
- Empty state could show clearer next actions and examples of outputs.

Screenshot to attach:

- `job-empty.png`

### 4. Job Tab: Blend Options

Current purpose:

- Configures the processing parameters for the selected source.
- Branches between video blending and photo stacking options.

Current video sections:

- Source summary and capture metadata.
- "Choose another source" reset action.
- Video blend options:
  - Frames to one output frame: 2, 5, 10, 25, 50.
  - Custom frame window stepper: 1 to 120.
  - Output frame rate: 24, 25, 30, 50, 60 fps.
  - Linear-light averaging toggle.
- Advanced:
  - Ramp the window across the clip.
  - Start frame window.
  - End frame window.
  - Curve: available `BlendCurve` options.
- Trim:
  - Trim video ends toggle.
  - Cut same duration from start and end: 0.1 to 30 seconds.
- Primary action: "Blend Video".

Current photo stack sections:

- Source summary and capture metadata.
- Stack:
  - Linear-light averaging toggle.
  - Explainer text about synthetic long exposure and noise reduction.
- Primary action: "Stack Photos".

Current design decisions:

- Video and photo sources share the same configure screen but reveal different controls.
- Advanced ramping is opt-in.
- Trimming is symmetrical from both ends, likely to remove camera shake at start/stop.
- Preset windows exist, but custom technical values are always visible.

UX considerations:

- This screen is the biggest opportunity for UX simplification.
- "Frames to one output frame" is accurate but not effect-oriented.
- Presets could be reframed around output intent, such as subtle blur, smooth timelapse, heavy streaking, or speed ramp.
- The relationship between source FPS, output FPS, frame window, speed, and blur needs clearer communication.
- Current controls do not preview expected output duration before processing.
- Advanced settings should likely be progressive-disclosed.

Screenshot to attach:

- `blend-options-video-basic.png`
- `blend-options-video-ramp.png`
- `blend-options-video-trim.png`
- `blend-options-photo-stack.png`
- `blend-options-error.png`

### 5. Job Tab: Processing

Current purpose:

- Shows processing progress and allows canceling.

Current content:

- Linear progress view.
- Status text, defaulting to "Processing..." or a specific model status message.
- Numeric percent.
- Optional job folder path.
- Optional scrolling log lines.
- Destructive `Cancel` button.

Current design decisions:

- iOS and macOS share a processing model, though macOS exposes more job-folder/log detail.
- Cancel returns the user to the configure stage.
- Technical progress/log fields support debugging and long-running processing.

UX considerations:

- On iOS, job folder and log detail may not be user-relevant.
- The screen could better explain what is happening: preparing, decoding, blending, encoding, saving.
- Consider an estimated time remaining if feasible.
- Cancel should clarify whether partial output is discarded.

Screenshot to attach:

- `processing-basic.png`
- `processing-with-log.png`

### 6. Job Tab: Result

Current purpose:

- Previews the generated video or stacked image.
- Allows sharing, saving to Photos, closing, and re-blending from the original.

Current content:

- Video player for generated video, or image preview for stacked photo output.
- Result summary, such as input frames, output frames, duration, and resolution.
- Blend parameter summary.
- Actions:
  - Share.
  - Save to Photos.
  - Close.
- Re-blend from original controls:
  - For video: frame window, output FPS, ramp options.
  - For photos: linear-light toggle.
  - Regenerate button.
- Save confirmation text.

Current design decisions:

- Results are not dead ends; every output can be regenerated from the preserved original.
- Share and Save to Photos are both exposed.
- Close resets the active job and returns to the home/source state.

UX considerations:

- "Close" may be ambiguous because the result remains saved in Blends.
- Re-blend controls on the result screen duplicate part of Blend Options and may feel visually secondary or cramped.
- The user may need clearer confirmation that the result is stored in the app library.
- Consider before/after comparison, original preview, output details, and stronger save/share hierarchy.

Screenshot to attach:

- `result-video.png`
- `result-image.png`
- `result-reblend-controls.png`
- `result-save-confirmation.png`

### 7. Library Tab: Captures

Current purpose:

- Displays preserved source captures.
- Lets users preview originals, start a new blend from a source, and inspect related blends.

Current states:

- Empty library.
- List display.
- Grid display.
- Expanded capture with related blends.
- Preview sheet.

Current content:

- Toolbar segmented picker: List / Grid.
- Capture cards:
  - Thumbnail.
  - Original name.
  - Summary, such as mode, FPS, or photo count.
  - Created date/time.
  - Actions: Preview, Blend, expand/collapse blend count.
- Expanded capture group:
  - Original thumbnail row.
  - Generated blend rows with preview/open actions.

Current design decisions:

- Captures and blends are preserved separately.
- Library is source-first: a capture can contain many blends.
- List/grid choice supports browsing different media volumes.

UX considerations:

- "Library" and "Blends" split may confuse users unless the relationship is made obvious.
- Expanded blend count button currently uses a numeric label, which may not be self-explanatory.
- There is a `CaptureProjectDetailView` in code, but the primary current interaction appears card-based.
- Consider a project detail page that groups source, outputs, actions, and metadata more clearly.

Screenshot to attach:

- `library-empty.png`
- `library-list.png`
- `library-grid.png`
- `library-expanded-capture.png`
- `library-preview-sheet.png`

### 8. Blends Tab: Generated Outputs

Current purpose:

- Displays all generated outputs across captures.
- Lets users preview, open, or adjust a blend.

Current states:

- Empty blends.
- List display.
- Grid display.
- Preview sheet.

Current content:

- Toolbar segmented picker: List / Grid.
- Blend cards:
  - Thumbnail.
  - Parameter summary, such as `10:1 - 25 fps`.
  - Result summary.
  - Source original name and generated date/time.
  - Actions: Preview, Open, Adjust.

Current design decisions:

- Blends are treated as first-class assets separate from their original captures.
- "Open" loads the generated output in the Result stage.
- "Adjust" loads the source and settings back into the configure stage.

UX considerations:

- "Open" vs "Preview" may be unclear.
- "Adjust" is valuable, but should communicate that it regenerates from the original.
- Consider a unified Projects tab instead of separate Library and Blends tabs, or make the split more explicit.

Screenshot to attach:

- `blends-empty.png`
- `blends-list.png`
- `blends-grid.png`
- `blends-preview-sheet.png`

### 9. Media Preview Sheet

Current purpose:

- Quick preview for either a source or generated output.

Current content:

- Navigation sheet with media title.
- Video player or image preview.
- Optional subtitle.
- Done button.

Current design decisions:

- Uses native sheet navigation.
- Video previews auto-play.

UX considerations:

- Preview-only sheets may need stronger actions, such as Use, Re-blend, Share, Save, or View Details, depending on context.
- Title/subtitle formatting should be tested with long filenames and technical parameter summaries.

Screenshot to attach:

- `media-preview-video.png`
- `media-preview-image.png`

### 10. Settings Tab

Current purpose:

- Defines default processing values and performance settings.

Current sections:

- Defaults:
  - Output frame rate.
  - Frames to one output frame.
  - Linear-light averaging.
- Performance:
  - CPU worker budget.
  - Concurrent blend batches.
  - Footer explaining decode, Metal/GPU batches, disk I/O, and GPU contention.

Current design decisions:

- Defaults are persisted in user defaults.
- Performance tuning is exposed directly to users.

UX considerations:

- Performance controls are probably advanced/developer-oriented and may not belong in a normal iOS settings screen.
- Consider separating creative defaults from diagnostics/developer controls.
- Provide clearer reset-to-default behavior.

Screenshot to attach:

- `settings.png`

### 11. Apple Watch Companion

Current purpose:

- Remote start/stop control for iPhone video capture.

Current states:

- Connecting.
- Ready/idle.
- Recording.
- Phone unavailable.
- Sending command.

Current content:

- Status title: Idle or Recording.
- Recording elapsed time when active.
- Status line with remote status and optional round-trip milliseconds.
- Primary button:
  - Start / Stop when phone is reachable.
  - Find iPhone when unreachable.

Current design decisions:

- Watch control is deliberately narrow: video start/stop only.
- It depends on the iPhone capture screen being active.
- Round-trip timing is shown, which is useful for development but may not be user-facing in production.

UX considerations:

- The watch app should clarify when the iPhone must be on the capture screen.
- For production, remove or hide latency/debug language.
- Consider haptics or stronger visual feedback on command accepted, recording started, and recording stopped.

Screenshot to attach:

- `watch-idle.png`
- `watch-recording.png`
- `watch-phone-unavailable.png`

## Current End-To-End Flows

### Flow A: Capture Video And Blend

1. User opens Capture tab.
2. User taps "Capture video or interval photos".
3. Camera opens full screen.
4. User chooses Video mode, lens, stabilization, resolution, and frame rate.
5. User taps Record.
6. UI shows elapsed recording time.
7. User taps Stop Recording.
8. Camera closes.
9. Source is preserved in the app library.
10. App advances to Job tab.
11. User configures blend options.
12. User taps Blend Video.
13. Processing screen shows progress.
14. Result screen shows generated video.
15. User shares, saves to Photos, closes, or regenerates.

### Flow B: Capture Interval Photos And Stack

1. User opens Capture tab.
2. User taps "Capture video or interval photos".
3. Camera opens full screen.
4. User chooses Interval mode.
5. User chooses lens, resolution, frame rate-related capture format, and interval seconds.
6. User taps Start Interval Capture.
7. UI shows count of captured photos.
8. User taps Finish.
9. Camera closes if at least two photos were captured.
10. Source photo sequence is preserved in the app library.
11. App advances to Job tab.
12. User configures stack options.
13. User taps Stack Photos.
14. Processing screen shows progress.
15. Result screen shows generated image.
16. User shares, saves to Photos, closes, or regenerates.

### Flow C: Import Video And Blend

1. User opens Capture tab.
2. User taps "Import a video".
3. Photos picker appears.
4. User selects video.
5. App copies the picked movie into a temporary location, then preserves it in app storage.
6. App advances to Job tab.
7. User configures blend options.
8. User processes and reviews result.

### Flow D: Import Photos And Stack

1. User opens Capture tab.
2. User taps "Import photos to stack".
3. Photos picker appears.
4. User selects up to 500 images.
5. App copies selected image data into a temporary folder, then preserves it in app storage.
6. If fewer than two photos are selected/imported, app shows an error.
7. App advances to Job tab.
8. User configures stack options.
9. User processes and reviews result.

### Flow E: Re-Blend From Library

1. User opens Library tab.
2. User finds a source capture.
3. User taps Blend.
4. App opens that source in the Job tab configure state.
5. User adjusts settings and processes a new output.
6. New blend is stored under the same source capture.

### Flow F: Reopen Or Adjust A Generated Blend

1. User opens Blends tab.
2. User finds a generated output.
3. User taps Preview to quickly inspect it, Open to load the existing result, or Adjust to return to settings.
4. Open shows the existing output in Result state.
5. Adjust loads the original source and saved parameters into Configure state.

### Flow G: Save Or Share Result

1. User reaches Result screen.
2. User taps Share to open the native share sheet.
3. User taps Save to Photos to request add-only Photos permission if needed.
4. App shows text confirmation: "Saved to Photos." or an error message.

### Flow H: Cancel Processing

1. User starts processing.
2. Processing screen appears.
3. User taps Cancel.
4. Processing task is canceled.
5. App returns to Configure state.

## Data And Persistence Model

Current library behavior:

- Every selected source is copied into app-managed storage.
- Captures are stored as projects with IDs, type, creation date, original name, source files, mode, and optional FPS.
- Blends are stored as generated outputs linked to a capture ID.
- The manifest is saved as JSON in Application Support.
- Existing blends can be reopened without reprocessing.
- New blend attempts create additional outputs rather than overwriting previous results.

UX implications:

- The app behaves more like a project library than a one-off export tool.
- Users need reassurance that originals and outputs are stored, especially after tapping Close.
- Storage management is currently absent from the visible UX: no delete, rename, duplicate, favorite, storage usage, or cleanup flow appears in the current screens.

## Current Design Language

Observed patterns:

- Native SwiftUI forms, lists, navigation stacks, tabs, sheets, and system icons.
- Camera screen uses custom dark controls over a live preview.
- Cards use material backgrounds and 8-12px rounded corners.
- Library and blends use a shared reusable browser component.
- Most controls use system components: pickers, steppers, toggles, sliders, segmented pickers, buttons, share link, video player.

Strengths:

- Native and familiar iOS interaction patterns.
- Clear technical affordances for advanced users.
- Strong underlying state model for preserving sources and outputs.
- Re-blending from original is a valuable differentiator.
- The Watch companion supports real capture use cases where touching the phone causes shake.

Weaknesses:

- The app reads as a tool/debug interface rather than a finished creator app.
- The five-tab structure may be more complex than the task requires.
- Technical parameters are surfaced before the user understands the effect.
- Some labels are precise but not creator-friendly.
- Empty and result states do not fully communicate the app's value or persistence model.
- There is no visible onboarding, examples, templates, or effect preview.

## Terminology Notes

Current terms to review:

- LetsLapse
- Capture
- Import
- Source
- Job
- Blend
- Stack
- Blends
- Frames to one output frame
- Custom frame count
- Output frame rate
- Linear-light averaging
- Ramp the window across the clip
- Trim video ends
- Re-blend from original
- Regenerate

Potential direction:

- Use creator-facing language for primary controls.
- Keep technical language in advanced drawers, info popovers, or detail views.
- Consider naming effect presets before parameters, for example:
  - Smooth timelapse
  - Heavy motion blur
  - Speed ramp
  - Long exposure still
  - Custom

## Key UX Problems To Solve

1. **First-time comprehension**

   Users need to understand what the app makes before they understand how it averages frames.

2. **Navigation model**

   Capture, Job, Library, and Blends are logically distinct in code, but users may think in projects and outputs. Reconsider whether five tabs are necessary.

3. **Effect setup**

   The blend screen should help users choose an outcome, not just numeric parameters.

4. **Result confidence**

   Users should know where their output went, whether it is saved to Photos, and how to get back to it later.

5. **Library clarity**

   The relationship between original captures and generated blends should become obvious and browsable.

6. **Advanced controls**

   Preserve power while reducing default cognitive load.

7. **Camera usability**

   Capture controls need to be fast, legible, reachable, and safe during real shooting.

8. **Missing management flows**

   Production UX likely needs delete, rename, storage cleanup, project details, and possibly export status.

## Suggested Redesign Questions

- Should the app be organized around **Create / Projects / Settings** instead of Capture / Job / Library / Blends / Settings?
- Should a new project begin with an effect choice or a source choice?
- What is the right default path for casual users who just want an impressive result?
- Which controls belong in basic mode versus advanced mode?
- How should the UI explain the relationship between frame window, output speed, and motion blur?
- Should re-blending happen on the Result screen, a dedicated editor screen, or a project detail screen?
- How visible should saved originals be?
- Should generated blends be grouped under projects rather than shown in a separate global tab?
- What should happen after Save to Photos?
- What storage-management controls are required before release?

## Recommended Redesign Direction

One possible direction:

- Replace the current five-tab experience with a simpler three-part model:
  - **Create**: choose effect, capture/import source, configure, process.
  - **Projects**: originals grouped with generated outputs.
  - **Settings**: app defaults and advanced diagnostics.
- Make effect cards the first meaningful choice:
  - Motion-blurred timelapse.
  - Speed ramp.
  - Long exposure photo.
  - Custom blend.
- Use presets for common outcomes and hide exact frame-window values under Advanced.
- Provide an output estimate before processing: expected duration, approximate blur strength, and output FPS.
- Treat Result as a polished review/export screen with clear persistence messaging.
- Give each source capture a project detail screen that shows original media, generated outputs, metadata, and actions.
- Move debug/performance controls behind an Advanced or Developer section.

This is not a fixed requirement; it is a starting hypothesis for design exploration.

## Screenshot Checklist

Provide screenshots for these states when briefing the designer:

- Capture tab empty.
- Capture tab with import progress.
- Capture tab with error.
- Camera permission denied.
- Camera video idle.
- Camera video recording.
- Camera interval idle.
- Camera interval running.
- Camera window preview mode.
- Job empty.
- Video blend options basic.
- Video blend options with ramp enabled.
- Video blend options with trim enabled.
- Photo stack options.
- Processing screen.
- Video result.
- Image result.
- Result with save confirmation.
- Library empty.
- Library list.
- Library grid.
- Library capture expanded with blends.
- Blends empty.
- Blends list.
- Blends grid.
- Media preview sheet for video.
- Media preview sheet for image.
- Settings.
- Apple Watch idle.
- Apple Watch recording.
- Apple Watch unavailable.

## Implementation References

Relevant current files:

- `LetsLapse/App/LetsLapseApp.swift`: tab structure, job shell, library, blends, actions, empty states.
- `LetsLapse/App/HomeView.swift`: capture/import source selection.
- `LetsLapse/App/CaptureView.swift`: iOS camera UI and capture controls.
- `LetsLapse/App/BlendOptionsView.swift`: processing configuration.
- `LetsLapse/App/ProcessingView.swift`: progress and cancel state.
- `LetsLapse/App/ResultView.swift`: output preview, share/save, re-blend.
- `LetsLapse/App/ProjectBrowserView.swift`: shared library/blends browser cards and preview sheet.
- `LetsLapse/App/SettingsView.swift`: defaults and performance settings.
- `LetsLapse/App/AppModel.swift`: app stages, persistence, captures, blends, processing state.
- `LetsLapse/Watch/WatchControlView.swift`: Apple Watch remote capture UI.

## Success Criteria For The UX Revamp

The redesigned app should:

- Make the core value understandable within the first screen.
- Let a new user create a useful result without understanding frame math.
- Let advanced users still access capture format, ramp, trim, FPS, and linear-light controls.
- Make source captures and generated outputs easy to find again.
- Make save/export status unambiguous.
- Feel native, polished, and purpose-built for iPhone creators.
- Reduce unnecessary technical detail in primary paths.
- Preserve the current app's strongest concept: every result can be regenerated from the original source.
