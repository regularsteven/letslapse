# Import a project from another device — implementation plan

**Status:** **Phase 1 implemented 2026-08-27** (iOS serves → Mac imports);
Phases 2–3 open · **Raised:** 2026-08-27 ·
**Revised:** 2026-08-27 (payload strategy, resume, AirDrop/USB) · Branch `ios-app`

> **What the implementation actually did, where it differs from this document.**
> The plan below is unedited; these are the departures, all of them narrowings.
>
> - **Service and salt.** `_letslapse-xfer._tcp` and
>   `com.regularsteven.letslapse.transfer.v1`, not `_letslapse-library._tcp` /
>   `…library.v1` (§2). Purpose-scoping is intact; only the strings differ.
> - **No resume in Phase 1.** `requestTransfer` carries no `have` set (§3), so
>   §4's reconciliation does not exist yet and a dropped pull discards its
>   partial tree rather than leaving disk nobody can spend. Everything the
>   resume needs is in place around it: `Incoming/<sourceProjectID>/` inside the
>   library root, `.part`-then-rename as the commit, `"Incoming"` in
>   `libraryItemNames`, and a 24-hour launch sweep. **Settings ▸ Incomplete
>   Transfers is therefore not built** — with nothing to resume, the row would
>   only ever offer Discard, which the sweep already does.
> - **Frame types.** Three, not four: `control` (0x01), `data` (0x02),
>   `cancel` (0x03). `fileEnd` and `blob` are unnecessary once the manifest
>   travels whole in `transferReady` and thumbnails ride inside the list reply
>   (budgeted to 3 MB, dropping rather than overflowing the control cap).
> - **`LibraryActivity`** shipped with five cases — capture, blending,
>   exportingArchive(UUID), importingArchive, servingTransfer — not the seven of
>   §5; collection export and the storage move are not yet bracketed.
> - **Serving is `#if os(iOS)`**, not Shared-and-platform-neutral (§2's last
>   subsection anticipated the Mac's serving UI landing in Phase 3; its listener
>   is scoped the same way until then).
> - **`.capture` is bracketed in `CaptureView`** (`configureOnAppear` /
>   `cleanUpOnDisappear`), as §5's table says, rather than in
>   `CameraController` — which holds no reference to the model.
>
> ### §3's backpressure recipe is wrong, and only a device says so
>
> **`NWConnection.send`'s `.contentProcessed` completion is not a drain
> signal.** It fires when the framework has TAKEN the bytes, so the counting
> semaphore §3 prescribes bounds concurrent *send calls* and nothing else. It
> also brought two hazards of its own, both of which fired here:
>
> - A drain that took its permits without handing them back **killed the app on
>   every completed transfer** — libdispatch traps (`EXC_BREAKPOINT` in
>   `_dispatch_semaphore_dispose`) on disposing a semaphore below its initial
>   value. On the client this looked like the connection closing one frame short
>   of `transferDone`, i.e. like a protocol bug.
> - An unbounded `wait()` **parked the pump forever** when a killed peer left
>   send completions that never fired, and `pumpQueue` is serial — so every
>   later transfer logged "serving N files" and then sent nothing at all.
>
> The semaphore is gone. **A windowed ack replaces it**: the client sends a
> cumulative `ack` every 8 MB (and once more when it has everything), and the
> server never runs more than 32 MB ahead of bytes the client has *written to
> disk*. That is real end-to-end flow control, it does not depend on unproven
> transport semantics, and it costs about five small frames a second. It also
> replaces the drain: `transferDone` now waits for every byte to be acked,
> which is a stronger guarantee than the old one.
>
> ### The bug the backpressure was hiding
>
> **`FileHandle.read` autoreleases, and the pump is one long-running
> synchronous block** — so its implicit autorelease pool never drains and every
> 4 MB chunk of a 12 GB project is held until the last one lands. Measured on
> the iPhone 16 Pro: `phys_footprint` tracked bytes read one for one (5.16 GB
> read, 5233 MB resident), then memory pressure collapsed flash reads from
> 972 MB/s to 0.3 MB/s — which from the client is indistinguishable from a
> network problem. `autoreleasepool` per chunk fixes it. Proved with
> `LL_TRANSFER_SINK=null`: with `connection.send` never called at all the growth
> was identical, which ruled the send queue out.
>
> **A simulator cannot show either of these** — the payloads are kilobytes and
> the memory is the Mac's. §8's Phase 0 item 3 ("does backpressure hold? push
> 2 GB between two Macs and watch RSS") would have missed it for the same
> reason: it has to be the phone, and it has to be gigabytes.
>
> ### Two more device-only findings
>
> - **A cabled iPhone is on Wi-Fi *and* USB at once**, so one client connection
>   races both interfaces and the listener sees TWO inbound connections
>   milliseconds apart. §2's newest-wins rule (inherited from
>   `CaptureRemoteListener`) then kills one at random, and half the time it is
>   the one the client settled on — an intermittent connect-then-close, only on
>   a cabled device. Fixed by promoting a newcomer on `.ready` rather than on
>   arrival, which keeps newest-wins without the race.
> - **§6's interface question is answered:** a USB-tethered iPhone 16 Pro
>   reports `wiredEthernet` (twice) alongside `wifi`. Because it is genuinely on
>   both, the picker shows no label at all — which is the designed behaviour,
>   and `transfer_probe` prints the raw list for anyone who needs it.
>
> ### Verified 2026-08-27, on Steven's iPhone 16 Pro over USB
>
> | | |
> | --- | --- |
> | 11 GB project (612 files, 603 DNGs + blends) | byte-for-byte, 267 s, **41 MB/s sustained** |
> | Peak app footprint over that transfer | **90 MB** (was 5+ GB) |
> | Ack window depth | 34 MB max against a 32 MB bound |
> | Client killed at 25% | server aborts in 0.7 s and serves complete transfers immediately after |
> | Library listing | 293 projects in ~0.4 s, 5/5 consecutive runs |
> | Real Mac Import window | phone → Mac, installed, "Import complete" |
> | Wrong code | `-9846 bad MAC` on the server, client reports it on the 8 s timeout |
>
> **Still owed:** a Wi-Fi-only run of the same size (every run above had the
> cable available), and iPad→Mac.

Move a whole project (~1–20 GB for a real shoot) from one LetsLapse to another
over the local network, with no intermediate file written on either device and
no cable required.

