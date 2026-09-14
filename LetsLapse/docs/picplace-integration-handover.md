# Sign in with PicPlace — client handover

**Date:** 2026-09-14 · **Status:** v1 implemented and working end to end; the
product flows below are the owner's to design · **Server:** PicPlace
(`picplace.co` live, `picplace.test` for local dev)

> **Decided 2026-09-14:** the flows this handover leaves open are answered in
> [picplace-sync-v2-plan.md](picplace-sync-v2-plan.md) (twelve decisions,
> the minimal dataset, the merge, five stages) with the server's answers of
> the same day condensed there; the asks that fall out of it are in
> [picplace-sync-v2-server-asks.md](picplace-sync-v2-server-asks.md). Read
> this file for what v1 built and why the questions arose.

This document hands the PicPlace integration to the LetsLapse repo owner. The
plumbing is built and proven — a device can sign in and push a nominated
project to the cloud — but the *flows* that make it a LetsLapse feature (how a
person first connects, what happens across libraries and devices, when things
sync) are deliberately left open, because they are LetsLapse decisions, not
transport decisions.

Two companion documents:

- **`docs/picplace-sync-v1.md`** — the implementation spec for what shipped:
  the seven decisions taken, the exact sync sequence, the screens, what v1
  does not do.
- **The server contract** lives in the PicPlace repo: `docs/letslapse-overview.md`
  (start there), `docs/letslapse-auth.md`, `docs/letslapse-api.md`,
  `docs/letslapse-storage.md`. Everything the app calls is documented there,
  endpoint by endpoint.

## 1. What exists today

A person can, from the Mac or iOS app:

1. **Settings ▸ PicPlace ▸ Sign in with PicPlace** — OAuth (PKCE) against the
   server; tokens land in the Keychain, this device registers itself, the card
   shows the account, this device's name, and how much is on the server.
2. **A project ▸ the PicPlace card ▸ Sync to PicPlace** — claims the project,
   uploads `project.json` as the manifest and every file under the project
   folder straight to object storage (skipping files the server already holds
   by hash), and shows progress and the end state (synced · *Also on* the other
   devices that report a copy · or a failure with its reason).
3. **A pill on the Projects list** marks projects that are synced / syncing /
   failed; nothing shows for projects that were never synced.
4. **Sign out** revokes this device on the server and forgets the tokens; local
   files are untouched.

This is **v1: one device, one nominated project, push only.** It changes no
record, no file format and nothing in the library index; a person who never
signs in sees no difference.

## 2. How the code is arranged

Everything is under `App/PicPlace/`, owned by `AppModel.picplace`
(`PicPlaceController`, `@MainActor`, observed by the cards):

| File | Responsibility |
|---|---|
| `PicPlaceConfiguration` | The server as a **setting** (`letslapse.picplace.server`); Debug defaults to `picplace.test`, Release to `picplace.co`. The public OAuth client id. Never a hardcoded server. |
| `PicPlaceKeychain` | The access/refresh tokens, this install only. |
| `PicPlaceSignIn` | The PKCE flow. iOS: `ASWebAuthenticationSession`. macOS: the default browser + the server's `/oauth/letslapse/return` page + a Launch Services callback (see §6). |
| `PicPlaceAPI` | The wire types and the bearer client, with single-flight token refresh. Asset bytes never pass through it. |
| `PicPlaceSyncRun` | One push: claim → manifest → batched negotiate → direct PUTs → confirm → presence → release. |
| `PicPlaceController` | Session, device registration, device-local sync records, the six card states, the sync tasks. |
| `PicPlaceViews` | `PicPlaceStatusCard` (project card + Mac inspector group), `PicPlaceSettingsCard`, `PicPlacePill`. |

Sync state is **device-local** (`UserDefaults` → `letslapse.picplace.syncStates`):
"this device pushed this project, at this revision, then." The server is the
truth for what is actually stored; the card re-reads it (`GET /projects/{uuid}`)
when it appears.

### Identity, as the code uses it

Three identities, matching the data-model programme's account model
(`docs/data-model-server-portability-2026-09-12.md` §10.6):

