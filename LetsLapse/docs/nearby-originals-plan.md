# Nearby originals — import a project's originals from your own device on the same network

**Date:** 2026-09-28 · **Status:** plan written. The server ask
([picplace-nearby-key-ask.md](picplace-nearby-key-ask.md)) goes to the PicPlace
developer first; the app work follows their answers. Stage 0 needs no server.
**Working mode:** code first, SVG mirrors after sign-off (Steven, 2026-09-28).
**Read with:** [project-transfer-plan.md](project-transfer-plan.md) (the LAN
transport this reuses), [connected-asset-states-plan.md](connected-asset-states-plan.md)
(the preview page, the fetch prompt, holdings),
[picplace-sync-v2-plan.md](picplace-sync-v2-plan.md) §13 (presence tiers),
[data-model-server-portability-2026-09-12.md](data-model-server-portability-2026-09-12.md)
§3.4, which already said it: *"The existing LAN project transfer becomes the
fast transport for originals between two devices that are on the same network,
driven by the server's presence map and keyed by origin id."* This plan is that
sentence, built.

---

## 0. In short

A project that is a **preview** on one device (records and poster from
PicPlace), whose originals are only on another device of the same PicPlace
account, on the same network, gets **Import originals from iPhone 18 Pro**. The
files come over the LAN transfer that already exists, with no pairing code and
no *Share projects with nearby devices* on the phone: the account is the trust.
The button shows only when a signed-in device nearby holds all of what is
missing. Each file is checked against the preview's own `assets.ndjson` hash
and lands the way a PicPlace download does. From there the Mac's normal upload
can carry the originals to PicPlace over its better line.

## 1. The brief

Steven's words are in the ask, §1 (lightly edited). The example that prompted
it, 2026-09-28: the 18 Pro and the 16 Pro both hold *Stack 28. 9. at 8:30*;
only the 18 Pro has the originals. The 16 Pro opens the preview and reads
*Preview only — The originals are only on iPhone for now*. Today the only way
across is the 18 Pro uploading to PicPlace and the 16 Pro downloading.

## 2. Decisions