Required combinations: iPhone→Mac, iPad→Mac, iPhone→iPad, iPad→iPhone,
iPhone→iPhone. The **server** is the device holding the project; it shows a
six-digit code. The **client** enters the code and pulls. Mac initiates;
iOS also initiates from the library. Foreground-only on iOS, by platform rule.

AirDrop and USB are covered in §6 — one is already supported and needs no work,
the other comes free with the design below.

**A transfer never deletes anything on the serving device.** It is a copy, in
both directions, always. There is no "move" and this is not an oversight; see
§9.4.

---

## 0. What the existing code already gives us

| Piece | Where | Verdict |
| --- | --- | --- |
| TLS-PSK from a 6-digit code (HKDF-SHA256) | `Shared/CaptureRemotePairing.swift` | **Reuse**, with a purpose-scoped salt |
| Bonjour advertise + browse | `Shared/CaptureRemoteListener.swift`, `Shared/LocalNetworkTransport.swift` | **Pattern to copy**, not to extend |
| 4-byte length + JSON framing | `Shared/CaptureRemoteFrame.swift:37` | Shape to copy; the 1 MB cap is baked into `decodeLength` |
| Apple Archive (lzfse) whole-directory read/write | `Kit/.../DirectoryArchive.swift` | **Untouched** — stays the `.lapse` file format; see §1 |
| Archive → library install (UUID minting, duplicate question, blend re-keying) | `AppModel.importProject(from:)` — `AppModel.swift:6581` | **Reuse**, after a split |
| Import progress sheet | `App/ProjectImport.swift` | Reuse, with new phases |
| `.lapse` export + share sheet (AirDrop) | `AppModel.exportProject` `:6479`, `App/ProjectArchiveShare.swift` | **Already ships**; §6 |

Two things it does **not** give us, and both are load-bearing:

1. **The capture listener is tied to the capture screen.** It starts and stops
   from `WatchRemoteControlReceiver.setCommandHandler` (`CaptureView.swift:858`
   / `:1280`), which is exactly right for a camera remote and useless for
   serving a library. A separate listener is not a nicety — the two have
   different lifetimes, different threat surfaces (start a recording vs. read
   every project on the device), and different traffic shapes.
2. **There is no central "the app is busy" flag.** Capture lives in
   `CameraController.isBusy` (`CameraController.swift:4400`), which `AppModel`
   cannot see; blending is `AppModel.stage == .processing`
   (`AppModel.swift:1519` uses exactly this to refuse a delete); archive export
   is `@State private var isExportingArchive` inside `ProjectDetailView` and
   `ScanDetailView`; collection export is `CollectionExportController.state`,
   owned by the screen; a library relocation is `StorageRelocation.phase`.
   Three of the six are view-local and invisible to any server. **Section 5
   fixes this and everything else depends on it.**

---

## 1. Payload strategy — the decision everything else hangs off

Three ways to put a project on the wire. This section supersedes the earlier
draft's assumption that the payload is an Apple Archive stream.

### A. Archive stream (original plan)

Point `DirectoryArchive.write` at the socket instead of a file, via
`ArchiveByteStream.customStream(instance:)`, and extract on the other side the
same way.

**Verified mechanically:** `ArchiveByteStream.customStream(instance:)` takes any
`ArchiveByteStreamProtocol` and a hand-rolled conformance type-checks against the
iOS 26.1 SDK (probed 2026-08-27). The full requirement set is:

```swift
func read(into: UnsafeMutableRawBufferPointer) throws -> Int
func read(into: UnsafeMutableRawBufferPointer, atOffset: Int64) throws -> Int
func write(from: UnsafeRawBufferPointer) throws -> Int
func write(from: UnsafeRawBufferPointer, atOffset: Int64) throws -> Int
func seek(toOffset: Int64, relativeTo: FileDescriptor.SeekOrigin) throws -> Int64
func cancel()
func close() throws
```

The two `atOffset` variants and `seek` are the risk: a socket cannot serve them,
and whether `ArchiveStream.decodeStream(readingFrom:)` ever calls them is
unproven. **Unresolved — treat the spike as genuinely required** (§8, Phase 0).

- 1× disk on the receiving side (nothing spooled).
- **No resume.** A sequential lzfse stream has no chunk index and no "start at
  entry N" facility. An interruption at 90% throws away 90%.
- Costs a full compression pass on the serving phone.

### B. Spool the archive to a temp file, then use the existing import

Two lines of integration — receive to `ImportStaging.makeURL()`, call
`openArchive(at:)`, done.

- **2× disk transiently** — 40 GB for a 20 GB shoot, which no 128 GB iPhone has.
  That disk cost is the whole objection to `.lapse`-over-AirDrop that this
  feature exists to remove, so re-introducing it undercuts the point.
- Resume is *theoretically* available (byte-offset restart into the spooled
  file), but Apple Archive still cannot start decoding at entry N, so the only
  thing resumed is the download — and only if the server can re-read from an
  arbitrary offset in a stream it regenerates. In practice: still a full restart.

### C. File-by-file — **recommended**

Send the project's files individually. `project.json` (the
`ProjectArchiveManifest`, generated in memory) and the file list travel first, so
the client knows the shape of the job before a payload byte moves; then each file
in turn, framed by name and length. No archive is built on either side.

Why this is the better shape for *this* content:

- **Resume is nearly free, and the filesystem is the ledger.** The client stages
  into a named directory keyed by the source project's id, writes each file as
  `<name>.part` and renames on completion. On reconnect it walks the staging tree,
  sends the set of files it already holds intact, and the server sends only the
  rest. No offsets, no bookkeeping file to keep in sync with reality, no
  half-written file mistaken for a complete one.
- **Compression buys almost nothing here.** DNG is already lossless-JPEG
  compressed, ProRes is already compressed, HEVC/H.264 more so. lzfse over a real
  DNG shoot is close to a no-op, which is why `exportProject` already denominates
  its storage check against the *uncompressed* size (`AppModel.swift:6499` says so
  in as many words). We are paying a full compression pass for a rounding error.
- **It takes heat off the serving phone.** These devices are thermally marginal
  under sustained load — that is the recurring finding of every bench in
  `docs/fieldtests/`. A 20 GB lzfse pass on an iPhone that is about to be asked to
  shoot again is a cost with no return.
