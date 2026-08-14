# Brief: a macOS mirror of the Watch remote, driving the iPad

**Status:** ready to build · **Branch:** `ios-app` · **Written:** 2026-08-13

## Why this exists

Two goals, and the second is the one that pays for the work:

1. **Control the window-mounted iPad from the Mac.** The iPad now lives on a
   window sill shooting the street. Touching it to start a take shakes the
   frame the take is measuring. `LL_RUN` (see
   `ramp-switch-investigation-2026-08-11.md`) solved this for *scripted* runs,
   but it is a launch hook — one canned script, no live control, app restart
   per take.
2. **Make the Watch app's UX iterable.** The Watch remote is 970 lines of
   SwiftUI whose only test surface is a real Watch or a paired simulator pair.
   Every UX idea costs a deploy. Four screens in
   `docs/design/watchOS/INDEX.md` are still 🟡 Planned and the P1 work from
   the 2026-07-29 link audit (state-aware unreachable screens, `openCamera`,
   rendered `statusText`, last-known-state-with-age footer) has sat untouched
   since. A Mac window that runs *the same view code* turns that into a
   hot-reload loop.

Goal 2 is why this should share code with the Watch rather than be a
lookalike. A Mac remote that merely *resembles* the Watch improves nothing.

> **Status, 2026-08-14.** Steps 1–5 (the scaffolding) landed earlier; the view
> now lives in `Remote/`, not `Watch/`, because the Mac window compiles it too.
> **Goal 2 has since been cashed in**: the watchOS redesign shipped, and with it
> most of the P1 list this brief was written to unblock — state-aware screens
> for a closed camera / a rendering phone / a phone in setup, an `armCamera`
> command, and truthful pending + failure states in place of a `statusText`
> nothing ever displayed. See `docs/design/watchOS/INDEX.md`. Paths written as
> `Watch/…` below are as they were when this brief was authored; the files moved
> in `88d957c` / `cfcb40e`.

## The constraint that shapes the whole job

**WatchConnectivity cannot reach either end of this.**

- `WCSession` does not exist on macOS. There is no port, no shim, no
  entitlement. The Mac cannot speak WatchConnectivity at all.
- `WCSession.isSupported()` returns **false on iPadOS** — Apple Watch pairs
  with iPhone only. `App/WatchRemoteControlReceiver.swift` is wrapped in
  `#if os(iOS)`, which iPadOS satisfies, so it *compiles* on the iPad and then
  no-ops at runtime on the guards at `:82` and `:337`.

So today **there is no remote-control path to the iPad at all**, and the Watch
app cannot be pointed at one. This is not a UI port. It is:

> a second transport, plus a receiver that works off-iPhone, with the existing
> Watch view hosted on top.

Budget accordingly — the view sharing is the easy third.

## Recommended architecture

### 1. The seam already exists — widen it

`Shared/WatchMessageKey.swift` is already a flat, transport-agnostic
dictionary vocabulary (37 keys) spoken by both ends. Keep it verbatim; it is
the wire format, and it costs nothing to carry over a different pipe.

`WatchCaptureCommand` (14 cases: `startRecording`, `stopRecording`,
`triggerMoment`, `timedBurst`, `lockExposure`, `unlockExposure`, `setISO`,
`setLensPosition`, `setCaptureMode`, `setIntervalSeconds`, `setFramesPerBlend`,
`scheduleStop`, `cancelScheduledStop`, `state`) currently lives *inside*
`#if os(iOS)` in `App/WatchRemoteControlReceiver.swift:5`, so the Watch target
can't see it and sends raw strings. **Move it to `Shared/`** and have both
ends use the enum. That alone removes a class of typo bug and gives the new
transport a typed surface for free.

### 2. Introduce a transport protocol

Define something like `CaptureRemoteTransport` in `Shared/`:

```
send(_ payload: [String: Any], reply: ([String: Any]) -> Void)
var isReachable: Bool { get }
var inbound: ([String: Any]) -> Void { get set }
```

Two conformances:

- **`WatchConnectivityTransport`** — the existing code, unchanged in
  behaviour. The WCSession coupling in `Watch/WatchCaptureRemote.swift` is
  already concentrated and easy to lift: activation `:86-91`, send
  `:160-184`, delegate `:631-698`. Everything else in that file — the
  published state, `applyState`, the command builders, the reconciliation
  polls — is transport-agnostic already.