| # | Decision | Who, when | Why |
|---|---|---|---|
| N1 | **Trust is the PicPlace account**: the same `server.id` and `user.uuid`, proven by the account's nearby key (the ask). No pairing code, and no *Share projects with nearby devices* on the serving device. | Steven, 2026-09-28 ("there's trust implied") | The code exists to stop strangers. The account already decides what each device may read from PicPlace. |
| N2 | **What the account channel serves:** only projects that are on PicPlace in that account, only their heavy files (`source/`, `blends/`, by `PicPlaceSyncPolicy.isHeavy`) that the asking device's records name, and nothing else. Read-only. | Proposed 2026-09-28 | This is why skipping the opt-in is safe: it serves nothing the account couldn't already fetch from PicPlace once the files were uploaded. Projects never synced, and whole libraries, stay behind the code. |
| N3 | **A phone serves only while LetsLapse is open.** No push-to-wake. | Steven, 2026-09-28 ("no worries, all good") | iOS doesn't let an app listen in the background. |
| N4 | **A new "fill in" request, keyed by origin id**, not the Create tab's whole-project import. | Steven, 2026-09-28 | The whole-project import installs a second copy under a new local id and asks the duplicate question. That is the transferred-copy trap of 2026-09-25. |
| N5 | **Device names:** the model ("iPhone 18 Pro", "iPad Air 13-inch (M3)") where iOS gives a generic "iPhone" or "iPad". A Mac keeps its computer name. | Steven, 2026-09-28 ("happy with this") | The user's own name needs Apple's `user-assigned-device-name` entitlement. Two phones both called "iPhone" are useless on this button. |
| N6 | **Code first, SVG mirrors after sign-off.** | Steven, 2026-09-28 | Mostly business logic, with a few simple UI changes. |
| N7 | **The button shows only when it can work:** a device of the same account, reachable now, holding all of what is missing, and not busy. | Steven's brief | "It should only show itself when it's possible." |
| N8 | **Integrity comes from the asker's own records:** each file must hash to the asker's `assets.ndjson` SHA-256. Failing that, it must match the hash the serving device sends; failing that, the size. | Proposed 2026-09-28 | `assets.ndjson` travels in the records bundle, so a preview already holds every original's fingerprint. A peer can't pass off a wrong or stale file. |
| N9 | **Local network only, with nothing identifying on it.** No AWDL. A random Bonjour instance name. A discovery tag that changes daily. | Proposed 2026-09-28 | AWDL advertising slowed a 5 GB pull to 1.3 MB/s (2026-08-29). The code server's TXT broadcasts the device name and project count; this one mustn't. |
| N10 | **A switch on the serving side** (Settings ▸ PicPlace, on by default), and a chip while sending, with Stop. | Proposed 2026-09-28 | It's the person's phone: they see what's going out and can turn it off. |
| N11 | **The server ask goes first.** The app is built and benched against a staged key in the meantime. | Steven, 2026-09-28 | The key is the only server dependency, and a staged key covers everything else. |
| N12 | **Nearby comes first.** When a nearby device holds all of what is missing, it is the offer; PicPlace is the second button in the prompt. | Steven, 2026-09-28 (Q1) | Faster, and nothing is downloaded from storage. |
| N13 | **Blends are in the first version, and a blend stays one asset.** Nearby only fills the file behind a blend record the device already holds (same blend id, file name and SHA-256); it never makes a record. Deleting a blend anywhere deletes it everywhere. The tombstone syncs as it always has; new: a tombstone that arrives by pull moves this device's copy of the file to its trash, as a local delete does. | Steven, 2026-09-28 (Q2) | "When this is deleted, it should be known to be the same blend asset, so deletion would be global." Until now a blend deleted elsewhere vanished from the lists here, but its file stayed in `blends/` for good (found 2026-09-28: `applyPulledUpdate` takes the tombstone, and nothing moves the file). |
| N14 | **Several holders: pick one.** The first device to answer with all of it; if several have already answered, a Mac. No measuring. | Steven, 2026-09-28 (Q3) | Rare. "Just pick one." |
| N15 | **Nothing when the holder isn't reachable.** No button and no hint. The "only on iPhone 18 Pro for now" caption stays, since it comes from PicPlace's presence record (stage 0), not from the network. | Steven, 2026-09-28 (Q4) | A device with LetsLapse closed can't be asked what it holds. |
| N16 | **The serving switch is on by default.** | Steven, 2026-09-28 (Q5) | |
| N17 | **The server as built** (picplace `docs/letslapse-nearby-key.md`, on `picplace.test`, not deployed yet): the gate is `assets:read` plus a registered device; the key is minted at the first `GET /nearby/key`; one shared key per account. It is replaced when a device is revoked or signs out, and when a password reset — which now signs out every device (Steven's decision) — takes the account back. **No 30-day rotation** (Steven's decision): it would split devices in the field and wouldn't cut off a lost device that stays online. The app's own rule covers abandoned devices: it ignores a key `/status` hasn't confirmed for 30 days. The app drops its key on `401 device_revoked`, `403 account_not_enabled`, `404 nearby_key_disabled`, a failed refresh (the existing sign-out path) and `features.nearby_key` false. Device summaries now carry `revoked_at`: a revoked device is never named in "only on …". | PicPlace developer and Steven, 2026-09-28 | |

## 3. The flow

1. **Both devices, while LetsLapse is open:** signed in, library connected, key
   held, switch on → `NearbyService` listens and browses for
   `_letslapse-near._tcp`.
2. **B finds A:** A's TXT tag matches B's key → B opens a TLS-PSK link →
   `hello` both ways (the ids must match; each side keeps the other's name and
   model for its words).
3. **B asks:** "of these origin ids, which do you hold?" It sends this
   library's projects that are short of originals or blends. A answers per
   origin id. `NearbyHoldingsStore` on B publishes origin id → offers.
4. **B shows it:** `fetchOffer` returns `.nearby(…)` for the preview →
   **Import originals from iPhone 18 Pro · 11.2 GB** on the preview card, in the
   just-in-time prompt, and on the other doors.