- **The server does less work and holds less state.** Open a file, read 1 MB at a
  time, send, close. No AppleArchive worker threads, no custom byte-stream
  conformance, no `seek`/`atOffset` question at all — **Phase 0's riskiest
  unknown disappears if this path is chosen.**
- **1× disk on the receiving side**, same as (A).
- The install half is *already* tree-shaped: `installStagedProject` (§4) takes an
  unpacked directory, which is exactly what file-by-file produces. (A) and (B)
  both have to unpack into that same shape first.

Honest costs:

- **Per-file overhead.** An interval shoot is thousands of DNGs. Two control
  frames per file at ~120 bytes is ~1.2 MB across 5 000 files against a 15 GB
  payload — negligible, *provided the stream is pipelined and never round-trips
  per file*. That is a design constraint, not an assumption: the server writes
  `fileBegin` / data / `fileEnd` back to back and never waits for an ack.
- **No single integrity unit.** Mitigated by per-file byte counts and the
  rename-on-complete rule; a truncated file is a `.part` and is simply re-fetched.
- **The file list itself is large.** 5 000 entries of `{path, bytes, mtime}` is
  ~400 KB of JSON, uncomfortably close to a 1 MB control cap. It travels as a
  `blob` frame, lzfse-compressed — the one place in this protocol where
  compression genuinely pays, because path strings are hugely repetitive.
- **A second payload path to maintain** beside `DirectoryArchive`. But
  `DirectoryArchive` is untouched by this and keeps serving `.lapse` files for
  Finder, the share sheet and AirDrop; the two do not interfere.

### The file list, and the allowlist trap

Enumeration walks exactly the subfolders the installer will accept —
`["source", "blends", "notes"]` (`AppModel.swift:6677`). Anything outside that
list is silently dropped at install today, so sending it would waste hours of
transfer on bytes that get deleted. **Both ends must read the same constant**:
lift that array into one `ProjectArchive.transferableSubfolders` and have the
enumerator, the installer and the archive path share it. A new project subfolder
added later that misses this constant does not travel — the same trap the
existing import comment warns about, now with a second victim.

File identity for resume is `(path, bytes, mtime)`, all three matching. Path and
size alone would be sound for `source/` — captured frames are immutable — but
`blends/` and `notes/` can be replaced in place by a re-render or a re-recorded
note, and a stale file that happens to match a size would install silently wrong.
mtime is free to read and closes that.

### Recommendation

**Go file-by-file (C).** It is resume-friendly, thermally cheaper, disk-optimal,
removes the plan's biggest unknown, and forfeits a compression saving that is
close to zero on this content. Phase 0 measures the last claim on real footage
before it is committed to (§8) — if lzfse turns out to save more than ~5% on a
representative shoot, reopen the question.

Keep (A) documented as the fallback: if per-file bookkeeping proves worse in
practice than expected, the archive stream is still a working design and the
protocol below carries it without change (a single "file" whose name is
`project.lapse`).

---

## 2. `ProjectTransferServer`

### Service identity

```swift
enum ProjectTransferService {
    static let type = "_letslapse-library._tcp"   // NEW — not _letslapse-remote._tcp
    enum TXTKey {
        static let deviceName  = "name"
        static let model       = "model"
        static let pairingID   = "pid"     // purpose-scoped, see below
        static let projectCount = "n"      // so the picker can say "12 projects"
        static let busy        = "busy"    // "0" / "1" — greys the row before you pair
        static let version     = "v"       // protocol version, so a client can refuse early
    }
}
```

`_letslapse-library._tcp` must be added to the `NSBonjourServices` **array** in
`App/Info.plist`. That key cannot be an `INFOPLIST_KEY_*` build setting — Xcode's
generator silently emits an empty value for arrays, and browsing then finds
nothing with no error to explain why (the comment at `App/Info.plist` says this
already; it is the single most likely way this feature ships broken).

**Listen on every interface.** Do not set `requiredInterfaceType` or
`prohibitedInterfaceTypes` on the listener's parameters, and set
`includePeerToPeer = true`. This is what makes §6's USB path work for free, and
it matches what `LocalNetworkTransport.startBrowsing` already does
(`LocalNetworkTransport.swift:66-70`).

### Lifetime

The listener is **armed by a human act and stands down on its own.** It is not
tied to a screen, and it is not on because the build supports it.

Starts when *all* of:
- `ProjectTransferServer.enabledKey` (`"transfer.allowLibrarySharing"`) is on —
  a Settings ▸ Advanced opt-in, separate from `remote.allowRemoteAccess`.
  Serving the library and driving the shutter are different grants.
- The human tapped **Share to nearby device** (Projects tab or Settings), which
  mints a code and opens the serving sheet.

Stops when *any* of:
- The human taps **Stop sharing**.
- The app backgrounds (`scenePhase == .background`) — iOS suspends network
  activity anyway, so this only makes the stand-down honest rather than silent.
  This is true over USB as well as Wi-Fi: a cable does not buy background time.
- The capture screen opens. A shoot always wins; an in-flight transfer is
  aborted with `error: "capture started"` rather than throttling the camera.
- Idle timeout: 15 minutes with no connection and no transfer. A code left
  advertising on a phone in a bag is the failure mode to design out.

It explicitly **survives tab switches and navigation** — that is the point of
not hanging it off a screen. The serving sheet can be dismissed while the
server keeps running; a chip in the Projects header says so and is the way back.

### Pairing

Reuse `CaptureRemotePairing`, parameterised by purpose so a code minted for one
channel cannot be replayed against the other:

```swift
enum Purpose: String {
    case captureRemote  = "com.regularsteven.letslapse.remote.v1"     // existing salt — unchanged
    case libraryTransfer = "com.regularsteven.letslapse.library.v1"
}
static func derivedKey(code: String, purpose: Purpose = .captureRemote) -> Data
static func pairingID(code: String, purpose: Purpose = .captureRemote) -> String
static func parameters(code: String, purpose: Purpose = .captureRemote) -> NWParameters
```

Defaulted so every existing call site compiles unchanged and the capture link's
wire behaviour is bit-identical.

`parameters` also needs transfer-shaped TCP. The capture link sets
`keepaliveIdle = 5, keepaliveCount = 2, keepaliveInterval = 2` so a window-mounted
iPad dropping off Wi-Fi surfaces in seconds. That is right for a control link and
wrong for a 40-minute bulk transfer over a congested 2.4 GHz network: use
`idle 20 / count 3 / interval 5` for `.libraryTransfer`, and leave `noDelay` off
(bulk chunks fill segments on their own; Nagle helps the control frames coalesce).