- **Device** = `DeviceIdentity.id` (per install, in `UserDefaults`). Sent as
  `device_key`; the server row is what other devices see in *Also on*.
- **Account** = attached at sign-in; owns the projects on the server; carries
  the (currently un-enforced) quota.
- **Project** = the project's own UUID. **v1 sends `capture.id`.** The
  data-model programme's stable cross-device key is `originID`
  (`AppModel.originID(of:)`); for a new capture the two are equal, but a
  project that *arrived* from elsewhere has an `originID` distinct from its
  local `capture.id`. **Before multi-device sync, switch the server key to
  `originID`** — see the open questions.

## 3. The flows to design (the reason for this handover)

The transport is done; these are product decisions the owner should make.

### 3.1 First-time connection

Today there is no onboarding: a Settings row and a per-project button, nothing
that explains what leaving-the-device means or what a person is agreeing to.
Decisions:

- **Where does "Sign in with PicPlace" belong** beyond Settings — a first-run
  prompt, an entry point from a project, a mention when storage runs low?
- **What does the first sync tell the person** about what is uploaded (the
  manifest and every source file, which for an interval shoot is gigabytes),
  where it goes, and that it counts against their storage?
- **Consent and expectations.** The account model assumes the app works fully
  with no account; sign-in is the opt-in. Make that opt-in legible.

### 3.2 Accounts with more than one library

This is the sharpest LetsLapse-specific question, because the Mac library is
**relocatable** (`StorageRoot`, Settings ▸ Storage ▸ Library location) and a
person can point the app at different library folders on different volumes.

- The device id is **per install, not per library** — so the same account and
  device would claim projects from *whichever* library is currently open into
  the *same* account on the server. Is that what you want? Or should a library
  be bound to an account, and switching libraries switch (or refuse) the
  connection?
- On the Mac, the **sandboxed and unsandboxed builds read different preference
  domains and so hold different device ids** (data-model Part 1 R7) — they are
  two devices to the server. Decide whether that matters.
- If two libraries hold projects with the **same `originID`** (a project
  transferred between them), they are one project to the server and would
  merge by the server's rules. Decide whether the app should ever let that
  happen, or keep libraries disjoint.

The clean answer probably follows the data-model programme: identity is
account + device + project(`originID`), and a library is just a local
materialisation. But the UX of "which library am I syncing, and to whom" needs
designing.

### 3.3 What syncs, and when

v1 is manual, one project at a time, push only. Open:

- **Selection and automation** — sync everything, or nominate; on capture, on
  edit, on a schedule, on Wi-Fi only; background transfers that survive app
  suspension (v1's `URLSession` upload tasks are foreground).
- **Download/restore** — the server already offers `GET /assets/{id}/url` and
  presence, so "restore this project to this device" and "free up space, it's
  safe, a copy is on the server and your iPad" are buildable now. This is the
  §4.1 use in the data-model audit and arguably the highest-value flow after
  first sync.
- **Conflicts and revisions** — v1 sends a client revision derived from
  `modifiedAt` and the server only checks it is not going backwards. The full
  per-field last-writer-wins model (data-model Part 3 §5) is not built. Decide
  how much of that this feature needs versus defers to phase 6.

### 3.4 Sign-out and local data

v1 sign-out revokes the device and keeps every file. The data-model decision
(§10.6) is stronger: **sign-out is refused while any original is unconfirmed by
the server**, then the person chooses between keeping records-and-previews as a
read-only view or wiping. None of that is built. Design the sign-out contract
against the eviction/presence model.

### 3.5 Multi-device presence and eviction

The server records **presence** per (project, device) and the app posts it
after a sync. The data-model programme's presence *tiers* (original / proxy /
preview) and the eviction policy that shrinks a project to a preview to free
space are the client half — unbuilt. This is where "the whole thing is a
Lightroom alternative with its own cloud" (data-model Part 3 framing) actually
lands, and it is the natural next milestone.

## 4. How this relates to the data-model programme

`docs/data-model-server-portability-2026-09-12.md` (Part 3 of the data-model
audit) designs the full "server as the source of truth": canonical records with
server-assigned revisions, a per-device NDJSON change journal behind one
`apply(change)` funnel, per-field last-writer-wins, presence tiers, and the
`.lapse`/LAN transports kept as fast paths. That is **phase 6** of that
programme and is **not** what shipped here.