5. **The press:** `requestFiles` for the shortfall → A streams the files over
   the existing frames and ack window → B hashes each file as it lands, moves it
   into place and records the hash → `noteOriginalsArrived` → presence
   `tier: original` → the preview page becomes the editor (as after a download).
6. **Afterwards:** B's originals queue can upload them to PicPlace (§10); A can
   free up space once they're there.

## 4. What exists, and what it becomes

| Piece | Where | Reused as |
|---|---|---|
| Frames, coder, reader, ack window | `Shared/ProjectTransferProtocol.swift` (`PTFrame`, `PTCoder`, `PTFrameReader`) | The same frames. New control kinds: `hello`, `holdings`, `holdingsReply`, `requestFiles`. |
| The send pump (chunked reads, `autoreleasepool`, windowed ack, cancel latch) and promote-on-`.ready` | `Shared/ProjectTransferServer.swift` (`pump`, `TransferJob`, `accept`/`promote`) | Factored out so both servers share them. Don't rewrite them: every line there paid for a device-only bug. |
| The receive half (`.part` and rename, acking after the write) | `Shared/ProjectTransferClient.swift` (`PTLink`) | The pattern, writing into the project's `tmp/` instead of `Incoming/`. |
| TLS-PSK parameters | `Shared/CaptureRemotePairing.swift` `parameters(code:salt:identity:bulkTransfer:)` | A variant that takes key bytes. The code paths stay bit-identical. |
| What is missing | Kit `ProjectHoldings.Shortfall`, `App/ProjectAvailability.swift` `availability(of:for:)` | The request's content. `fileNames` already lists a clip's alternative encodings. |
| The offer, the prompt, the preview card | `App/PicPlace/PicPlaceFetch.swift` `FetchOffer`, `App/FetchPrompt.swift`, `App/EditorPreviewPage.swift` `status` | A `.nearby` case. The card and the prompt gain its words and button. |
| Landing | `PicPlaceController.downloadOriginals` epilogue: `noteOriginalsArrived`, `assetStore.noteHashes`, presence `tier` | The same epilogue, so the preview page, the pill, the filters and the status sweep all follow unchanged. |
| Progress and Stop | `picplace.progress[captureID]` (`.downloading`), `cancelSync` | The same map, with where the files come from, so the card, the drawer and *Continue When Ready* work unchanged. |
| Busy | `AppModel.transferBlockReason`, `LibraryActivity` (`.servingTransfer`), the capture watch | The same refusals. A capture starting mid-serve aborts it. |
| Serving chip | `App/ProjectSharingChip.swift` (the Project Syncing pill and sheet) | A "Sending originals to …" line with Stop. |
| Relay | `PicPlaceAutoSync.runOriginalsQueue` (decides by what is in the folder) | Unchanged, if the bench agrees (§10). |
| Hashes | Kit `AssetHash`, `AssetRecordStore.records(inProjectFolder:)` | The integrity check (N8). |

## 5. Trust on the device (stage 1)

- **`PicPlaceNearbyKey`** (`App/PicPlace/`): reads `features.nearby_key` and
  `nearby.key_id` from `/status` (`PPStatus` gains `nearby`).
  - Fetches `GET /nearby/key` when the id differs or no key is held.
  - Stores the key in the Keychain beside the account's tokens, and deletes it
    at sign-out or disconnect.
  - Refuses a key whose last `/status` confirmation is older than 30 days.
  - An unrecognised tag on the network triggers one `/status` re-read, at most
    every 10 minutes.
- **Derivations, pure and in Kit** (`Library/NearbyTrust.swift`), tested with
  fixed vectors:
  - `psk(key, serverID, userUUID)`: HKDF-SHA256, salt
    `com.regularsteven.letslapse.nearby.v1`, info
    `tls-psk|<server.id>|<user.uuid>`;
  - `discoveryTag(key, day)`: HMAC-SHA256 under the HKDF subkey `discovery`,
    over the UTC day, first 8 bytes, base64url;
  - `accepts(tag, key, now)`: accepts yesterday's, today's and tomorrow's tag.