**Say the threat plainly in the UI:** the code grants read access to *every*
project in the library, not the one you are looking at. The serving sheet should
say "Anyone with this code can see and copy every project on this device", and
the code should rotate on every arm.

### What it serves

- `hello` — who this is, protocol version, and whether it is busy right now.
- `listProjects` — metadata only, no images (see §3 for why).
- `thumbnail(id:)` — one ≤320pt-long-edge JPEG, fetched lazily per visible row.
- `requestProject(id:have:)` — the manifest and file list, then the files the
  client does not already hold.

It never writes to the library and never deletes from it. The serving side of
this feature is read-only by construction, which is worth keeping true as it
grows: a "Move" affordance would break that property, and §9.4 declines it.

Project metadata comes from `AppModel.captures` + `AppModel.blends(for:)`, sized
with `AppModel.directorySize(_:)` (`AppModel.swift:3619`, already `nonisolated`)
against `captureFolderURL(for:)`. Sizing 40 projects walks 40 directory trees, so
it is done once on arm, off the main actor, and cached until the library changes.
Thumbnails come from `AppModel.thumbnailURL(for:)` (`AppModel.swift:1091`) via the
existing `ProjectThumbnailCache` — note the known trap that on iOS a DNG has no
preview IFD and costs a full RAW decode per tile, which is exactly why they are
lazy and not bundled into the list reply.

### Where the serving UI lives on iOS

**Projects tab**, not the capture screen and not buried in Settings.

- `ProjectsView` header (`ProjectsView.swift:122`) gains a **Share** control in
  the title row — an icon button beside "Projects", opening `ProjectServingSheet`.
- While serving, the header shows a persistent chip modelled on `RemoteLinkChip`
  (`App/RemoteLinkChip.swift`): amber dot + "Sharing" + the spaced code, green +
  "Sending to iPad" during a transfer. Tapping it reopens the sheet.
- Settings ▸ Advanced gets the opt-in toggle and a secondary "Share to nearby
  device" row, so the feature is discoverable from where the sibling toggle lives.
- **Not** on the capture screen: `RemoteLinkChip`'s doc comment explains why the
  capture code lives there (it is regenerated every time that screen appears).
  This code has a different lifetime and must not be read off that screen.

The scans tab serves its projects too — a scan is a `CaptureProject` and travels
through the identical path; no separate handling.

### macOS: serve as well as import?

**Import-only in Phases 1–2; serving lands in Phase 3.** The code is written to
be platform-neutral from day one (`ProjectTransferServer` goes in `Shared/`,
compiled into both targets), but the Mac's serving *UI* and its lifetime rules
are deferred:

- Value asymmetry: the reason this feature exists is that a phone's library is
  hard to get off. A Mac's library is already reachable over Finder, Time
  Machine, and a `.lapse` export to any disk.
- The Mac has no scene-phase stand-down and no foreground rule, so "when does it
  stop advertising" is a genuinely different question that deserves its own pass.
- The Mac already runs a browse loop for the camera remote; adding a second
  advertised service on the same host that a second Mac could browse is the
  configuration most likely to surface the "one control link at a time" class of
  bug the bench notes warn about.

---

## 3. Protocol

One `NWConnection`, two phases, length-prefixed frames throughout.

### Framing

New coder in `Shared/ProjectTransferProtocol.swift`. **Not** an extension of
`CaptureRemoteCoder`: that format is a bare 4-byte length with no room for a
type discriminator, and its 1 MB cap lives inside `decodeLength` where every
existing reader depends on it. The new one keeps the same *shape* (big-endian
length prefix, JSON bodies) so the CLI provers can read both.

```
┌────────┬──────────────────┬───────────────┐
│ 1 byte │ 4 bytes BE       │ length bytes  │
│ type   │ payload length   │ payload       │
└────────┴──────────────────┴───────────────┘
```

| type | name | payload | cap |
| --- | --- | --- | --- |
| `0x01` | `control` | JSON `{id, kind, body}` — same envelope as `CaptureRemoteFrame` | 1 MB |
| `0x02` | `data` | raw bytes of the file currently open | 4 MB |
| `0x03` | `fileEnd` | JSON `{path, bytes}` | 1 KB |
| `0x04` | `blob` | JSON header then raw bytes — thumbnails, and the lzfse-compressed file list | 8 MB |

`kind` stays `command` / `reply` / `push`, and `id` correlates replies exactly as
the capture link does. Copying that envelope is deliberate: a push landing
mid-flight must never be mistaken for a reply, and that lesson is already paid
for in `CaptureRemoteFrame`'s doc comment.

### Command vocabulary

```
→ hello {clientName, protocolVersion}
← reply {protocolVersion, deviceName, model, appVersion, busy, busyReason?}

→ listProjects {}
← reply {projects: [{id, name, kind, mode, createdAt, frameCount,
                     durationSeconds?, bytes, blendCount, hasThumbnail}]}

→ thumbnail {id}
← blob   (JPEG, ≤320pt long edge)

→ requestProject {id, have: [{path, bytes, mtime}]}      // `have` empty on a fresh pull
← reply {name, projectID, manifest: <ProjectArchiveManifest>,
         files: <blob ref>, totalBytes, remainingBytes}
← blob  (lzfse JSON: [{path, bytes, mtime}] — the whole project, not the delta)
← control fileBegin {path, bytes}
← data … data …
← fileEnd {path, bytes}
← … repeated, pipelined, no acks …
← reply {complete: true, files: N, bytes: M}
   — or —
← reply {error: "busy" | "gone" | "readFailed", message: "<human sentence>"}

→ cancel {}                       (valid at any time, including mid-stream)
← reply {cancelled: true}         (server stops writing, connection stays usable)
```

`totalBytes` is the whole project; `remainingBytes` is what this pull will
actually send after `have` is subtracted, and is what the progress bar
denominates against. Both are uncompressed byte counts — there is no compression
on the payload path, so for the first time the number the UI shows is simply the
truth rather than an estimate. `ProjectImportSheet`'s "about" hedging can go for
the network case.

