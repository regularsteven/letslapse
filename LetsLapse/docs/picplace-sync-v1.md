# PicPlace sync, version one — sign in, push one project, show where it is

**Date:** 2026-09-14 · **Status:** design signed off (Steven, 2026-09-14) and **implemented the same day** in `App/PicPlace/` + the four screens; verified end to end on the iPhone 16 Pro simulator against picplace.test (§7) · **Server:** the PicPlace Laravel app (`picplace` repo, phases 0–4 built and verified 2026-09-14 against Garage; production rollout pending)

Steven's framing (2026-09-14): add authentication to the LetsLapse app and the sync of a **nominated** project — photo, video or interval — to the PicPlace server, with some indication of the status inside the app. This is deliberately the small slice: the full "server as the source of truth" programme ([data-model-server-portability-2026-09-12.md](data-model-server-portability-2026-09-12.md), phase 6) stays where it is. Nothing here changes a record, a file format or the index; a device that never signs in sees no difference.

---

## 1. What the server offers (already built)

Base path `https://<server>/api/letslapse/v1`, bearer tokens from Laravel Passport, PKCE public client with a fixed id, scopes `projects:read/write` + `assets:read/write`. Per project (keyed by the project's own UUID): an index row (name, type, revision, captured_at), the manifest stored verbatim as an object, a single-device **write claim** (a lease with a TTL), **presence** records per device, and **assets** identified by their path within the project with a three-step upload — negotiate (presigned PUT), PUT straight to object storage, confirm. Batches of up to 100 for negotiate and confirm. Accounts must be flagged `verified` on the server (Steven's is). Full contract: `picplace/docs/letslapse-auth.md`, `letslapse-api.md`, `letslapse-storage.md`.

## 2. What the app does

### Sign in (Settings › PICPLACE)

