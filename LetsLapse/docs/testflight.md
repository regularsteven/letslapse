# Shipping LetsLapse to TestFlight

Everything the repo can do for a TestFlight build is done by
`tools/release/testflight.sh`. Everything it *can't* — the parts that need your
Apple account — is the checklist below. Do those once; after that a build for
your testers is one command.

```bash
./tools/release/testflight.sh --upload
```

**Scope right now: iPhone and iPad, with the Watch app riding along inside the
same build.** macOS is not shippable to TestFlight yet; see the last section for
exactly why and what it needs.

---

## One-time setup (only you can do this)

### 1. Create the App Store Connect record

App Store Connect ▸ Apps ▸ **+** ▸ New App.

| Field | Value |
| --- | --- |
| Platforms | **iOS** (tick macOS too — same record, and it saves re-doing this later) |
| Name | LetsLapse |
| Primary language | English (UK) |
| Bundle ID | `com.regularsteven.letslapse` |
| SKU | anything unique and private, e.g. `letslapse-001` |
| User access | Full Access |

If the bundle ID isn't in the dropdown, register it first at
developer.apple.com ▸ Certificates, Identifiers & Profiles ▸ Identifiers, with
these capabilities enabled to match what the app is signed for:

- **Increased Memory Limit** (the app's iOS entitlement — blending large frames)

The Watch app needs its own identifier too:
`com.regularsteven.letslapse.watchkitapp`.

### 2. Mint an App Store Connect API key

Users and Access ▸ Integrations ▸ App Store Connect API ▸ **+**. Role:
**App Manager**.

You get three things, and the `.p8` downloads **exactly once**:

```bash
export ASC_KEY_ID=XXXXXXXXXX
export ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
mkdir -p ~/.appstoreconnect/private_keys
mv ~/Downloads/AuthKey_XXXXXXXXXX.p8 ~/.appstoreconnect/private_keys/
```

Keep the filename `AuthKey_<key id>.p8` — `altool` looks it up by name. Back it
up somewhere that is **not** this repo; if you lose it you revoke and re-mint.

Put the two `export` lines in your shell profile so the script always sees them.

The key does double duty: it authorises the upload, *and* it lets `xcodebuild`
create the Apple Distribution certificate and App Store provisioning profiles
during export. That matters here — see "Signing" below.

### 3. Answer the App Store Connect questions

Once the first build finishes processing:

- **Export compliance** — already answered in the binary
  (`ITSAppUsesNonExemptEncryption = false` in `App/Info.plist`), so builds
  should process straight through without asking. If App Store Connect ever
  does ask, the answer is *no non-exempt encryption*: the app implements no
  cryptography of its own and only uses Apple's — SHA256 for cache keys,
  HKDF for the remote's pairing key, and Network.framework TLS for the link.
- **Beta App Description / feedback email** — TestFlight ▸ Test Information.
  Required before you can invite external testers.
- **Test groups** — TestFlight ▸ Internal Testing for your own devices (up to
  100 users, no review). External groups (up to 10,000) need a one-time Beta
  App Review per version, usually a day or less.

---

## Signing

The Mac this was set up on has an **Apple Development** certificate and a
**Developer ID Application** certificate. Neither can sign a TestFlight build:
Developer ID is for distributing outside the App Store, and Development can't
be uploaded at all.

The missing one is **Apple Distribution**. You don't need to create it by hand —
with the `ASC_*` variables set, `xcodebuild` creates it and the matching App
Store profiles automatically on first export. That is the whole reason the API
key is required before the first build, not just before the first upload.

(There is also a *revoked* Apple Development certificate sitting in your
keychain. It's harmless — the valid one is picked automatically — but it's
worth deleting from Keychain Access to stop it confusing future signing errors.)

---

## Version and build numbers

- **Marketing version** is `MARKETING_VERSION` in the project, currently
  **0.1.0**. It's set in four places (Debug/Release × app/Watch) and they must
  stay equal — App Store Connect rejects a Watch app whose version differs from
  its host.
- **Build number** is derived from the commit count (`git rev-list --count
  HEAD`) at build time, so it always rises and always traces back to a commit.
  Override with `--build N` when you need to re-upload the same commit after a
  signing fix.

Every upload needs a build number higher than the last for that marketing
version. Bump `MARKETING_VERSION` when you want a fresh series.

---

## What a build does, step by step

`testflight.sh` archives, exports, checks, and (with `--upload`) validates and
uploads. Two of those steps exist because of failure modes that are expensive
to diagnose later:

- **`get-task-allow` check.** The archive is signed for development, and the
  export is what re-signs it for distribution. If that re-sign silently doesn't
  happen, the upload is rejected minutes later with a signature error that
  never mentions the cause. The script unpacks the `.ipa` and fails on the spot
  instead.
- **`--validate-app` before `--upload-app`.** Same defects, about a minute, and
  without consuming a build number on Apple's side.

Logs land in `build/testflight/ios/{archive,export}.log`.

---

## App Store readiness, as it stands

Fixed as part of this work:

- **Privacy manifest** (`App/PrivacyInfo.xcprivacy`) — declares the four
  required-reason APIs the app actually uses: UserDefaults (`CA92.1`), file
  timestamps (`DDA9.1`), disk space (`E174.1`), system boot time (`35F9.1`).
  Without it every upload draws an ITMS-91053 mail per API and review
  eventually blocks. It also declares **no** data collection and no tracking,
  which is accurate: captures, projects and AI tags never leave the device.
- **Export compliance** answered in the binary, so uploads don't park in
  "Missing Compliance".
- **Marketing version** `0.1` → `0.1.0`.

Already fine, checked rather than assumed:

- App icons complete for iOS, macOS and Watch, with correct alpha (opaque
  1024 for iOS, alpha only where it belongs).
- All `LL_*` launch hooks are behind `#if DEBUG` and cannot fire in a Release
  build.
- No App Transport Security exceptions, no hardcoded endpoints, no
  subprocess launches.
- Usage strings present for camera, microphone, photo-add, location and local
  network. Photos access is add-only (`.addOnly`), which matches the
  add-only usage string — no read permission is requested or needed.

Worth knowing before testers hit it:

- The **test card rig ships in Release by decision** (see `CLAUDE.md`). It arms
  only in front of a live card and shows a cancellable countdown, so testers
  won't trip it by accident, but it *is* reachable in a TestFlight build.
- **MLX scene-analysis models download on demand** from Hugging Face. The app
  itself is ~31 MB; the model is not in it. Testers on cellular will want to be
  warned in your Beta App Description.

---

## macOS: what the sandbox needs

macOS TestFlight is backed by the Mac App Store, which refuses an unsandboxed
binary. `App/LetsLapse.entitlements` currently sets:

```xml
<key>com.apple.security.app-sandbox</key>
<false/>
```

Turning it on is a real behaviour change, not a flag flip, so it's deliberately
not part of this pass. When you want it, the entitlement set the app needs is:

| Entitlement | Why |
| --- | --- |
| `com.apple.security.app-sandbox` | required |
| `com.apple.security.device.camera` | already present |
| `com.apple.security.device.audio-input` | already present |
| `com.apple.security.files.user-selected.read-write` | already present — `.lapse` import/export |
| `com.apple.security.network.client` | Hugging Face model downloads, remote client |
| `com.apple.security.network.server` | the Bonjour `NWListener` the camera advertises |
| `com.apple.security.personal-information.photos-library` | `PHPhotoLibrary` saves |
| `com.apple.security.personal-information.location` | geotagging |

The encouraging part: a scan for the things that usually break under sandboxing
came back clean. There are no `Process()` launches, no hardcoded paths outside
the container, and the two `NSHomeDirectory()` uses (the thumbnail cache key and
the Hugging Face cache directory) are already container-relative and behave
correctly when the container moves.

What still has to be *verified* rather than reasoned about, because sandbox
denials are silent:

1. Camera and microphone capture still start.
2. Saving a blend to Photos still succeeds.
3. The Bonjour remote still advertises *and* the Mac still finds an iPad.
4. The Mac blend runner's scratch directory still writes (it lives in the app
   library, so it should, but it's the one with the disk-space guard).
5. Double-clicking a `.lapse` in Finder still imports.

Once those pass, `tools/release/ExportOptions-macOS.plist` is already written
and `./tools/release/testflight.sh --platform macos --upload` works. The script
refuses to build macOS while the sandbox is off, so it can't produce a `.pkg`
that would only be rejected on upload.