- **DEBUG:** `LL_NEARBY_KEY=<base64url>[:<key id>]` stages a key with no server.
  Two instances given the same key trust each other, which is how stages 2–4
  are built before the server ships. A bound bench root still launches with
  `LL_PICPLACE_TOKENS` (the Keychain prompt trap).

## 6. The service (stage 2)

- **`Shared/NearbyService.swift`** (`#if !os(watchOS)`), owned by `AppModel`
  and app-wide. It is not tied to a tab: the code server is armed by the
  Projects and Gallery views (`armsProjectSharing`), which is wrong for a
  listener the editor depends on.
  - **Runs while:** signed in, library connected, key held, and the switch on.
  - **iOS:** stops at `.background` and restarts at `.active`.
  - **Mac:** runs while the app runs. There's no idle stand-down, because it
    serves only the account's own devices.
- **Parameters:** TLS-PSK from the derived key, identity `letslapse-nearby`,
  `bulkTransfer: true`, `includePeerToPeer = false`.
  - A random instance name. The default instance name is the device's name.
  - TXT: `v` (protocol version) and `t` (discovery tag). Nothing else. (A
    holdings revision `r` was planned; asking when a page appears, and again
    at the press, makes it unnecessary.)
  - `_letslapse-near._tcp` joins the `NSBonjourServices` **array** in
    `App/Info.plist` (never an `INFOPLIST_KEY_*`: that silently emits nothing).
- **Browser:** ignores its own instance. Connects to each peer whose tag this
  key accepts, one link per peer, reused for queries. Rebuilt after `.failed`
  (`NWBrowser` never recovers on its own).
- **`hello`** both ways: `v`, `serverID`, `userUUID`, PicPlace `deviceID`,
  name, model, platform. A mismatch closes the link. The name and model feed
  B's words and A's chip.
- **`holdings`:** B asks about the projects it is showing: the preview page,
  the prompt, the project screen, the Gallery panel. Each asks when it
  appears (as `askForListing` does for PicPlace), and every new peer is asked
  about everything already wanted. A answers per origin id: whether it holds
  every original, the blend file names it holds, or `busy` with a sentence. It
  omits projects that aren't on PicPlace or aren't in its open library. An
  answer is kept for a minute, and the press asks again before anything moves.
- **`NearbyHoldingsStore`** (App) publishes origin id → offers (peer, what it
  covers, bytes). An offer is dropped when its peer's link closes or the peer
  disappears.
- **DEBUG:** `LL_NEARBY=log` logs peers, hellos and holdings answers.

## 7. The import (stage 3)

- **The request:** `requestFiles {originID, originals: [[alternatives]], blends:
  [names]}`. Each original lists the files that can stand for it (a clip's
  encodings).
  - A resolves each original to the first alternative it holds.
  - A refuses anything that isn't heavy, or whose resolved path isn't inside the
    project folder (`..`, symlinks).
  - A then sends `transferReady` with the exact files, their sizes and A's
    recorded hash per file, followed by the existing `fileBegin`, data, `ack`
    and `transferDone`.
  - A transferred copy's local id ≠ its origin id, so A looks the project up
    with `libraryIndex.projectID(originID:)`, never by the origin id itself.
- **`NearbyImportRun`** on B, shaped like `PicPlaceDownloadRun`:
  - checks storage headroom first (`AppModel.checkStorageHeadroom`);
  - writes each file into `<project>/tmp/nearby-<uuid>`, hashing as it writes
    (incremental SHA-256);
  - compares it per N8, then moves it into place and records the hash with
    `assetStore.noteHashes`;
  - ends with the download epilogue (`noteOriginalsArrived`, presence `tier`).
- **Progress** goes into `picplace.progress[captureID]` as `.downloading`, with
  where the files are coming from, so every surface that shows a download shows
  this too.
- **Stop:** the card's Stop sends a cancel frame. What landed stays, and the
  next press asks only for what is still missing, so resume comes for free.
