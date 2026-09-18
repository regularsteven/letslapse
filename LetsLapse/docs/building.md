# Building LetsLapse yourself — Mac, iPhone, iPad

For anyone curious with a Mac. No developer background assumed; every step is
a click path in Xcode, and the two Terminal commands are marked optional.
The first time takes about an hour, most of it downloads. Written 2026-09-18,
after the first checkout on a second Mac failed with a wall of "Missing package
product" errors and a Watch-app signing error — both decoded at the end.

## What you need

- **A Mac with Apple silicon** (M1 or later) and about 40 GB free. Xcode is big.
- **Xcode**, free from the Mac App Store. Last verified with Xcode 26.1.1 on
  macOS 15.6. Your Xcode must be at least as new as the iOS on your phone —
  a phone running a newer iOS than your Xcode knows will not appear as a
  destination, so update Xcode first.
- **GitHub Desktop** (free), or any git client.
- **An Apple ID.** A free one is enough to run the app on your own iPhone,
  iPad or Mac (Apple calls this a Personal Team), with limits: an app put on
  a phone this way stops opening after 7 days (press Run again to renew it),
  three such apps per device, and you trust yourself as a developer on the
  phone once. A paid Apple Developer membership lifts those limits.
- **Internet** for the first open: Xcode downloads a few hundred megabytes of
  Swift packages (the MLX machine-learning engine is the big one).
- An **iPhone or iPad on iOS 17 or later** and a USB cable. An Apple Watch is
  optional; the Watch app rides inside the iPhone app.

## 1. Get the code

GitHub Desktop ▸ File ▸ Clone Repository ▸ URL tab ▸
`https://github.com/regularsteven/letslapse` ▸ Clone.

Then switch branches: **Current Branch ▸ `ios-app`**. The default branch,
`main`, is the original Raspberry Pi project; the app lives on `ios-app`.
Fetch origin now and then to stay current.

Everything the app needs is in the checkout. There is no install step, no
package manager to run and nothing to download by hand: the one third-party
package that used to need a Terminal recipe is committed since 2026-09-18.

## 2. Set up Xcode once, before opening the project

1. Launch Xcode, accept the licence, let it finish installing its components.
2. **Xcode ▸ Settings ▸ Components.** Install the **iOS** platform if you want
   to run the app in the Simulator (a real phone does not need it), and get
   the **Metal Toolchain** — Xcode 26 and later download it separately. The
   MLX engine compiles its GPU code when the app builds, so without it the
   build stops with *cannot execute tool 'metal' due to missing Metal
   Toolchain*. Optional Terminal equivalent:

   ```
   xcodebuild -downloadComponent MetalToolchain
   ```

3. **Xcode ▸ Settings ▸ Accounts ▸ + ▸ Apple ID.** Sign in. This is what
   lets Xcode sign the app for your devices.

## 3. Open the project and wait

Double-click `LetsLapse/LetsLapse.xcodeproj` inside the checkout. Xcode starts
resolving Swift packages at once — progress shows in the toolbar and under
the Report navigator (⌘9). The first time takes minutes, and the **Build**
command stays disabled until every package is in. Wait it out.

If the file list on the left ends with a "Package Dependencies" group that
lists mlx-swift, swift-huggingface, swift-transformers and friends, you are
there. If it instead says *Missing package product*, resolution is not done or
one download failed: **File ▸ Packages ▸ Resolve Package Versions**, and if
that does not clear it, **File ▸ Packages ▸ Reset Package Caches**.

## 4. Tell Xcode who you are (signing)

Click the blue **LetsLapse** project icon at the top of the file list, then
under **TARGETS** select **LetsLapse** and open the **Signing & Capabilities**
tab.

**If you are Steven on a new Mac:** the team and identifiers are already in
the project. Once the Apple ID from step 2 is signed in, the pane clears by
itself; if it still shows a red error, press **Try Again**, then do the same
on the **LetsLapse Watch App** target. That is all.

**If you are anyone else** — Apple ties app identifiers to the team that
registered them, so Steven's cannot be used by yours:

1. **Team:** choose your own (with a free Apple ID it is "Your Name
   (Personal Team)").
2. **Bundle Identifier:** change `com.regularsteven.letslapse` to something
   of your own in reverse-domain form, e.g. `com.yourname.letslapse`.
3. Under **TARGETS** select **LetsLapse Watch App** and repeat: your Team, and
   Bundle Identifier `com.yourname.letslapse.watchkitapp` — it must be your
   app's identifier plus `.watchkitapp`.
4. Still on the Watch target, open the **Info** tab and change
   **WKCompanionAppBundleIdentifier** to your app's identifier
   (`com.yourname.letslapse`). If the row is not there, it lives in
   **Build Settings** — type `WKCompanionAppBundleIdentifier` in the filter.

Xcode then registers the identifiers with your team and creates the signing
profiles. A green "Provisioning profile … created" line, or simply no error,
means you are done. Red errors are decoded in the table at the end.

## 5. Run it on your iPhone or iPad

1. Plug the phone in, unlock it, tap **Trust** when it asks about the Mac.
2. On the phone: **Settings ▸ Privacy & Security ▸ Developer Mode ▸ on**
   (it restarts). Without this the phone never appears in Xcode.
3. In Xcode's toolbar pick the scheme **LetsLapse** and, as the destination,
   your phone (Xcode may say it is "preparing" the device for a minute).
4. Press **▶ Run** (⌘R). The first build takes 5–15 minutes on an M-series
   Mac — the MLX engine is a large C++ compile; later builds take seconds.
5. Free Apple ID only, first launch: the phone says **Untrusted Developer**.
   Settings ▸ General ▸ VPN & Device Management ▸ your Apple ID ▸ Trust,
   then open the app again.

The Watch app is embedded in the iPhone app; a paired Apple Watch gets it
through the phone's Watch app (or automatically, if that is on).

## 6. Run it on the Mac

Same scheme, destination **My Mac**, ▶ Run. Any team works here. The app asks
for camera and microphone access on first use.

## 7. Simulator, no device at all

Destination: any iPhone or iPad simulator (needs the iOS platform from
step 2). Capture is unavailable — the Simulator has no camera — but importing
videos and photos, blending and the whole editor work.

## About the AI features (why the download and the build are big)

LetsLapse's on-device scene understanding runs Google's Gemma 4 model through
Apple's MLX engine, entirely on the device. The engine itself is compiled into
the app — that is the mlx-swift package download and the Metal Toolchain —
but **nothing AI runs or downloads on its own**:

- Models are multi-gigabyte downloads that you start yourself, from
  **Settings ▸ AI models**. Nothing is fetched at first launch.
- Before offering a model, the app measures the device's memory and refuses
  what would be killed by iOS mid-inference (an 8 GB iPhone is the floor for
  the smallest model).
- Every other feature — capture, interval shoots, blending, the editor,
  collections, the Watch remote — works without any model.

On iPhone the AI relies on Apple's *Increased Memory Limit* capability,
which is in the project's entitlements; it is why the app needs an explicit
App ID of its own, and Xcode arranges that during signing. The engine version
is pinned exactly (`mlx-swift` 0.31.4) because newer ones need a newer Swift
toolchain than the Xcode this was built with — do not "update to latest
package versions" without reading `tools/mlx-vlm-spike/vendor/README.md`.

## If it goes wrong

| Xcode says | It means | Do this |
| --- | --- | --- |
| *Missing package product 'LetsLapseKit'* (and 'MLX', 'MLXVLM', 'MLXLMCommon', 'HuggingFace', 'Tokenizers') | Package resolution did not finish or failed for one package. They fail as a set, so `LetsLapseKit` being "missing" while its folder is right there is normal. | Wait; File ▸ Packages ▸ Resolve Package Versions; then Reset Package Caches. Check the checkout has `LetsLapse/tools/mlx-vlm-spike/vendor/mlx-swift-lm/Package.swift` — it is committed since 2026-09-18, so an older checkout needs a fetch. |
| *Unable to log in with account '…'. The login details … were rejected.* | Xcode's saved session for that Apple ID is stale — a new Mac, settings carried over by Migration Assistant, or a changed password. | Xcode ▸ Settings ▸ Accounts ▸ select the account ▸ **−** to remove it ▸ **+** to add it again and sign in. |
| *No profiles for 'com.regularsteven.letslapse.watchkitapp' were found* | Xcode could not create the Watch app's signing profile: because of the login error above, or because that identifier belongs to another team. | Fix the login first; then Signing & Capabilities ▸ **Try Again** on the Watch target. Not on Steven's team? Change the identifiers as in step 4. |
| *The app identifier "…" cannot be registered to your development team* | The identifier is Steven's. | Step 4: your own identifiers. |
| *Your maximum App ID limit has been reached* | A free Apple ID may register ten identifiers a week. | Wait a week, or reuse identifiers you already made. |
| *cannot execute tool 'metal' due to missing Metal Toolchain* | The Metal Toolchain component is not installed. | Step 2. |
| Your phone is not offered as a destination | Not trusted, Developer Mode off, locked, or the phone's iOS is newer than Xcode. | Step 5; or update Xcode. |
| *Missing private key* on the signing certificate (a Mac set up from an old one) | The certificate came across without its key. | Keychain Access ▸ My Certificates ▸ delete that Apple Development certificate; Xcode makes a new one on the next Try Again. Or, on the old Mac, Xcode ▸ Settings ▸ Accounts ▸ Export Apple ID and Code Signing Assets, and import the file on the new one. |
| Signing pane objects to *Increased Memory Limit* on your team | Not every team may carry that capability. | Remove the key from `App/LetsLapse-iOS.entitlements` to build without it; everything but the largest AI models still works. |

## For developers

- **Device build from the Terminal** (the Release configuration is the
  field-test build; the Xcode scheme's Run action builds Release too):

  ```
  xcodebuild -project LetsLapse/LetsLapse.xcodeproj -scheme LetsLapse \
    -destination 'generic/platform=iOS' -configuration Release \
    -derivedDataPath ~/Library/Developer/LetsLapseRun/dd-device-release \
    -allowProvisioningUpdates build
  xcrun devicectl device install app --device <udid> <path to LetsLapse.app>
  ```

  `-allowProvisioningUpdates` uses the Apple ID signed in to Xcode, so the
  Accounts fix above unblocks this path too.
- **Simulator and Mac builds** into an isolated DerivedData:
  `python3 .claude/skills/run-letslapse/driver.py build sim|mac`. A fresh
  Simulator for PicPlace work: `LetsLapse/tools/sim-fresh.sh`.
- **Engine only:** `cd LetsLapse/Kit && swift build -c release` for the
  `lapse` CLI, `swift test` for the suite.
- **TestFlight:** `docs/testflight.md`.
- **Why the project looks like this:** the AI engine's language-model
  library is a committed, patched copy of `ml-explore/mlx-swift-lm` at
  `tools/mlx-vlm-spike/vendor/mlx-swift-lm/` (`vendor/README.md` has the why,
  `vendor/refresh.sh` regenerates it; never edit it by hand). Steven's team
  and bundle identifiers are pinned in the project, which is why step 4 is
  five edits for anyone else — collapsing that to one file is an open job
  in `docs/TODO.md`, as is un-vendoring the engine.