- **`LocalNetworkTransport`** — new. Bonjour + Network.framework.

Do **not** regress the Watch path while doing this. It carries hard-won
behaviour: the off-main `wcQueue` (a main-thread `updateApplicationContext`
hangs the UI and trips the 0x8BADF00D watchdog — see
`watchconnectivity-main-thread-hang` in the working notes), the 6 s `isSending`
watchdog, the 4 s unreachable poll, the post-accept reconciliation polls, and
`isDebugPreview` isolation. Re-read the P0 audit notes before touching it.

### 3. Transport B: Bonjour + Network.framework

Greenfield — there is no `NWListener`/`NWBrowser`/MultipeerConnectivity
anywhere in the repo today.

- **iPad/iPhone (the camera) advertises.** `NWListener` on
  `_letslapse-remote._tcp`, publishing device name and capture state.
- **Mac (the remote) browses.** `NWBrowser`, lists cameras, connects to one.
- **Framing:** length-prefixed JSON, one object per message, mirroring the
  WC dictionary shape so `applyState` needs no changes.
- **Direction:** bidirectional — commands up, state pushes down, same as WC's
  `sendMessage` + `updateApplicationContext` split.

Rejected alternatives: MultipeerConnectivity (heavier, flakier, and its
discovery UI assumptions don't fit); a plain HTTP server (no discovery, and
you'd hand-roll push).

**Pair before you trust.** This channel starts and stops recordings on a
camera over the LAN. Ship a pairing step — a short code shown on the camera
and typed on the Mac, backing a TLS-PSK `NWParameters` — rather than an open
socket any process on the network can drive. Do this in the first cut, not as
a follow-up; retrofitting auth onto a working open channel never happens.

**Foreground constraint:** iOS suspends network activity in the background, so
the iPad must have the capture screen up for the listener to live. That is the
same constraint the app already has today, but say it in the UI rather than
letting the Mac show a silent dead link.

### 4. The view: share it, render it Watch-sized

Host `Watch/WatchControlView.swift` itself on macOS, inside a window
constrained to the Watch canvas — **208×248 pt** (Apple Watch 46 mm, per
`docs/design/watchOS/INDEX.md`). Layout decisions then transfer 1:1 and the
watchOS SVGs stay the single source of truth. An "expanded" Mac layout can
come later; it is not what makes Goal 2 pay.

The platform forks are small and fully enumerated — this is the whole list:

| What | Where | macOS treatment |
|---|---|---|
| `import WatchKit` | `WatchCaptureRemote.swift:4` | `#if os(watchOS)` |
| `WKInterfaceDevice.current().play(_:)` | `WatchCaptureRemote.swift:411-414` | no-op, or `NSHapticFeedbackManager` |
| `WKExtendedRuntimeSession` | `WatchCaptureRemote.swift:448, 462-471, 705-712` | no-op — a Mac doesn't sleep mid-take |
| `.digitalCrownRotation` | `WatchControlView.swift:311, 786` | scroll wheel / drag; **the one real UX design decision** |
| `WCSession` | `WatchCaptureRemote.swift:86-91, 160-184, 631-698` | the transport swap above |

The crown substitution deserves thought rather than a stepper: those two sites
are the ISO/lens-position control and the Stop At dial, both of which are
"no-look" controls on the wrist. What replaces them on a Mac should be
evaluated on whether it teaches you anything about the wrist version.

### 5. Where the Mac window lives

**Put it in the existing universal target**, as a new scene. The target
already builds for macOS (`SUPPORTED_PLATFORMS = "iphoneos iphonesimulator
macosx"`), `Shared/` already compiles into all three platforms, and the photo
editor set the precedent for a `WindowGroup(for:)` scene on the Mac. A second
target would mean a second bundle id, signing setup, and Shared/ membership
list to keep in sync, for nothing.

Note this makes the Mac build both a camera *and* a remote. Keep the remote
window a distinct scene, not a tab, so it can sit beside the capture window.

## Gotchas that will cost you a day each

- **`NSBonjourServices` cannot be an `INFOPLIST_KEY_*` build setting** (it's an
  array). It must go in the partial `App/Info.plist`, which is merged with the
  generated keys — the file's own header comment explains that arrangement,
  which exists because `UILaunchScreen`'s nested key hit the same wall.
  `NSLocalNetworkUsageDescription` is a string and *can* be an
  `INFOPLIST_KEY_*`. Getting this wrong yields a silently empty dict.
- **Local Network permission** prompts on first browse/advertise on iOS. A
  denied prompt looks exactly like "no cameras found". Surface the
  authorization state explicitly.
- **The Mac app is not sandboxed** (`com.apple.security.app-sandbox` is
  `false` in `App/LetsLapse.entitlements`), so no network entitlement is
  needed today. If that ever changes, `com.apple.security.network.client` and
  `.server` both become required.
- **Watch target Info.plist** uses the same merge arrangement for
  `WKBackgroundModes`, and there is a known sync-group exception around it.
  Don't "tidy" either plist.
- **`WCSession.isSupported()` is your platform test, not `#if os(iOS)`.**
  iPadOS satisfies `os(iOS)`. Any `#if os(iOS)` you find in the watch-link
  code is suspect and probably means "iPhone".

## Design-sync obligation

`CLAUDE.md` §"Design-sync requirement" applies in full — this is UI work on
watchOS and macOS. Before starting, ask the standard question: *design files
first, app code first, or something else?*

- `docs/design/watchOS/` holds 6 SVGs + `INDEX.md` at 208×248 pt. If the Mac
  mirror renders the same view at the same size, **these stay the source of
  truth** and no parallel Mac screen specs are needed for the mirrored
  content.
- `docs/design/macOS/` needs one new spec for the window chrome — camera
  picker, pairing, connection state — since none of that exists on the Watch.
- Any UX change made on the Mac surface must land in the watchOS SVGs too.
  That is the entire point of the exercise; a Mac-only improvement is a
  regression against Goal 2.

## Suggested staging

1. **Move `WatchCaptureCommand` to `Shared/`**, both ends on the enum. No
   behaviour change. Verify the Watch still drives an iPhone on the paired-sim
   rig.
2. **Extract `CaptureRemoteTransport`**, with WatchConnectivity as the only
   conformance. Still no behaviour change; still verify on the rig. This is
   the risky refactor — do it alone, in its own commit.
3. **`LocalNetworkTransport` + pairing**, camera side first. Prove it with a
   throwaway CLI client before any UI exists: connect, send `state`, print the
   dictionary.
4. **Receiver off-iPhone.** Make `WatchRemoteControlReceiver`'s command
   handling transport-agnostic and reachable on iPadOS/macOS. This is where
   the iPad first becomes controllable at all.
5. **Host `WatchControlView` on macOS** at 208×248 with the fork table above.
6. **Then, and only then, the UX work** — the four 🟡 specs and the P1 list.
   That is the deliverable; 1–5 are scaffolding.

## Verification

- **Rig:** the iPad at the window, reachable over Wi-Fi with no cable
  (`transportType: localNetwork`). Install and launch from the Mac:
  `xcrun devicectl device install app --device <udid> <app>` then
  `... process launch --console --terminate-existing`. Console output is
  block-buffered over the tunnel and dies when the app backgrounds.
- **Ground truth for anything capture-related:** `LL_RUN=i25x15,b50x5,i25x10`
  drives a scripted ramp hands-free; the analyzer recipe in
  `ramp-switch-investigation-2026-08-11.md` reads per-segment cadence back out
  of the pulled files. A remote-triggered take should produce timing
  indistinguishable from an `LL_RUN` one — that is the regression test.
- **Don't break the Watch:** the paired-sim rig (iPhone 17 Pro + "LL Watch
  S11") still exercises the WC path end to end. Every stage above must leave
  it working.

## Non-goals

- Rebuilding the Watch UI for a large screen. Watch-sized is the point.
- Remote *viewing* — a live preview stream is a much bigger job (video
  encode + transport) and is not required for control. If framing feedback
  turns out to be the real need, scope it separately; a periodic still might
  buy 90 % of it for 5 % of the work.
- Anything over the internet. LAN only.
- Replacing `LL_RUN`. It stays as the deterministic scripted path.

## Decisions taken here — challenge them first

The new agent should sanity-check these before building, since each shapes
everything after:

1. Bonjour + Network.framework, not MultipeerConnectivity.
2. A scene in the existing universal target, not a new macOS target.
3. Watch-sized canvas, not a Mac-native expanded layout.
4. Pairing with TLS-PSK in the first cut, not deferred.
5. Shared view with `#if os(watchOS)` forks, not a parallel Mac view.