- **Staying alive:** B holds itself with `PicPlaceBackgroundActivity` (the
  press was on B). A has to stay open (N3) and keeps its screen awake.
- **The offer:** `FetchOffer.nearby(…)` from `PicPlaceController.fetchOffer`,
  ahead of PicPlace (N12), from one device (N14). It appears on:
  - the preview card: caption plus a full-width button;
  - the prompt (`FetchPromptContent`);
  - the project screen's Originals row, the Gallery panel, and the Mac item
    view.
- **Words (drafts for Steven's copy pass):**
  - Card, not on PicPlace: *Preview only* · *The originals are only on iPhone 18
    Pro for now* · **Import originals from iPhone 18 Pro** · *11.2 GB*
  - Prompt: **Import the originals from iPhone 18 Pro?** · *Light needs the
    originals: 11.2 GB on iPhone 18 Pro, nearby. You can keep browsing while
    they come over.* · **Import and Continue** / **Stay as Is**
  - Importing: *Importing from iPhone 18 Pro · 2.1 of 11.2 GB* · Stop
  - Failed: *iPhone 18 Pro stopped sending: it's shooting right now.* (the
    serving device's own sentence)
- **DEBUG:** `LL_NEARBY_IMPORT=<latest|uuid>` presses Import once a peer offers
  it.

## 8. The serving side (stage 4)

- A answers queries without a word on screen. A transfer shows on the Project
  Syncing pill and sheet: *Sending originals to MacBook Pro · 2.1 of 11.2 GB*,
  with Stop.
- While sending, A keeps the screen awake (`isIdleTimerDisabled`, as the code
  server does) and registers `.servingTransfer`. A capture starting aborts the
  serve with its sentence. Anything in `transferBlockReason` refuses it
  up front. One serve at a time; a second asker gets `busy`.
- **Settings ▸ PicPlace:** *Let my devices import originals from this one* (on
  by default), with a footer: *Your other devices signed in to PicPlace can
  bring this device's originals over your local network while LetsLapse is
  open. Only projects on PicPlace; nothing leaves your network.* When Local
  Network access is denied, a line with *Open Settings* appears, because a
  denied permission looks exactly like "no devices nearby".
- **The iOS Local Network prompt** appears the first time the service starts.
  That moment should be right after connecting a library to PicPlace, never
  cold at launch.
- **DEBUG:** `-letslapse.nearby.serve NO` as a launch argument turns the switch
  off for a run without writing the setting.
  `LL_NEARBY_STAGE=offer|importing|sending` (staging the card and chip states
  with no peer) was planned and **not built**: the mirrors were drawn from the
  bench and from the code's own layout.

## 9. Device names and the real holder (stage 0: no server needed)

- **`DeviceName`** (`Shared/`) returns `UIDevice.current.name`, unless that is
  the generic word ("iPhone", "iPad"). Then it returns the model name from
  `utsname.machine` through a table.
  - Known from the bench: `iPhone13,3` → iPhone 12 Pro, `iPhone17,1` → iPhone
    16 Pro, `iPhone19,2` → iPhone 18 Pro, `iPad13,16` → iPad Air (5th
    generation), `iPad15,5` → iPad Air 13-inch (M3). Fill in the rest from
    `devicectl list devices` and the Simulator runtimes.
  - An unknown identifier keeps the generic word.
  - The Simulator reads `SIMULATOR_MODEL_IDENTIFIER`. The Mac keeps
    `Host.current().localizedName`.
  - Used by `POST /device` (`PicPlaceController.deviceName`, so presence rows
    and the device list update at the next registration or version report), the
    code server's TXT (`ProjectTransferServer.deviceName`), the nearby `hello`,
    and every "only on …" line.
- **Presence tier:**
  - `PPPresence` gains `tier`.
  - The sync record gains `originalsOn`: the other devices whose tier is
    `original`, freshest `confirmed_at` first, beside `alsoOn`.
  - `FetchOffer.notUploaded(device:)` names `originalsOn.first`. With none
    known, it keeps today's *the device that made them*.
  - Today it names `alsoOn.first` (`PicPlaceFetch.swift:89`): the first other
    device with any presence, which can be one holding only a preview.
- Answers part of the TODO *Copy pass — where a file is when it is not on this
  device*.

## 10. The relay (stage 5)

- B's originals queue (`runOriginalsQueue`) decides by what is in the folder:
  *"What is here decides — a pulled preview has nothing heavy."* So originals
  that arrived over the LAN on a pulled project should go up unchanged, with
  auto originals on or the card's Upload. Bench it. A's *Remove originals
  already on PicPlace* then frees the phone.
- **Both devices uploading at once:** PicPlace dedupes by SHA-256 and the
  negotiate names what is already there. The worst case is wasted bandwidth.

## 11. Stages

| Stage | What | Server | Verified by |
|---|---|---|---|
| 0 | Model names (N5); presence `tier` → the real holder in every "only on …" line | — | Mac + Simulator; the 16 Pro's notice names the 18 Pro |
| 1 | `PicPlaceNearbyKey`, `NearbyTrust` (Kit, with tests), the PSK parameters variant, `LL_NEARBY_KEY` | the ask | Kit tests; key fetch on `picplace.test` once it ships |
| 2 | `NearbyService`: listener, browser, `hello`, `holdings`; `NearbyHoldingsStore` | — (staged key) | `LL_NEARBY=log` between Mac and Simulator |
| 3 | `requestFiles`, `NearbyImportRun`, `FetchOffer.nearby`, the card, the prompt, the other doors | — | Mac ← Simulator import; Stop and press again; a damaged file refused |
| 4 | Serving chip, keep-awake, Settings switch, permission line, busy answers | — | Capture on the serving side mid-import; switch off |
| 5 | The relay (bench; code only if it fails) | — | B uploads; A frees space |
| 6 | SVG mirrors, after sign-off — **drawn 2026-09-28** | — | INDEX rows ✅ |

## 12. Bench

- **Before the server ships:** a Mac scratch root holding the preview (a pulled
  project, or `LL_DROP_SOURCES`), and a Simulator holding the originals. Both
  get the same `LL_NEARBY_KEY`. Both bound to one `picplace.test` account, so
  the projects share an origin id and the scope rule (N2) holds.
- **Two Mac instances** on one machine are possible, but macOS grants Local
  Network permission per copy of the app, so run each copy from one fixed path.
- **Devices** (ask before installing — they may be mid-shoot): 18 Pro → 16 Pro
  and 18 Pro → Mac on Wi-Fi, with a real interval shoot.
  - Measure MB/s. The Wi-Fi-only run the transfer plan still owes comes free
    here.
  - Kill the serving app mid-import, then press again.
  - Start a capture on the serving phone mid-import.
- **Throwaway projects only.** A change on a real project reaches every device.

## 13. Traps known before starting

- A denied Local Network permission looks like "no devices". `NWBrowser` never
  recovers from `.failed`: rebuild it.
- A cabled iPhone is on Wi-Fi and USB at once, so a client's connection arrives
  twice: promote on `.ready` (reuse `accept`/`promote`).
- `FileHandle.read` autoreleases inside a long pump: reuse the pump, with its
  `autoreleasepool`.
- `NWConnection.send`'s `.contentProcessed` isn't a drain signal: the ack window
  is the backpressure (reuse it).
- A transferred copy's local id ≠ its origin id: look projects up by origin id
  through the index.
- The default Bonjour instance name is the device's name: set a random one.
- The camera remote (`_letslapse-remote`) and the code server
  (`_letslapse-xfer`) may be listening at the same time. Three listeners are
  fine, but the code server's AWDL advertisement pauses during a pull
  (`llProjectTransferPullState`), and a nearby import should post the same
  notification.
- An unsigned Debug Mac build reads the Keychain with a password prompt: the
  key lives there, so bench roots use `LL_NEARBY_KEY` and `LL_PICPLACE_TOKENS`.

## 14. Questions — answered 2026-09-28

Steven answered Q1–Q5 the same day (N12–N16); the PicPlace developer answered
the ask's §8 (N17, and the ask's §10).