Ordering: `project.json` first, then `source/` in name order, then `blends/`,
then `notes/`. Name order matters: it makes a resumed pull prefix-shaped and
progress monotonic, so "78%" after a reconnect means the same thing it meant
before the drop.

### Why chunks, not "flush until close"

Flushing until the connection closes is simpler and loses three things we need:

1. **Cancel mid-stream.** The client must be able to stop a 20 GB pull at 3 GB
   and keep the link for a second attempt.
2. **Failure after the first byte.** A disk read error at 12 GB in has to arrive
   as an error, not as a truncated payload that installs as a broken project.
3. **Framing per file**, which is what makes resume work at all.

The cost is 5 bytes per ~1 MB chunk.

### Backpressure — the detail that decides whether this ships

The server reads from disk far faster than a phone's Wi-Fi drains, and
`NWConnection.send` queues without bound. Left alone, a 20 GB transfer grows a
multi-gigabyte send queue and the app is jetsammed.

The send loop must **block** until the connection has accepted the bytes: a
counting semaphore signalled from the `.contentProcessed` completion, capped at
4 in-flight 1 MB chunks, with the file read loop on a utility-QoS worker so the
blocking never touches the main actor.

File-by-file makes this simpler than the archive path would: the read loop is
ours, so the semaphore sits in plain code instead of inside an
`ArchiveByteStreamProtocol.write(from:)` conformance called from AppleArchive's
worker threads. Cancel is a latch checked between chunks.

**The server must keep reading control frames while streaming.** Receive loop and
send pump are independent; a `cancel` arriving mid-stream is the whole point.

---

## 4. Import client

### Where it lives

- **iOS — Projects tab.** Same overflow menu as Share: **Import from nearby
  device**, opening `ProjectTransferImportView` as a sheet. Also a row in
  `CreateView`'s source list beside the existing "Import project" `fileImporter`
  (`CreateView.swift:157`), because Create is where "bring something in" already
  lives. Both open the same view.
- **macOS — a new `Window` scene**, `id: "library-transfer"`, titled "Import from
  Device", ⌘⇧I. Not a section in `RemoteWindow`: that window is pinned to
  208×248 pt because Watch layout parity is its entire reason for existing
  (`RemoteWindow.swift:20-23`), and a project list with sizes and a progress bar
  cannot live in a Watch canvas without wrecking the thing it exists to protect.
  It reuses `RemoteWindow`'s browse/pair *chrome* as a shared subview.

### Flow

1. Browse `_letslapse-library._tcp`. Rows show name, model, project count, the
   interface the device was found on (§6), and grey out with "Busy — shooting"
   when TXT `busy=1`.
2. Tap a device → 6-digit field → Connect.
   **A wrong code never fails the client** — it surfaces as `-9846 bad MAC` on
   the *server's* first read and this side sits in `.preparing` forever. Copy
   `LocalNetworkTransport`'s 8-second timeout verbatim
   (`LocalNetworkTransport.swift:131`); this is a solved problem that will
   otherwise be re-discovered.
3. `hello` → `listProjects` → a list with names, dates, frame counts, sizes;
   thumbnails fill in lazily. A project with a resumable partial transfer on this
   device is badged **"7.2 GB of 12.4 GB already here"**.
4. Tap a project → confirm against free space → `requestProject(id:have:)`.
5. Progress bar over `remainingBytes`, then the install phase.
6. Done — the project appears in the library and opens, via the existing
   `AppModel.show(_:)`.

### Staging, and resume

Resume needs the partial tree to outlive the connection, the sheet, and the app,
which rules out `ImportStaging`'s current home: it stages under
`FileManager.default.temporaryDirectory` and sweeps anything untouched for
15 minutes at launch (`ProjectImport.swift:154-189`). That sweep exists for good
reason and must not be weakened — so network transfers get their own place:

```
<StorageRoot.current>/Incoming/<sourceProjectID>/
    transfer.json          peer name, project id + name, totalBytes, startedAt,
                           lastSeenAt, the manifest as received
    source/… blends/… notes/…      files landed so far
    <anything>.part        the file in flight when the link dropped
```

- **`"Incoming"` must be added to `StorageLocation.libraryItemNames`**
  (`StorageLocation.swift:35`). That array is the definition of what a library
  *is* for the purposes of a storage-location move, and its own comment says a new
  top-level item that misses it gets left behind. A half-finished 12 GB transfer
  stranded on the old volume by a location change is exactly the silent failure
  that list exists to prevent.
- A `.part` file is never trusted: it is deleted and its file re-requested. The
  rename from `.part` to the final name is the commit.
- The `have` set sent on reconnect is every file whose final name exists *and*
  whose `bytes` and `mtime` match the stored manifest. Anything else is re-pulled.
- Settings ▸ Storage grows an **Incomplete Transfers** row — resume or discard,
  with the size reclaimed shown. This mirrors the **Incomplete Captures** row that
  already exists for orphaned capture logs (`SettingsView.swift:922`), which is
  the same problem (a killed process left gigabytes nobody can see) with the same
  answer. Without it, a discarded transfer is invisible disk the user cannot
  reclaim without deleting the app.
- Discard policy: an `Incoming/` entry untouched for 14 days is offered for
  deletion at launch rather than deleted silently — it may be the only copy of
  half a shoot someone is mid-way through rescuing.

### Feeding `AppModel`'s import path

`importProject(from:)` (`AppModel.swift:6581`) does two separable jobs. Split it:

```swift
// A — source-specific: produce a staged tree
private func stageArchive(from url: URL, into staging: URL, …) async throws

// B — source-agnostic: everything from `phase = .installing` onward
//     (manifest read + version check, duplicate question, fresh UUIDs,
//      the ["source","blends","notes"] move, blend re-keying, persistLibrary,
//      stills-metadata catch-up, show)
private func installStagedProject(at staging: URL, …) async throws
```

Half B is `AppModel.swift:6636–6718` lifted wholesale, unchanged in behaviour.
Half A gets a network sibling. `openArchive(at:)` stays the single door for
files; the network path calls its own entry, `receiveProject(from:)`, which
shares the same `archiveImport` queue so two imports can never race for the disk
(the existing `archiveImportURLs` serialisation is there for exactly that reason).

File-by-file lands directly in the shape half B wants, so there is no unpack step
between them at all — the staged tree simply *is* the received tree, and install
is a rename plus the manifest work. That is the second structural argument for §1
(C): the archive paths both have to materialise this same tree first.