The PKCE authorization-code flow on `<server>/oauth/authorize`, callback `letslapse://oauth/callback` (the scheme is registered in `App/Info.plist`). **iOS** runs the page in `ASWebAuthenticationSession`, which intercepts the callback itself. **macOS** opens the page in the default browser, asks the server for `redirect_uri=https://<server>/oauth/letslapse/return` — the server's "Return to LetsLapse" page, which relays code and state to `letslapse://oauth/callback` automatically or from its button — and takes the callback through Launch Services (`application(_:open:)` / `onOpenURL` → `PicPlaceSignIn.handleCallback`). Why the detour (2026-09-14, Steven's Mac, Chrome 152 as the default browser): `ASWebAuthenticationSession` handed the whole session to Chrome (which declares Apple's auth-session support) and Chrome showed "This site can't be reached" on the `letslapse://` redirect; opening the page in Chrome as a plain tab did the same on the 302 — yet a clicked `letslapse://` link in Chrome reached the app every time. So the redirect target is a page every browser will show, and the scheme is opened from it. The browser may ask "Open LetsLapse?" once; the tab it leaves says it can be closed; a sign-in the browser never finishes is cancelled by tapping the row again. Every `letslapse://` URL the app receives is logged (`picplace: received …`) and consumed, never handed to the archive importer. Exchange the code at `/oauth/token`, keep access + refresh tokens in the Keychain (`com.regularsteven.letslapse.picplace`, this device only), refresh silently before expiry, treat a refused refresh as signed out. Then `POST /device` with `device_key = DeviceIdentity.id`, the device's name, platform, model, OS and app version — the row other devices see in a project's *Also on* line. `GET /status` is the handshake (api version, user, feature flags, storage used).

**Server** is a setting (`letslapse.picplace.server`): Debug builds default to `https://picplace.test` (Valet + Garage on the Mac), Release to `https://picplace.co`. Editable only while signed out.

**Sign out** revokes this device on the server (`DELETE /devices/{id}`), clears the Keychain and the device-local sync states; local files are never touched.

### Sync a project (project detail › PICPLACE, or the Mac inspector)

One button, one project, push only:

1. `POST /projects/{uuid}/claim` — the write claim; if another device holds it, the card shows who until when (`failed` with the reason; `force` is a later decision).
2. `PUT /projects/{uuid}` with `name` (custom name or original name), `type` (photo / interval / video by `ProjectCategory`; scan → interval), `revision` (see §3), `captured_at` (`capture.createdAt`) and the whole `project.json` as `manifest`. Creating grants the claim to this device anyway.
3. Walk the project folder: every regular file except `project.json`, `.DS_Store`, hidden files and `tmp/`; `kind` by top-level folder (`source`, `blends → blend`, `luts → lut`, `notes → note`, `ref`, `masks → mask`; top-level sidecars → `note`); `sha256` from `assets.ndjson` when it has the file, otherwise computed (CryptoKit, streamed); bytes from the file. `POST /projects/{uuid}/assets` in batches of 100. Files whose hash and size already match come back without an upload — the second sync of an unchanged project transfers nothing.
4. `PUT` each returned URL with a `URLSession` upload task from the file, sending exactly the returned headers, four at a time; re-negotiate a URL that expired mid-run.
5. `POST /projects/{uuid}/assets/confirm` in batches; per-item errors are retried once, then reported.
6. `POST /projects/{uuid}/presence` with the revision; `DELETE /projects/{uuid}/claim`.

The whole run is one `Task`; Cancel cancels it and releases the claim. The project stays usable throughout — nothing is locked locally.

### Status

Device-local, in `UserDefaults` under `letslapse.picplace.syncStates` (a `[UUID: SyncRecord]`: `syncedAt`, `revision`, `files`, `bytes`, `lastError`, `alsoOn`). It is device state — "this device pushed this project then" — and the server is the truth for what is actually there, which the card re-reads (`GET /projects/{uuid}`) when it appears. No new file in the project folder, nothing in the index, nothing in `library.json`: the M2 list query is untouched, and the Projects-card pill reads this map.

## 3. Decisions taken in the draft (to confirm at sign-off)

1. **Revision** = `Int(capture.modifiedAt.timeIntervalSince1970 * 1000)` until the data-model programme adds a real `revision` field — monotonic as a person edits, and it is what the server compares. A replay of the same revision is accepted by the server, so a retry is safe.
2. **The nominated project is chosen by tapping Sync on its own screen.** No auto-sync, no multi-select, no "sync everything" in v1.
3. **Push only.** The app never downloads a project in v1; *Also on* is informational (the server's presence rows), exactly the §6 use in the brief.
4. **Claims are not force-taken in v1.** A claim held elsewhere is shown as the failure reason; the holder's lease lapses in ≤ 60 min.
5. **Progress is by bytes, caption by files and bytes**, so a project of three 2 GB blends and a thousand sidecars reads honestly.
6. **The list pill is a media pill on the thumbnail**, not a second text-row pill: the size row already carries the SourceFormatPill, which on an interval card with FLAT reaches the card's edge.
7. **PICPLACE sits between STORAGE and ADVANCED** in Settings, and takes the Burst-frames seat (after the actions, before management) on a project screen — it is about where the project lives.

## 4. The screens (design-first, drawn 2026-09-14)

| Where | File | Shows |
|---|---|---|
| Settings, signed out | `design/iOS/settings.picplace.signed-out.portrait.svg` | Sign in with PicPlace · Server |
| Settings, signed in | `design/iOS/settings.picplace.signed-in.portrait.svg` | Account · This device · On PicPlace · Server · Sign out… |
| Project detail (photo) | `design/iOS/project-detail.photo.picplace.portrait.svg` | the PICPLACE card, syncing |
| Projects list | `design/iOS/projects.picplace.portrait.svg` | thumbnail pills: synced, syncing |
| Mac Gallery item inspector | `design/macOS/gallery.item.picplace.svg` | the PICPLACE group, synced |
| The card's six states, two widths | `design/components/picplace-status.<state>.{phone,narrow}.svg` | signed-out · not-synced · changes · syncing · synced · failed |
| The account card's two states | `design/components/picplace-account.<state>.phone.svg` | signed-out · signed-in |
| The list pill's three states | `design/components/picplace-pill.<state>.svg` | synced · syncing · failed |

Interval and video project screens take the same card in the same seat (not drawn separately). The iPad shares the iOS spec. The Mac's Settings shares the iOS spec, as it does for every other card.

## 5. Not in v1 (and where it goes)

Downloading a project to another device; syncing many projects at once or automatically; force-taking a claim; the server's device list in the app (revoking a lost device — the server supports it); background transfers that survive the app being suspended; per-file presence tiers, journals, previews and proxies (the phase-6 programme); production hosting (Hetzner Object Storage + a scheduler cron on picplace.co — the `picplace` repo's phase 5).

## 6. Verification plan (app-first would have done this first; design-first does it after sign-off)

Against `picplace.test` with Garage: sign in on the Mac app, sync the real project `3F09DE6F-3262-4FB4-8BEA-73A8D175B271` (7 files, 5.8 MB — the one the server was verified with), watch the card through every state, confirm the bucket and the registry from the server side, sync again (zero uploads), sign out and confirm the device is revoked. Then the same on the iOS Simulator. Screenshot each mirror with `LL_TAB=settings` / `LL_DETAIL=latest` / `LL_TAB=projects` and a new `LL_PICPLACE=<state>` hook that stages the card's states without a server, so the six component files can be verified against the running app.

## 7. What shipped, and what verification found (2026-09-14)

**Code.** `App/PicPlace/`: `PicPlaceConfiguration` (the server setting and the public client id), `PicPlaceKeychain` (tokens, this device only), `PicPlaceSignIn` (PKCE in `ASWebAuthenticationSession`), `PicPlaceAPI` (wire types, bearer client with single-flight refresh), `PicPlaceSyncRun` (the push), `PicPlaceController` (session, device registration, sync records, project state; owned by `AppModel.picplace`), `PicPlaceViews` (`PicPlaceStatusCard` phone/narrow, `PicPlaceSettingsCard`, `PicPlacePill`). Seams: the PICPLACE section in `SettingsView`, the card on every `ProjectDetailView` body, the pill on `ProjectsView`'s card, the group in `GalleryPreviewPanel` (`.inspector`), the `letslapse` URL scheme and loopback ATS exceptions in `Info.plist`.

**Verified on the iPhone 16 Pro simulator** (Debug build, tokens injected with `LL_PICPLACE_TOKENS`, the real project `3F09DE6F…` seeded into the scratch library): the device registered itself (name, platform, OS, app version reached the server); Settings showed the signed-in card; the detail card went not-synced → syncing → synced with "7 files · 6,1 MB"; on the server every asset was confirmed with the hash and size of the file on the volume, the presence row named the iPhone, the claim was released and nothing was left pending; **Sync again transferred 0 files**; the Projects card wore the green pill; Sign out revoked the device on the server and cleared the local state. Three things the run corrected: the client must not claim before the first PUT (a claim on an unknown UUID is 404 — the PUT creates and claims); `GET /projects/{uuid}` is `{project, assets, manifest}`, not a bare project; and iOS's ATS blocks Garage's plain-http loopback URLs without an exception.

**Two facts for the brief.** The iOS Simulator does **not** trust Valet's CA: run `xcrun simctl keychain <udid> add-root-cert ~/.config/valet/CA/LaravelValetCASelfSigned.pem` once per simulator (the Mac app trusts it through the system keychain). The real Sign-in button — the server's own login/consent pages in a browser — is the one step Steven verifies by hand (no password is typed into a UI by an agent). On the Mac the callback delivery was verified separately: the app's own authorize URL completed with curl and the resulting `letslapse://` URL delivered through Launch Services registered the device.

**Not verified:** the Mac Gallery inspector's narrow card (`macOS/gallery.item.picplace.svg`) was not screenshotted — it sits below the inspector's fold and scrolling the Mac window headlessly was declined. The view is the same `PicPlaceStatusCard` in its `.narrow` style; the mirror stays 🟡 until Steven has looked at it (`LL_TAB=gallery LL_ITEM=<uuid> LL_PICPLACE=synced` stages it without a server).

**Hooks added:** `LL_PICPLACE=<state>` (stages every card in one of the six states, no server), `LL_PICPLACE_TOKENS=<access>:<refresh>` (signs in with tokens minted elsewhere), `LL_PICPLACE_SERVER=<url>` (overrides the server setting for the run), `LL_PICPLACE_SIGNIN=1|silent` (presses Sign in at launch; `silent` opens no browser and logs the authorize URL, so a test completes the consent itself and delivers `open -a <app> "letslapse://…"` — how the macOS Launch Services path was verified), `LL_PICPLACE_SIGNOUT=1` (starts signed out: revokes the device, clears the Keychain and defaults — how a test run leaves a shared Mac as it found it), and `LL_DETAIL` now takes a project UUID as well as `latest`.