- **Still open:** PicPlace keeps a deleted blend's object. The app never
  deletes an asset on PicPlace, and the server's *recently deleted* covers whole
  projects only. With N13, deleting a blend clears it from every device, but
  PicPlace's copy stays. Whether PicPlace should drop a blend whose record is
  tombstoned is a server question for later.

## 15. Built, and what the bench proved (2026-09-28)

**Built, code first, uncommitted:** stages 0–4 and N13, all in one pass —
`Shared/DeviceName.swift`, the presence tier (`PPPresence.tier`,
`originalsOn`, revoked devices skipped), Kit `Library/NearbyTrust.swift`
(9 tests, vectors from an independent implementation), `App/PicPlace/PicPlaceNearbyKey.swift`,
`App/Nearby/` (`NearbyProtocol`, `NearbyService`, `NearbyLinks`), the offer
in `PicPlaceFetch.swift` (`.nearby`, `importNearby`), the prompt, the
preview page's full-width button, the project card, the collection
builder, the Project Syncing pill and sheet (*Sending originals to …* with
Stop), the Settings switch, `LibraryActivity.servingNearby`,
`_letslapse-near._tcp` in `Info.plist`, and the blend tombstone moving the
file to the trash on pull (`applyPulledUpdate`). Mac and iOS Simulator builds
clean.