`ArchiveImport` (`ProjectImport.swift:15`) gains:
- `Phase.receiving(files: Int, of: Int)` — the network's own phase, `fraction`
  over `remainingBytes`.
- `var peerName: String?` — so the sheet can say "from Steven's iPhone".
- `var resumedBytes: Int64` — so a resumed pull's bar starts where it left off
  instead of at zero, which would read as lost work.

### Error handling

| Failure | Client behaviour |
| --- | --- |
| Wrong code | 8-second timeout → "Couldn't pair — check the code on the other device" (the `-9846` trap above) |
| Device goes away mid-transfer | Keepalive (20/3/5) or a short read → the sheet offers **Resume** and **Discard**; the staging tree survives either way until the human answers or the 14-day sweep. **Never a partial project in the library** — nothing is published until every file has landed |
| Storage full on the import side | Pre-check `remainingBytes` against `volumeAvailableCapacityForImportantUsage` *before* sending `requestProject`, reusing `AppModel.ImportError.insufficientStorage`'s wording. Re-check every ~500 MB mid-stream and stop with the honest message — a partial transfer is resumable once space is freed, which makes this recoverable rather than fatal |
| Server busy | `requestProject` refused with `busyReason` → the row greys and shows the sentence verbatim. No retry loop |
| Server's project deleted between list and request | `error: "gone"` → refresh the list |
| A file vanishes server-side mid-pull | `error: "readFailed"` naming the file. Everything already landed stays staged; a later resume re-reconciles against the fresh file list |
| Project changed server-side between pulls (a new blend rendered) | The file list is re-sent whole on every `requestProject`, so the client reconciles: new files are fetched, files that no longer exist are dropped from staging |
| App backgrounded on the *client* mid-transfer | Treated as a drop, and now recoverable: the partial tree persists and Resume picks it up. The sheet still says "Keep LetsLapse open" rather than pretending to survive it |
| Two clients at once | The listener holds one peer, newest wins — the same rule and the same reasoning as `CaptureRemoteListener.accept` (`:132`). An in-flight transfer is aborted for the newcomer, which is worth a log line and a sentence in the serving sheet. The evicted client resumes |

---

## 5. Lifetime / state guards — the prerequisite

There is no flag to read. Add one.

```swift
// AppModel
enum LibraryActivity: String, CaseIterable {
    case capture, blend, archiveExport, collectionExport, archiveImport,
         storageMove, projectTransfer

    var sentence: String {   // what the wire carries and the client shows
        switch self {
        case .capture:          return "This device is shooting right now."
        case .blend:            return "This device is rendering a blend."
        …
        }
    }
}

@Published private(set) var activities: Set<LibraryActivity> = []
func begin(_ activity: LibraryActivity)
func end(_ activity: LibraryActivity)
var transferBlockReason: String? { activities.subtracting([.projectTransfer]).first?.sentence }
```

Registration sites (all one-line brackets, no behaviour change):

| Activity | Where | Current signal |
| --- | --- | --- |
| `.capture` | `CaptureView.setUpForAppear` / `cleanUpOnDisappear` — beside the existing `watchRemote.setCommandHandler` pair at `CaptureView.swift:858` / `:1280` | `CameraController.isBusy` is unreachable from the model; the screen bracket is the existing cross-object convention |
| `.blend` | `AppModel.startProcessing` (`:3732`) and the `blendTask` completion / `cancelProcessing` (`:2451`) | `stage == .processing` — could be derived, but a token is cheaper to reason about than a stage enum that also means "the flow is on screen" |
| `.archiveExport` | `ProjectDetailView.swift:1309`, `ScanDetailView.swift:716` | `@State isExportingArchive` — invisible to the model today |
| `.collectionExport` | `CollectionExportController.start` / terminal states | `state == .exporting` |
| `.archiveImport` | `AppModel.importProject` / `receiveProject` | `archiveImport != nil` |
| `.storageMove` | `StorageRelocation.begin` / `cancel` / completion | `phase` |
| `.projectTransfer` | `ProjectTransferServer`, per in-flight transfer | new |

### The rule

- **Connections are always accepted.** `hello`, `listProjects` and `thumbnail`
  are answered whatever the app is doing — they are kilobytes, and a client that
  cannot see the list has no idea *why* it cannot.
- **`requestProject` is refused** while `transferBlockReason != nil`, with the
  reason sentence in the reply. The client greys the row and shows the sentence.
- **TXT `busy` mirrors the same flag**, republished when `activities` changes, so
  a browsing client can grey the whole device before pairing.
- **A transfer in flight registers `.projectTransfer`**, so a blend or an export
  started on the serving device is refused (or, better, warns and offers to stop
  the transfer). Reading 20 GB off the disk under a render is the contention case
  that makes both look broken.
- **Capture is never blocked by a transfer.** A shoot always wins: opening the
  capture screen aborts the transfer with `error: "capture started"`. Stated
  explicitly because the opposite default is what an activity registry naturally
  produces — and with resume in place, this abort now costs the user nothing but
  a tap when they come back.

---

## 6. The other two transports

### AirDrop — already supported, no work needed

`ProjectDetailView` and `ScanDetailView` already build a `.lapse` and hand it to
`ShareLink` (`App/ProjectArchiveShare.swift:71`), and the iOS share sheet includes
AirDrop. Nothing in this plan changes that, and nothing needs to be built.

What to be honest about:

- **It materialises the whole archive first.** `exportProject` writes the `.lapse`
  into `FileManager.default.temporaryDirectory` (`AppModel.swift:6488`) before a
  byte can move, so peak disk is roughly project + archive. For a 20 GB DNG shoot
  on a phone that is already 70% full, this fails — but it fails *cleanly*:
  `exportProject` pre-checks free space against the uncompressed directory size
  and throws `ExportError.insufficientStorage` (`AppModel.swift:6502-6509`).
- **It bypasses the pairing code entirely.** AirDrop uses the OS's own consent
  model — a receiving device the user taps Accept on. That is fine and is not a
  hole in this design, but it means the "anyone with this code" warning in §2 is
  not the only way a project leaves a device, and the two should not be described
  as if the code were the only gate.