What shipped is the smaller, standalone slice: a registry the client pushes one
whole project to. It maps cleanly onto the larger model — projects, presence
and claims are the same concepts — so it is a stepping stone, not a detour. When
phase 6 lands, this sync becomes the transport for the journal rather than a
whole-project push, and the server registry gains the change feed. Nothing here
should need to be torn out; the main adjustment is keying by `originID` (§2) and
moving from whole-project pushes to journal batches.

## 5. Design mirrors (the repo's design-sync rule)

Per `CLAUDE.md`, UI has SVG mirrors in `docs/design/`. The PicPlace UI is
mirrored:

- Components: `components/picplace-status.<state>.{phone,narrow}.svg`,
  `picplace-account.<state>.phone.svg`, `picplace-pill.<state>.svg`.
- Screens: `iOS/settings.picplace.*.svg`, `iOS/project-detail.photo.picplace.portrait.svg`,
  `iOS/projects.picplace.portrait.svg`, `macOS/gallery.item.picplace.svg`.

Status in the platform `INDEX.md` files: the iOS mirrors are ✅ (verified on the
simulator through a real sync); the **Mac inspector card is 🟡** — the code is
in but the group has not been screenshotted on the Mac (it sits below the
inspector's fold). Stage it with
`LL_TAB=gallery LL_ITEM=<uuid> LL_PICPLACE=synced` and compare against
`macOS/gallery.item.picplace.svg` to close it. Any change to the PicPlace UI
must update these mirrors in the same unit of work.

## 6. Running and testing it

- **Server as a setting.** Debug builds default to `https://picplace.test`,
  Release to `https://picplace.co`. Change it in Settings ▸ PicPlace ▸ Server
  (only while signed out). Never hardcode.
- **macOS sign-in** opens the default browser and returns through the server's
  `/oauth/letslapse/return` page. This is deliberate: desktop Chrome drops a 302
  straight to a `letslapse://` scheme with "This site can't be reached", but
  opens the scheme from a page. Every `letslapse://` URL the app receives is
  logged (`picplace: received …`) and consumed, never handed to the archive
  importer.
- **iOS Simulator + `.test`:** the Simulator does not trust Valet's CA. Once per
  simulator:
  `xcrun simctl keychain <udid> add-root-cert ~/.config/valet/CA/LaravelValetCASelfSigned.pem`.
  A physical device trusts neither `.test` DNS nor the cert — use `picplace.co`
  or a tunnel.
- **DEBUG launch hooks** (read the environment, `SIMCTL_CHILD_` prefixed on the
  simulator): `LL_PICPLACE=<state>` stages every card in one of the six states
  with no server; `LL_PICPLACE_TOKENS=<access>:<refresh>` signs in with tokens
  minted elsewhere; `LL_PICPLACE_SERVER=<url>` overrides the server for the run;
  `LL_PICPLACE_SIGNIN=1|silent` presses Sign in at launch (`silent` opens no
  browser and logs the authorize URL, so a test can finish the consent itself);
  `LL_PICPLACE_SIGNOUT=1` starts signed out and revokes the device — run it to
  leave a shared Mac as you found it; `LL_DETAIL=<capture-uuid>` opens a
  specific project.
- **A throwaway verified account** is how the server side is exercised without a
  real user: the account must have `users.verified = 1` on the server (the API
  is gated on it). The PicPlace repo's docs show the shell walkthrough.

## 7. Open questions, collected

1. Switch the server project key from `capture.id` to `originID` before any
   multi-device work (§2).
2. Bind a library to an account, or let one account span libraries? And the
   sandboxed/unsandboxed Mac device-id split (§3.2).
3. The first-run connection experience and the "what gets uploaded" disclosure
   (§3.1).
4. Auto-sync policy, background transfers, and download/restore (§3.3).
5. Sign-out contract against unconfirmed originals (§3.4).
6. Presence tiers and eviction — the "free up space safely" feature (§3.5).
7. How much of the phase-6 data-model programme this feature pulls forward
   versus defers (§4).