**Bench, two Simulators on `picplace.test` with the real key endpoint:**

- Both fetched the same key (`nk_2fa9…`) from PicPlace and found each other
  by tag alone; the handshake named the peer (*“LetsLapse B87F…” is Nearby
  Bench A (ios)*).
- The preview page drew Steven's mock: *Preview only* · *The originals are
  only on Nearby Bench A for now* · **Import originals from Nearby Bench A**.
- The import: 12 originals, 137.8 MB, in 0.15 s over loopback; every file
  byte-identical to the sender's by SHA-256; 12 hashes recorded in
  `assets.ndjson`; nothing left in `tmp/`; the preview page became the
  editor; PicPlace's presence moved to `original`.
- **Found and fixed on the bench:** a query link was let go the moment it was
  made (its handlers held it weakly), so its connection was cancelled
  silently — the link now holds itself until it finishes. A refused Local
  Network permission logged three lines every 5 s for ever — the browser
  now backs off to a minute and logs a refusal once.
- **Trap:** the Mac bench copy (`LetsLapseRun/dd-mac`) has no Local Network
  access on this Mac (`NoAuth` from both browser and listener) — a Mac bench
  needs Steven's Allow in System Settings ▸ Privacy & Security ▸ Local
  Network. Two Simulators need nothing. And one bench token per install: a
  token reused by two installs attributes both installs' presence to one
  device row.

**Mirrors, 2026-09-28** (Steven: "commit it, then do the mirrors"): the preview page's
offer, prompt and importing states on the iPhone, the iPad (offer) and the Mac item view;
the project screen of a preview with the new `picplace-status.preview-nearby` card state;
Project Syncing while sending; the Settings account card's new row (886.8 pt). **Found
drawing them:** the project card's action *Import from iPhone 18 Pro* wraps to two lines,
and its caption, capped at two lines, is cut before the size — Steven's call; the card
keeps the grey camera where the editor page slashes it; the Gallery pill ignores nearby
devices (right: it says what PicPlace and this device hold).

**Not yet verified:** a Mac importing; Stop mid-transfer and the *Sending
originals to …* row (the Simulator send is too fast to see); real Wi-Fi
speed; a blend import; N13 on a real pull; the device run on picplace.co
(the PicPlace developer's script).

## 16. Later

- Blends from nearby in the blend row and the collection builder.
- The Create tab's device import skipping the code for same-account devices
  (PicPlace projects only, per N2).
- Several peers at once, a file each.
- Peer-to-peer Wi-Fi in the field (no shared network), where AWDL is worth its
  cost.
- Per-device keys (ask §5), if the shared key's rotation ever chafes.