- **One thing to verify before recommending AirDrop for large projects:** the
  temp `.lapse` is deleted when the share sheet is dismissed
  (`ProjectArchiveShare.swift:47-51`), on the stated reasoning that dismissal is
  when the file stops being needed. Whether that races a 20 GB AirDrop still in
  flight is a device check, not an assumption. If it does race, the fix is to
  defer the delete rather than to change the design.

Product-side follow-up, once nearby transfer exists: the export sheet should
steer large projects — above some threshold, a caption saying "Large project —
Import from nearby device is faster and needs no free space". That is one line of
copy, and it is the difference between AirDrop being a reasonable small-project
convenience and being the thing that fills someone's phone.

### USB cable (Mac ↔ iOS) — free, by construction

A USB-tethered iOS device presents to the Mac as a network interface. Because the
listener publishes its Bonjour service on **all** interfaces (§2) and the Mac's
browser is built with plain `NWParameters` plus `includePeerToPeer` and no
interface restriction (`LocalNetworkTransport.swift:66-70`), a cabled device is
discovered and connected to by exactly the same code as a Wi-Fi one. **No
protocol change, no second transport, no new code path.**

The constraints that do apply:

- Do not add `requiredInterfaceType` or `prohibitedInterfaceTypes` anywhere in
  this feature. The moment either appears, USB stops working and the symptom is
  "the device just doesn't show up", which reads as a Bonjour problem.
- A cable buys no background execution. The iOS foreground rule in §2 is
  unchanged: the app must be open on the serving device.
- The device must be unlocked and trusted by the Mac. The bench notes already
  record that a locked iPhone refuses `devicectl`; the same lock is what an
  untrusted USB link looks like here.

The only UX implication is in the picker: a cabled device should be labelled so
the user knows it will be fast. Take the label from `NWBrowser.Result.interfaces`
— but **how a USB-tethered iOS device reports its `NWInterface.InterfaceType`
(`.wiredEthernet` vs `.other`) is a device check, not something to assume.**
Verify on hardware in Phase 1 and degrade to no label rather than mislabel a
Wi-Fi device as USB.

### Peer-to-peer Wi-Fi — probably also free, worth a test

`includePeerToPeer = true` (already set on the existing browser) enables AWDL
discovery, which is what would let two iPhones transfer with no shared network at
all — a field case this app genuinely has. Test it in Phase 2 alongside
iPhone→iPhone; do not claim it works until it has moved real bytes.

---

## 7. Files

### New

| File | Target(s) | Contents |
| --- | --- | --- |
| `Shared/ProjectTransferProtocol.swift` | iOS, macOS | Service type + TXT keys, frame types, `ProjectTransferCoder`, command vocabulary, `ProjectSummary` / `TransferFileEntry: Codable`, protocol version |
| `Shared/ProjectTransferServer.swift` | iOS, macOS | `NWListener`, TXT publication, per-connection state machine, file enumeration + send pump with semaphore backpressure, activity guards |
| `Shared/ProjectTransferClient.swift` | iOS, macOS | `NWBrowser`, `DiscoveredLibrary` (incl. interface label), connect + pair, control round-trips, framed receive → staging writer, the 8s pairing timeout |
| `App/IncomingTransfers.swift` | iOS, macOS | The `Incoming/` staging store: `transfer.json`, `have`-set reconciliation, `.part` handling, the 14-day sweep, and the model behind Settings ▸ Incomplete Transfers |
| `App/ProjectServingView.swift` | iOS (macOS in P3) | The serving sheet: code, project count, "anyone with this code…" warning, connected peer, live transfer row, Stop sharing |
| `App/ProjectServingChip.swift` | iOS | Projects-header chip, modelled on `RemoteLinkChip` |
| `App/ProjectTransferImportView.swift` | iOS, macOS | Browse → pair → list → pick → progress, with the resume badge and Resume/Discard |
| `Remote/LibraryTransferWindow.swift` | macOS | `Window` scene wrapper + shared browse/pair chrome extracted from `RemoteWindow` |

`Shared/ConnectionArchiveStreams.swift` from the earlier draft is **gone** — the
file-by-file payload needs no `ArchiveByteStreamProtocol` conformance. It returns
only if §1 falls back to the archive stream.

Not in the watchOS target — the server references `AppModel` and `LLog`, and a
Watch is a remote, never a library (the `#if !os(watchOS)` guard at the top of
`CaptureRemoteListener.swift` is the precedent).

### Modified

| File | Change |
| --- | --- |
| `App/AppModel.swift` | `LibraryActivity` registry; split `importProject` into `stageArchive` + `installStagedProject`; add `receiveProject`; hold the `ProjectTransferServer`; `projectSummaries()` + the cached size walk; project file enumeration |
| `App/ProjectArchive.swift` | `transferableSubfolders` — the one `["source","blends","notes"]` constant shared by the enumerator, the installer and the archive path |
| `App/StorageLocation.swift` | `"Incoming"` into `libraryItemNames` (`:35`); `.storageMove` activity bracket |
| `Shared/CaptureRemotePairing.swift` | `Purpose` enum on `derivedKey` / `pairingID` / `parameters`, defaulted to `.captureRemote`; transfer-shaped TCP options |
| `App/ProjectImport.swift` | `ArchiveImport.Phase.receiving`, `peerName`, `resumedBytes`; sheet copy, icon and Resume/Discard buttons for the network case |
| `App/Info.plist` | `_letslapse-library._tcp` into the `NSBonjourServices` **array** |
| `App/SettingsView.swift` | Advanced gains the sharing opt-in + "Share to nearby device" beside `allowRemoteAccess` (`:783`); Storage gains **Incomplete Transfers**, modelled on Incomplete Captures (`:922`) |
| `App/ProjectsView.swift` | Share / Import controls in `header` (`:122`); serving chip |
| `App/CreateView.swift` | "Import from nearby device" row beside the archive `fileImporter` |
| `App/ProjectDetailView.swift`, `App/ScanDetailView.swift` | `.archiveExport` bracket; the large-project caption on the export sheet (§6) |
| `App/LetsLapseApp.swift` | macOS `Window` scene + ⌘⇧I; scenePhase → server stand-down (the existing `setAppActive` hook at `:126`/`:131`); `Incoming/` sweep beside `ImportStaging.sweepOrphans()` at `:25` |
| `App/CaptureView.swift` | `.capture` activity bracket beside `setCommandHandler` |
| `App/CollectionExporter.swift` | `.collectionExport` bracket |
| `LetsLapse.xcodeproj/project.pbxproj` | New sources → iOS + macOS targets only |
| `docs/TODO.md` | Job entry pointing here |

`Kit/Sources/LetsLapseKit/DirectoryArchive.swift` is **unmodified** under the
recommended path — it keeps owning the `.lapse` file format for Finder, the share
sheet and AirDrop, and the network never touches it. It gains the stream
overloads only if §1 falls back to (A).

### Design specs (CLAUDE.md requirement)

Per `docs/design/README.md`, **ask design-first or app-first before any of this
UI is written.** New/updated SVGs:

- `docs/design/iOS/library-share.portrait.svg` (armed, with code)
- `docs/design/iOS/library-share.sending.portrait.svg`
- `docs/design/iOS/library-import.browse.portrait.svg`
- `docs/design/iOS/library-import.list.portrait.svg`
- `docs/design/iOS/library-import.progress.portrait.svg`
- `docs/design/iOS/library-import.resume.portrait.svg`
- `docs/design/iOS/settings.incomplete-transfers.portrait.svg`
- `docs/design/iOS/projects.portrait.svg` — **update**, the header gains controls
  and the serving chip (already `M` in the working tree; coordinate)
- `docs/design/iPadOS/` mirrors for the same set
- `docs/design/macOS/library-import.svg`
- `docs/design/*/INDEX.md` status rows

---

## 8. Phasing

### Phase 0 — spike (½ day, blocks everything)

Three measurements, in this order. The first two decide §1 and can kill the
third outright.

1. **What does lzfse actually save on real footage?** Archive one real 15 GB DNG
   interval shoot and one ProRes/JPEG project with the existing
   `DirectoryArchive.write`, and compare against `directorySize`. This is a
   one-line script over projects Steven already has. **If the saving is under
   ~5%, file-by-file (§1 C) is settled** and questions 2 is moot.
2. **Only if (1) says compression is worth keeping:** does
   `ArchiveStream.decodeStream(readingFrom:)` ever call `read(into:atOffset:)` or
   `seek` on its source? Wrap a `fileStream` in a logging
   `ArchiveByteStreamProtocol` proxy, run the existing Kit round-trip test through
   it, and count the calls. Sequential-only means the archive stream is viable;
   anything else means archive transfer must spool, at 2× disk.
3. **Does backpressure hold?** Push 2 GB between two Macs through the send pump
   and watch RSS. It must sit flat at roughly `chunk × inFlight`. This applies to
   whichever payload strategy wins, and if it climbs, nothing downstream matters.

### Phase 1 — iOS serve → Mac import

The shortest path to the thing that hurts today: a 16 GB shoot on a phone that
has to become a project on the Mac.

- Protocol, coder, server, client, `IncomingTransfers`.
- `LibraryActivity` registry and every registration site (§5) — done here, once,
  because Phase 2 and 3 both assume it.
- iOS: Settings opt-in, Projects Share control, serving sheet + chip.
- macOS: the `Import from Device` window.
- `AppModel` import split; `transferableSubfolders`; `"Incoming"` in
  `libraryItemNames`.
- Settings ▸ Incomplete Transfers.
- USB check: confirm a cabled iPhone appears in the Mac's browser and transfers,
  and find out what interface type it actually reports (§6).
- **Exit criteria:** a 15+ GB interval shoot moves iPhone→Mac and iPad→Mac over
  Wi-Fi *and* over USB; cancel works at 25%; **pulling the server's Wi-Fi at 40%
  and reconnecting resumes from 40%, not from zero**; nothing partial ever
  appears in the Mac's library; peak disk on the Mac is bounded by the project
  size, not twice it.

### Phase 2 — iOS import

Everything is already cross-platform; this is the client UI on iOS plus the
storage-pressure cases a Mac does not have.

- `ProjectTransferImportView` presented as an iOS sheet from Projects and Create.
- Free-space pre-check and the mid-stream watch (§4) — the case that matters far
  more on a 128 GB iPhone than on a Mac, and now recoverable rather than fatal
  because the partial survives.
- "Keep LetsLapse open", the background-kill path, and Resume from Settings.
- Peer-to-peer Wi-Fi test (§6) alongside iPhone→iPhone.
- **Exit criteria:** iPad imports from iPhone, iPhone imports from iPhone, a
  deliberately-too-large project is refused *before* a byte moves, and a transfer
  interrupted by backgrounding resumes cleanly from Settings on the next launch.

### Phase 3 — Mac serve

- Mac-side serving UI and its own lifetime rule (no scene phase, no foreground
  constraint — likely "advertise while the sharing window is open", plus the
  15-minute idle timeout).
- Interaction with the camera-remote browse loop on the same host.
- Mac serving UI SVG.

---

## 9. Decisions taken

1. **Streaming vs spooling — unresolved, and the spike is genuinely required.**
   Not a formality: Phase 0 measures the compression saving first, because if it
   is near zero the whole question is replaced by §1 (C) and the AppleArchive
   `seek` unknown never has to be answered.
2. **One code unlocks the whole library.** Browse everything, pull anything. The
   per-project-consent alternative is safer and worse for the case that motivates
   the feature ("get three shoots off this phone"), so the risk is handled by
   saying it plainly in the serving sheet and rotating the code on every arm.
3. **Payload is file-by-file** (recommended, pending Phase 0's measurement) —
   resume-friendly, thermally cheaper, disk-optimal, and it removes the plan's
   largest unknown. See §1.
4. **A transfer never deletes the source project.** Not on completion, not on
   request, not behind a confirmation. The serving side of this feature is
   read-only by construction and that property is worth more than the
   convenience: the failure mode of a "Move" that deletes after an install that
   later turns out to be broken is losing a shoot, and nothing about a
   partially-verified 20 GB copy justifies that risk. Someone who wants the space
   back deletes the project themselves, on the device, having seen it arrive.
5. **No digest verification.** The `sha256` trailer is dropped from the design.
   TLS already provides integrity; truncation is caught by per-file byte counts;
   and hashing 20 GB on both ends costs a full extra pass on the two devices
   least able to afford it. Revisit only if a real-world corruption shows up that
   the byte counts missed.
6. **AirDrop stays as-is** — already shipped via the share sheet, no new work,
   with the temp-file caveat in §6 to verify and a size-aware caption to add.
7. **USB needs no code** beyond not restricting interfaces, and a picker label.
