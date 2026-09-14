import LetsLapseKit
import SwiftUI

#if DEBUG && os(macOS)
/// The editors `LL_EDITOR` has already opened in this process — see the hook.
@MainActor private var llHookOpenedEditors: Set<UUID> = []
@MainActor private var llHookDragFired = false
#endif

@main
struct LetsLapseApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    // Purely to catch files opened while the app is already running — see
    // `LetsLapseAppDelegate`.
    @NSApplicationDelegateAdaptor(LetsLapseAppDelegate.self) private var appDelegate
    #endif

    init() {
        Self.quietenMetalShaderCompiler()

        // Any capture log still on disk at launch outlived the process that
        // wrote it — a crash or a force-quit with the camera open. Scanned
        // before anything can start a new session, so the leftovers are
        // unambiguous, and surfaced in Settings ▸ Incomplete Captures.
        CaptureSessionLogger.shared.scanForOrphanedLogs()

        // Same reasoning, far more disk: a project import that was killed
        // part-way leaves its whole half-unpacked tree behind, and only a
        // later launch can know it was abandoned.
        ImportStaging.sweepOrphans()

        // The experiment logs (`liveblend-*.json/.ndjson`) and ladder logs
        // used to accumulate for ever — 277 files / 39 MB on the iPhone
        // (Part 1 R5). The newest 50 of each stay, as the console log keeps
        // its newest 12 (W11).
        let logs = StorageRoot.current.appendingPathComponent("Logs", isDirectory: true)
        ExperimentLog.prune(directory: logs, prefix: "liveblend-", keep: 50)
        ExperimentLog.prune(directory: logs, prefix: "ladder-", keep: 50)

        // And the network's own staging tree. A day rather than 15 minutes:
        // a partial transfer is the only thing that makes a resume possible,
        // and it can legitimately outlive several launches while somebody is
        // half-way through rescuing a shoot off a phone.
        AppModel.cleanStaleIncoming()

        // Capture Flat used to be one bool for the whole app; it is now stored
        // per capture scope (stills / video). Seed both from the old value
        // before any view can read one — `@AppStorage` has no fallback key, so
        // an unseeded scope would show the toggle off for someone who had it on.
        FlatCapture.migrateIfNeeded()

        #if DEBUG
        // LL_RESET_CAPS=1 — drop the cached device capability matrix before
        // anything can read it, so a tester can force a fresh format probe
        // without reinstalling the app. Here rather than in
        // `applyUIPreviewHooks` because `CameraController.configure()` loads
        // the cache as soon as the camera appears.
        if let reset = ProcessInfo.processInfo.environment["LL_RESET_CAPS"], reset != "0" {
            DeviceCapabilityMatrix.invalidateCache()
        }
        #endif

        #if os(iOS)
        // Activate in init, not view onAppear: when the Watch messages a
        // not-running phone app, iOS launches it in the background to deliver —
        // no UI is built there, so an onAppear-tied activation never runs and
        // the Watch's message dies with a timeout.
        WatchRemoteControlReceiver.shared.activate()
        #endif
    }

    /// Silences the "Warning: Compilation succeeded with: …unused variable
    /// 'MAX_REDUCE_SPECIALIZED_DIMS'…" block that MLX's first inference prints
    /// once per JIT-compiled kernel, burying every real log line under it.
    ///
    /// The warnings are not MLX's to suppress and there is no Swift API for
    /// them: `Device::build_library_` only prints when `newLibrary` returns
    /// *nil*, so a library that compiles with warnings is reported by Metal's
    /// own compiler service, not by mlx. (`MLX_METAL_DEBUG` looks like the
    /// lever and isn't — it is an `#ifdef` in mlx's C++, a build-time flag on a
    /// dependency this app consumes prebuilt, so setting it in the environment
    /// does nothing.) `MTL_IGNORE_WARNINGS` is the Metal-side switch, read
    /// lazily when a shader is first compiled — hence here, ahead of anything
    /// that could touch the GPU, rather than in `SceneAnalyser`.
    ///
    /// Not overwritten if it is already set, so a scheme entry (or
    /// `MTL_IGNORE_WARNINGS=0` when the warnings are the thing being debugged)
    /// still wins.
    private static func quietenMetalShaderCompiler() {
        #if canImport(MLX)
        setenv("MTL_IGNORE_WARNINGS", "1", 0)
        #endif
    }

    /// The app's one screen, shared by both platforms' scenes below.
    private var root: some View {
        ContentView()
            .environmentObject(model)
            .environmentObject(model.processingProgress)
            // A `.lapse` double-clicked in Finder or opened from the Files
            // app. SwiftUI holds the URL until this view exists, so a file
            // that *launched* the app arrives here too rather than being
            // dropped on the floor — verified on a cold launch, which is
            // the case that actually matters for a double-click. The type
            // that makes Launch Services route it here at all is declared
            // in App/Info.plist.
            //
            // Do NOT reach for `handlesExternalEvents` to stop the Mac opening
            // a window per file: it does reuse the window, and it also stops
            // the URL ever arriving here, so opening a project silently does
            // nothing at all. The single-window scene below is the fix.
            .onOpenURL { url in
                // The PicPlace sign-in callback (letslapse://…) or a .lapse file.
                if !model.picplace.handleCallbackURL(url) {
                    model.openArchive(at: url)
                }
            }
            #if os(macOS)
            // The warm half of the same door, and the earliest point a file
            // that launched the app can be acted on: the model exists from
            // here, so anything the delegate caught before now is released.
            .onAppear {
                LetsLapseAppDelegate.handler = { url in
                    if !model.picplace.handleCallbackURL(url) {
                        model.openArchive(at: url)
                    }
                }
                // The last queued write lands before the process goes (W6),
                // the compatibility export is regenerated from the documents
                // (M3), and the lock goes with it (Phase 4).
                LetsLapseAppDelegate.willTerminate = {
                    model.flushLibraryPersistsAndExport()
                    model.releaseLibraryLock()
                }
            }
            #endif
    }

    var body: some Scene {
        #if os(macOS)
        // `Window`, not `WindowGroup`: a group makes a NEW window for every
        // document opened from the Finder, so a second double-click gives a
        // second LetsLapse showing the same library — and a third, and a
        // fourth. There is nothing to put in a second one: every window of the
        // group renders the same shared AppModel, down to the import sheet
        // appearing on all of them at once. A `.lapse` is not a document this
        // app edits in a window, it is a file it swallows into one library, so
        // the library gets exactly one window and opened files land in it.
        // (The photo editor below is a genuine per-document window and stays a
        // group.) The cost is ⌘N, which only ever produced a duplicate.
        Window("LetsLapse", id: "main") {
            root
        }
        .defaultSize(width: 760, height: 680)
        .commands {
            CameraCommands()
            LibraryImportCommands()
        }
        #else
        WindowGroup {
            root
                .onAppear {
                    WatchRemoteControlReceiver.shared.setAppActive(scenePhase != .background)
                }
                // .inactive still counts as active: Control Center or the app
                // switcher over a live camera shouldn't read as "phone away".
                .onChange(of: scenePhase) { phase in
                    WatchRemoteControlReceiver.shared.setAppActive(phase != .background)
                    // Backgrounded is as far as iOS lets an app see its own
                    // end coming: the queued writes land now (W6) and the
                    // compatibility export is regenerated (M3).
                    if phase == .background { model.flushLibraryPersistsAndExport() }
                    // Back in front: did anything else write the manifest
                    // meanwhile? (Phase 4)
                    if phase == .active { model.checkManifestUnchangedSinceLastSeen() }
                }
        }
        #endif

        #if os(macOS)
        // The camera remote. A distinct window rather than a tab so it can sit
        // beside the capture window — the Mac build is both a camera and a
        // remote, and the whole point is watching one screen while driving
        // another device. `Window`, not `WindowGroup`: there is one remote,
        // and a second copy would just fight the first over the connection.
        Window("Camera Remote", id: "remote") {
            RemoteWindow()
        }
        .defaultSize(width: 260, height: 320)
        // The Watch canvas is a fixed 208×248; a resizable window would let
        // the mirror drift off-spec, which is the one thing it must not do.
        .windowResizability(.contentSize)
        .keyboardShortcut("r", modifiers: [.command, .shift])

        // Pulling a project off a phone or an iPad. `Window`, not
        // `WindowGroup`: there is one library to import into, and a second copy
        // would just fight the first over the connection — the serving listener
        // holds a single peer and replaces it on any new connection, so two
        // import windows on one Mac tear each other down.
        Window("Import from Device", id: "import") {
            ImportWindow()
                .environmentObject(model)
            .environmentObject(model.processingProgress)
        }
        .defaultSize(width: 460, height: 520)

        // The grading viewer opens as its own window on the Mac — macOS sheets
        // are fixed-size, and an editor wants free resizing and full screen.
        // One window per photo: reopening the same photo fronts its window.
        WindowGroup(for: PhotoEditorWindowRequest.self) { $request in
            if let request {
                PhotoViewerView(captureID: request.captureID, url: request.url)
                .environmentObject(model)
            .environmentObject(model.processingProgress)
                // The window's own title bar carries the name; the editor
                // content deliberately doesn't repeat it.
                .navigationTitle(request.title)
                // Floor only. The rail is fixed at 340pt, so 720 leaves the
                // image pane a workable ~380pt at the smallest.
                .frame(minWidth: 720, minHeight: 480)
            }
        }
        .defaultSize(width: 1000, height: 700)

        // The video editor gets the same window treatment as the photo
        // editor: free resizing, one window per movie, reopen fronts it.
        WindowGroup(for: VideoEditorWindowRequest.self) { $request in
            if let request {
                VideoEditorView(captureID: request.captureID, url: request.url)
                .environmentObject(model)
            .environmentObject(model.processingProgress)
                .navigationTitle(request.title)
                .frame(minWidth: 720, minHeight: 480)
            }
        }
        .defaultSize(width: 1000, height: 700)

        // The framing review — "Review photos" on an interval project — is a
        // fixed 560×640 window (docs/design/macOS/framing-review.svg): a
        // report with a chart, not an editor, so it neither resizes nor
        // needs to. One per project; reopening fronts it.
        WindowGroup(for: FramingReviewWindowRequest.self) { $request in
            if let request {
                FramingReviewView(captureID: request.captureID)
                    .environmentObject(model)
                    .navigationTitle(request.title)
            }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 560, height: 640)
        #endif
    }
}

/// Five or six tabs — Create, Gallery, [Scans], Projects, Collections,
/// Settings — with the blended-clip flow (Adjust → Processing → Result) laid
/// over them whenever a job is active. Collections is a placeholder while its UX is designed; it
/// took the parked Music spike's slot (MusicView stays in the codebase). Scans
/// sits between the two library tabs and is the *only* place a scanner run is
/// listed: Projects and Gallery exclude them.
///
/// Scans is conditional (`visibleTabs`): scanning is not a primary use case, so
/// the tab appears once the library holds a scan and can be turned off outright
/// in Settings ▸ Advanced ▸ Layout — which hands scanner runs to the Projects
/// list instead. Hidden from the bar is not gone from the hierarchy: the tab
/// stays selectable in code so a finished scan can still open its own screen.
struct ContentView: View {
    @EnvironmentObject var model: AppModel
    /// Settings ▸ Advanced ▸ Layout. Read here rather than off the model so the
    /// bar rebuilds the moment the toggle moves.
    @AppStorage(LayoutSettings.scansMenuKey) private var scansMenuEnabled = true
    @State private var selectedTab: LLTab = .create
    @State private var galleryPath: [UUID] = []
    /// The Gallery's item view (macOS) — here beside its path so a trip to
    /// another tab and back lands on the same project, not the grid.
    @State private var galleryFocus: GalleryFocus?
    @State private var scansPath: [UUID] = []
    @State private var projectsPath: [UUID] = []
    @State private var collectionsPath: [UUID] = []
    @State private var settingsPath: [SettingsDestination] = []
    /// Owns the camera presentation so that selecting the Create tab can open
    /// the camera straight away, over the Create screen (the tab's home).
    @State private var showCamera = false
    @State private var cameraIntent = CaptureIntent()
    /// Cold-launch only, for free: `ContentView` is not rebuilt when the app
    /// returns from the background, so a warm resume never re-arms the splash.
    @State private var showLaunch = LaunchAnimationView.shouldPlayOnLaunch
    #if DEBUG
    /// Raised by the `LL_SCANS*` screenshot hooks: they stage the Scans tab in
    /// states — an empty library above all — where the bar would rightly leave
    /// it out, and a screenshot of the tab needs the tab.
    @State private var forcesScansTab = false
    #endif
    #if os(macOS)
    #if DEBUG
    /// Used only by `applyUIPreviewHooks` to front the remote window for a
    /// screenshot run — the remote is otherwise behind ⌘⇧R, which no headless
    /// verification can press.
    @Environment(\.openWindow) private var openWindow
    #endif
    @State private var lastStage: AppModel.Stage = .home
    /// The tab a flow was started from when that wasn't Create — New clip on
    /// the Gallery panel or a project screen. Entering the flow fronts Create
    /// (below), which the person never chose; leaving it through Back puts
    /// them back here rather than on Create's home. Cleared when they pick
    /// another tab themselves while the flow is parked: from then on the tab
    /// bar is where they are, and Back means Create's home as it always did.
    @State private var flowOriginTab: LLTab?
    /// Raised once at launch when a nominated library location couldn't be
    /// reached and the session fell back to the default (see `StorageRoot`).
    @State private var showStorageFallbackAlert = false
    #endif

    var body: some View {
        ZStack {
            tabs

            // W7: the library on disk could not be read and was set aside.
            // Over every tab — until relaunch when nothing could be rebuilt,
            // or as the account of the rebuild (Phase 4) when it could. The
            // same banner says when another instance holds the lock.
            if let failure = model.libraryLoadFailure {
                VStack {
                    LibraryNoticeBanner(failure: failure)
                    Spacer()
                }
                .zIndex(50)
            } else if let readOnly = model.libraryReadOnly {
                VStack {
                    LibraryNoticeBanner(readOnly: readOnly)
                    Spacer()
                }
                .zIndex(50)
            }

            // On iOS the flow is a full-screen overlay and the tab bar steps
            // aside. On macOS the flow lives inside the Create tab instead
            // (see `tabs`), so the native tab bar stays visible and clickable
            // throughout — switching away parks the flow, switching back
            // resumes it.
            #if os(iOS)
            if model.stage == .home {
                VStack {
                    Spacer()
                    FloatingTabBar(
                        selection: $selectedTab,
                        tabs: visibleTabs,
                        onReselect: handleReselect)
                        .padding(.bottom, 6)
                }
                .transition(.opacity)
            }

            if model.stage != .home {
                FlowView()
                    .background(LL.screenBackground.ignoresSafeArea())
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(1)
            }
            #endif

            // Over everything, including the flow. The camera is deliberately
            // *not* opened underneath it: a `fullScreenCover` presents above the
            // root hosting controller, so nothing in this hierarchy could draw
            // over it. It opens when the splash finishes instead.
            if showLaunch {
                LaunchAnimationView(onFinish: finishLaunch)
                    .transition(.opacity)
                    .zIndex(100)
            }
        }
        .animation(.spring(response: 0.36, dampingFraction: 0.86), value: model.stage)
        // Presented from the root so it covers any tab, and the flow with it: a
        // double-clicked archive can arrive while the app is on any screen at
        // all, or was not running a moment ago.
        //
        // `sheet(item:)` captures the closure's value at presentation and never
        // refreshes it, so the sheet reads the live progress off the model.
        .sheet(item: $model.archiveImport) { _ in
            ProjectImportSheet()
                .environmentObject(model)
            .environmentObject(model.processingProgress)
        }
        .onChange(of: model.requestedProjectDetailID) { requested in
            guard requested != nil else { return }
            selectedTab = .projects
        }
        // A finished scan asking for its own tab. `ScansView` takes it from
        // there and pushes the session; this only moves the selection, the same
        // division of labour the Projects request above uses.
        .onChange(of: model.requestedScanDetailID) { requested in
            guard requested != nil else { return }
            selectedTab = .scans
        }
        // A screen layered over the tabs (the camera's recent-capture tile)
        // asking for a different tab. It dismisses itself; this moves the
        // selection under it.
        .onChange(of: model.requestedTab) { requested in
            guard let requested else { return }
            model.requestedTab = nil
            selectedTab = requested
        }
        // A deep link into a specific Settings page, from a screen that can
        // explain what is missing but not fix it (project detail's
        // "Download a model in Settings" caption).
        .onChange(of: model.requestedSettingsDestination) { requested in
            guard let requested else { return }
            model.requestedSettingsDestination = nil
            selectedTab = .settings
            // The Settings stack is only built once its tab is selected, and a path set in the
            // same update lands before its `navigationDestination` is registered — so it is
            // silently dropped. Push on the next turn, when the stack exists.
            DispatchQueue.main.async { settingsPath = [requested] }
        }
        // Turning the Scans tab off while standing on it: its contents have
        // just moved into the Projects list, so follow them there rather than
        // leave the screen showing with nothing in the bar pointing at it.
        .onChange(of: scansMenuEnabled) { enabled in
            guard !enabled, selectedTab == .scans else { return }
            selectedTab = .projects
        }
        #if os(iOS)
        // Selecting the Create tab opens the camera straight away — the Create
        // screen lives behind it as the tab's home and is revealed on close.
        .onChange(of: selectedTab) { tab in
            if tab == .create { openCameraForCreateTab() }
        }
        // The Watch asking for the camera back. Unlike the tab path this does
        // NOT require `stage == .home`: the capture screen is a full-screen
        // cover presented above the root, so it sits over a parked setup flow
        // without disturbing it. Closing the camera reveals the flow exactly
        // as it was, which is what lets the remote promise the steps survive.
        .onChange(of: model.requestedCameraOpen) { requested in
            guard requested else { return }
            model.requestedCameraOpen = false
            selectedTab = .create
            cameraIntent = CaptureIntent()
            // Next turn: the cover is presented from CreateView, and a tab
            // that was just selected has not built its hierarchy yet — the
            // same ordering the Settings deep link needs.
            DispatchQueue.main.async { showCamera = true }
        }
        .onChange(of: model.stage) { _ in publishFlowContext() }
        // `onReceive`, not `onChange`: these two moved off AppModel onto the
        // run-rate progress model, so AppModel invalidation no longer carries
        // them. Fires on willSet, so the context built here trails the value
        // by one 10 Hz tick — invisible on a watch progress readout.
        .onReceive(model.processingProgress.$fraction) { _ in publishFlowContext() }
        .onReceive(model.processingProgress.$etaDate) { _ in publishFlowContext() }
        .onChange(of: model.guidedStep) { _ in publishFlowContext() }
        .onChange(of: model.guidedBuilderFocused) { _ in publishFlowContext() }
        .onAppear {
            WatchRemoteControlReceiver.shared.setFlowCommandHandler(handleWatchFlowCommand)
            publishFlowContext()
        }
        // When the splash is showing it owns the hand-off; without it (a
        // screenshot run, or a build where it is suppressed) this is the path.
        .onAppear {
            if !showLaunch { openCameraOnLaunch() }
        }
        #endif
        #if os(macOS)
        .onChange(of: model.stage) { newStage in
            // A flow can start from any tab (e.g. "New blended clip" in Projects);
            // bring the Create tab front so the flow is on screen. Entering
            // `.configure` always fronts it — even over a parked flow, that
            // transition means a fresh editing surface was just requested
            // ("from these settings" on the result screen, a Guided clip
            // opened while another flow sat parked).
            if newStage == .configure || (newStage != .home && lastStage == .home) {
                if lastStage == .home, selectedTab != .create {
                    flowOriginTab = selectedTab
                }
                selectedTab = .create
            }
            if newStage == .home {
                // Back, or Cancel. A finished job asks for its project on the
                // Projects tab itself (`finishFlow` → `requestedProjectDetailID`),
                // and that request wins over where the flow began.
                if let origin = flowOriginTab, model.requestedProjectDetailID == nil {
                    selectedTab = origin
                }
                flowOriginTab = nil
            }
            lastStage = newStage
        }
        .onChange(of: selectedTab) { tab in
            // Parking the flow on a tab of their choosing — not the Create
            // front above, and not the return to the origin, which is itself.
            if tab != .create, model.stage != .home { flowOriginTab = nil }
        }
        // Say so up front when the session isn't on the nominated library:
        // otherwise a detached drive just looks like every project vanished.
        .onAppear {
            showStorageFallbackAlert = StorageRoot.customRootUnavailable
        }
        .alert("Library location unavailable", isPresented: $showStorageFallbackAlert) {
            Button("OK") {}
        } message: {
            Text(
                "LetsLapse keeps its library at \(StorageRoot.customPath ?? "its nominated location"), "
                    + "which can't be reached right now — the drive may not be connected. Using the "
                    + "default location for this session; reconnect the drive and relaunch to get back "
                    + "to your library. Settings ▸ Storage has the details.")
        }
        #endif
        .tint(LL.accent)
        #if DEBUG
        .onAppear(perform: applyUIPreviewHooks)
        #endif
    }

    /// The mark has settled — hand over to the app.
    private func finishLaunch() {
        guard showLaunch else { return }
        #if os(iOS)
        // Let the camera slide up *over* a still-opaque field, then drop the
        // field once it is hidden behind the cover. Cross-fading the field out
        // instead exposes the light Create screen underneath for a few frames —
        // the very white flash this screen exists to remove — and racing the
        // presentation with `disablesAnimations` does not win reliably, because
        // the cover is a UIKit presentation and takes its own frames to land.
        // Holding past the animation is the version with no race in it.
        if openCameraOnLaunch() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { showLaunch = false }
            return
        }
        #endif
        withAnimation(.easeOut(duration: 0.3)) { showLaunch = false }
    }

    #if os(iOS)
    /// Open the camera as the Create tab's front surface. Only when the tab is
    /// at rest (no job flow layered over it) — a running or parked flow keeps
    /// the screen it's on.
    ///
    /// Gated on `CreateCameraSetting`: an iPhone is a camera that edits, an
    /// iPad is an editor that can shoot (the Mac's posture — its Create tab
    /// has never auto-opened anything). All three default-behaviour paths
    /// funnel through here — launch, switching to Create, and reselecting it —
    /// while explicit asks (the Record button in Create, the Watch's
    /// `armCamera`) present the camera directly and stay un-gated.
    private func openCameraForCreateTab() {
        guard CreateCameraSetting.opensCamera else { return }
        guard model.stage == .home else { return }
        cameraIntent = CaptureIntent()
        showCamera = true
    }

    // MARK: - Watch: what the phone is doing


    /// The two commands the remote can send when the capture screen isn't
    /// there. Returns whether the command actually ran — a refusal must not
    /// come back as "accepted", or the wrist shows a camera that never opened.
    private func handleWatchFlowCommand(_ command: WatchCaptureCommand, payload: [String: Any]) -> Bool {
        switch command {
        case .armCamera:
            // Never over a running blend. The two would contend for the same
            // GPU, and the remote has a better answer for that case: it shows
            // the render's progress and offers to cancel it.
            guard model.stage != .processing else { return false }
            model.requestedCameraOpen = true
            return true
        case .cancelExport:
            guard model.stage == .processing else { return false }
            model.cancelProcessing()
            return true
        default:
            return false
        }
    }

    private func publishFlowContext() {
        let flow: String
        switch model.stage {
        case .home: flow = "home"
        case .configure: flow = "setup"
        case .processing: flow = "processing"
        case .done: flow = "done"
        }

        let isGuided = model.guidedBuilderFocused
        var eta: Double?
        if model.stage == .processing, let date = model.processingETADate {
            eta = max(0, date.timeIntervalSinceNow)
        }

        WatchRemoteControlReceiver.shared.setPhoneFlowContext(
            flow: flow,
            flowTitle: model.stage == .configure ? (isGuided ? "Guided Clip" : "Adjust") : nil,
            // Only the guided builder counts its steps; Adjust is one surface.
            flowStep: isGuided ? model.guidedStep : nil,
            flowStepCount: isGuided ? model.guidedStepCount : nil,
            exportProgress: model.stage == .processing ? model.progress : nil,
            exportETASeconds: eta,
            exportTitle: model.stage == .processing ? watchExportTitle : nil,
            exportSubtitle: model.stage == .processing ? "Blended clip · camera unavailable" : nil,
            lastCaptureAt: model.newestCapture()?.createdAt
        )
    }

    /// Names the thing being made, not the machinery — "Creating 12.4s clip"
    /// tells you whether it is worth waiting for; "Encoding" does not.
    private var watchExportTitle: String {
        if let summary = model.resultSummary, !summary.isEmpty {
            return summary
        }
        return model.processingStage.title
    }

    /// Create is the launch tab and its purpose is the camera, so present it on
    /// first appear too — but never when a DEBUG preview hook is steering the
    /// app to a specific screen for screenshots. Reports whether it opened, so
    /// the launch screen knows whether it has something to hand off to.
    @discardableResult
    private func openCameraOnLaunch() -> Bool {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        // LL_PROBE_FORMATS is in this list for a different reason than the
        // rest: the probe drives its own capture session, and the camera the
        // launch would otherwise open owns the device while it does.
        let hookKeys = ["LL_TAB", "LL_OPEN", "LL_SEED", "LL_DETAIL", "LL_PUSH", "LL_CAPTURE", "LL_AUTO", "LL_COLLECTIONS", "LL_ADJUST", "LL_REFRAME", "LL_GUIDED", "LL_PROBE_FORMATS", "LL_SECTIONS", "LL_VIEWER", "LL_KEYFRAMES", "LL_PROJECT_SCANNER", "LL_TRANSFER", "LL_TRANSFER_PAIR", "LL_TIMESLICE", "LL_SCANS", "LL_SCANS_EMPTY", "LL_SCANS_DETAIL", "LL_SCANS_CORRECTED", "LL_SCANS_AUTOCORRECT", "LL_SCANS_DELETED", "LL_SCANS_DOCS", "LL_SCANS_EXPORT", "LL_LAYOUT", "LL_EDITOR", "LL_RAIL", "LL_MASK", "LL_IMPORT_STILLS", "LL_IMPORT_VIDEO", "LL_IMPORT_ARCHIVE", "LL_EXPORT_ARCHIVE", "LL_APPLY_PRESET", "LL_DELETE", "LL_LADDERS", "LL_TEXT", "LL_RUNINFO", "LL_RUNDIM", "LL_DNGPROBE", "LL_DNGARCHIVE", "LL_LIGHTROOM", "LL_MIXER", "LL_PRESETS", "LL_SHAPEMATION", "LL_SHAPES", "LL_SHAPES_SCOPE", "LL_SHAPES_MODE", "LL_SHAPES_RUN", "LL_PADS", "LL_SELECT", "LL_PANEL", "LL_DRAG", "LL_PICPLACE", "LL_PICPLACE_TOKENS", "LL_PICPLACE_SERVER"]
        if hookKeys.contains(where: { environment[$0] != nil }) { return false }
        #endif
        guard selectedTab == .create, model.stage == .home else { return false }
        openCameraForCreateTab()
        return true
    }
    #endif

    #if DEBUG
    /// Drive the app into a specific screen from `simctl launch` env vars,
    /// so screens can be screenshot-verified without tap automation.
    private func applyUIPreviewHooks() {
        let environment = ProcessInfo.processInfo.environment
        // `LL_DNGPROBE=1` — print the DNG archive capability table (ImageIO
        // and VideoToolbox encoders, a `jxlc` session attempt, Metal family)
        // to the console and carry on. The Mac and the simulators cannot
        // answer the JPEG XL encoder question; only a device can, and this is
        // how `docs/dng-archive-spike-brief.md` §6.1 asks it. `--console` on
        // `devicectl device process launch` shows the output.
        if let hook = environment["LL_DNGPROBE"], hook != "0" {
            let report = DNGCapabilityProbe.run(tryJPEGXLSession: true)
            print(DNGCapabilityProbe.text(report))
            print("LL_DNGPROBE_JSON_BEGIN")
            print(DNGCapabilityProbe.json(report))
            print("LL_DNGPROBE_JSON_END")
        }
        // `LL_DNGARCHIVE=<project uuid>|latest` — duplicate that interval project
        // as a DNG archive and print every frame's timing to the console: the
        // way libjxl is timed on a device. `LL_DNGARCHIVE_MP` (megapixels,
        // default keep), `LL_DNGARCHIVE_DISTANCE` (default 0.5, 0 = lossless),
        // `LL_DNGARCHIVE_LIMIT` (first N frames) shape the run.
        if let hook = environment["LL_DNGARCHIVE"], hook != "0" {
            // stdout is a file when the Mac binary is launched from a shell
            // with a redirect, and then fully buffered — the last frames and
            // the totals would sit in the buffer until exit.
            setlinebuf(stdout)
            let megapixels = environment["LL_DNGARCHIVE_MP"].flatMap(Double.init)
            let distance = environment["LL_DNGARCHIVE_DISTANCE"].flatMap(Float.init) ?? 0.5
            let limit = environment["LL_DNGARCHIVE_LIMIT"].flatMap(Int.init)
            let inFlight = environment["LL_DNGARCHIVE_INFLIGHT"].flatMap(Int.init) ?? 2
            Task { @MainActor in
                let capture = hook == "latest"
                    ? model.newestCapture(where: { model.canArchiveAsDNG($0) })
                    : model.newestCapture(where: { $0.id.uuidString.lowercased().hasPrefix(hook.lowercased()) && model.canArchiveAsDNG($0) })
                guard let capture else {
                    print("LL_DNGARCHIVE: no archivable project matches \(hook)")
                    return
                }
                let strategy = DNGArchive.Strategy.archive(megapixels: megapixels, distance: distance)
                print("LL_DNGARCHIVE: \(capture.displayTitle) [\(capture.id.uuidString)] → \(strategy.label)\(limit.map { " · first \($0) frames" } ?? "") · \(inFlight) in flight")
                do {
                    let clone = try await model.duplicateAsDNGArchive(
                        capture, strategy: strategy, nameSuffix: "DNG hook", limit: limit, inFlight: inFlight,
                        progress: { snapshot in
                            if let last = snapshot.lastReport {
                                let stages = last.stages.map { String(format: "%@ %.0f", $0.0, $0.1) }.joined(separator: " ")
                                print(String(format: "LL_DNGARCHIVE: frame %d/%d %@ %dx%d %.0f ms [%@] %d bytes",
                                             snapshot.framesDone, snapshot.framesTotal, last.output.lastPathComponent,
                                             last.width, last.height, last.totalMilliseconds, stages, last.outputBytes))
                            }
                        })
                    print("LL_DNGARCHIVE_DONE: \(clone.id.uuidString) \(clone.sourceFileNames.count) frames")
                    if let data = try? Data(contentsOf: model.projectFolderURL(for: clone).appendingPathComponent("dng-archive.json")),
                       let ledger = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        print(String(format: "LL_DNGARCHIVE_TOTAL: %.1f s · %.2f frames/s · %.1f MB → %.1f MB",
                                     ledger["elapsedSeconds"] as? Double ?? 0, ledger["framesPerSecond"] as? Double ?? 0,
                                     Double(ledger["inputBytes"] as? Int ?? 0) / 1e6, Double(ledger["outputBytes"] as? Int ?? 0) / 1e6))
                    }
                } catch {
                    print("LL_DNGARCHIVE_FAILED: \(error)")
                }
            }
        }
        #if os(macOS)
        // Both remote hooks open the window, because it is behind ⌘⇧R and no
        // headless run can press that. They are mutually exclusive in practice:
        // `LL_UI_PREVIEW=<screen>` stages FAKE state and freezes out real
        // payloads (`WatchCaptureRemote.applyDebugPreviewStateIfRequested`),
        // while `LL_REMOTE_CONNECT=<code>` dials a REAL camera — the one that
        // answers "does the Mac show what the iPad is actually doing?".
        if let screen = environment["LL_UI_PREVIEW"], !screen.isEmpty {
            openWindow(id: "remote")
        } else if let code = environment["LL_REMOTE_CONNECT"], code.count == 6 {
            openWindow(id: "remote")
        }
        // `LL_TRANSFER=1` — the Import from Device window, same reasoning as
        // the remote hooks above: it is behind ⌘⇧I and no headless run can
        // press that. It stages nothing; the window browses for real, which is
        // the point — the screenshot has to be of the actual browse state.
        // `LL_TRANSFER=<6-digit code>` goes further and pairs with the first
        // device found; see `ImportWindow.autoRunIfRequested`.
        if let hook = environment["LL_TRANSFER"], hook != "0" {
            openWindow(id: "import")
        }
        // `LL_TRANSFER_PAIR[=<device name>]` — the same window, parked on the
        // pairing screen with its QR scanner live and nothing advertising.
        // The Mac's whole reason for having one is only checkable this way:
        // the screen is otherwise two clicks past a device that has to exist.
        if environment["LL_TRANSFER_PAIR"] != nil {
            openWindow(id: "import")
        }
        #endif
        // `LL_LAYOUT=noscans,counts,nopads` — Settings ▸ Advanced ▸ Layout,
        // staged. Written into the defaults the toggles themselves read, so
        // the whole app (tab bar, Projects filter bar, Editor) sees the same
        // switch a tap makes. `pads` is accepted for symmetry and is the
        // default. (`LL_PADS=off`, by contrast, is read from the environment
        // by the editor and writes nothing: the Mac driver runs the real app
        // on the real defaults, and a screenshot must not change a setting.)
        if let hook = environment["LL_LAYOUT"] {
            let parts = hook.split(separator: ",").map(String.init)
            UserDefaults.standard.set(
                !parts.contains("noscans"), forKey: LayoutSettings.scansMenuKey)
            UserDefaults.standard.set(
                parts.contains("counts"), forKey: LayoutSettings.projectCountsKey)
            UserDefaults.standard.set(
                !parts.contains("nopads"), forKey: LayoutSettings.editorPadsKey)
        }
        // Any Scanner hook wants the tab in the bar as well as on screen —
        // `LL_SCANS_EMPTY` in particular stages a library with no scans in it,
        // which is exactly the case the bar now hides the tab for.
        if environment.keys.contains(where: { $0.hasPrefix("LL_SCANS") }) {
            forcesScansTab = true
        }
        switch environment["LL_TAB"] {
        case "projects": selectedTab = .projects
        case "gallery": selectedTab = .gallery
        case "scans": selectedTab = .scans
        case "settings": selectedTab = .settings
        case "create": selectedTab = .create
        case "collections": selectedTab = .collections
        default: break
        }
        // LL_LADDERS=list|editor|rung — the Interval ladders sheet lives on
        // the Create tab, so the hook implies that tab; `CreateView` reads the
        // value itself and opens the sheet on the requested screen.
        if environment["LL_LADDERS"] != nil {
            selectedTab = .create
        }
        // LL_PRESETS=list|preset|lut|import — the Presets sheet, on the Create
        // tab for the same reason; `CreateView` reads the value and opens it.
        if environment["LL_PRESETS"] != nil {
            selectedTab = .create
        }
        // LL_SHAPEMATION=home|find|build|list — the Shape-mation sheet, on the
        // Create tab for the same reason; `CreateView` reads the value.
        if environment["LL_SHAPEMATION"] != nil {
            selectedTab = .create
        }
        // LL_SCANS / LL_SCANS_EMPTY / LL_SCANS_DETAIL / LL_SCANS_CORRECTED —
        // the Scans tab in each of its states. Same reason as every other
        // Scanner hook: no simulator can shoot a scan (no camera to difference
        // frames from, nothing flat to detect), so without these the whole tab
        // is unreachable off-device and cannot be checked against its SVGs.
        if environment["LL_SCANS_EMPTY"] != nil {
            selectedTab = .scans
        } else if let hook = environment["LL_SCANS"] {
            selectedTab = .scans
            // Bare `LL_SCANS=1` opens whatever is really there; `seed` stages
            // the three sessions the list design is drawn from.
            if hook == "seed" || hook == "list" { model.debugSeedScanLibrary() }
        }
        // A single session, opened: eight A4 pages, rectangles on seven, all
        // but one of those corrected — the mixed state the detail screen's
        // ring, its prompt strip and its per-tile badges all describe.
        // `LL_SCANS_AUTOCORRECT` stages what a shoot's own last moment looks
        // like: a session that has just landed, uncorrected, with the automatic
        // pass running over it — the header counting pages and the tiles
        // rectifying one at a time. It is the state a real scan opens in and
        // the only one no static seed can show.
        if let hook = environment["LL_SCANS_AUTOCORRECT"] {
            // `=<n>` sets the page count: eight synthetic pages rectify almost
            // instantly, so a screenshot of the *progress* needs a set big
            // enough to still be working when the shutter clicks.
            let poses = Int(hook) ?? 8
            if let id = model.debugSeedScannerProject(
                poses: max(1, min(poses, 72)), paper: .a4, spacingSeconds: 27) {
                // Drives the SAME route a finished shoot takes — the model
                // asks, ContentView switches tabs, ScansView pushes — rather
                // than setting the path here. A hook that took a short cut
                // would be a hook that couldn't catch the routing breaking.
                if let capture = model.capture(id: id) {
                    model.requestedScanDetailID = id
                    model.autoCorrectScan(capture)
                }
            }
        }
        // `LL_SCANS_DELETED=<page>` — a corrected set with one page thrown
        // away, which is the state the numbering rule exists for: the pages
        // that remain KEEP their numbers, so a set of eight missing its third
        // reads 1, 2, 4…8 rather than closing up. Nothing else in the app can
        // produce it without a long-press and a confirmation.
        if let hook = environment["LL_SCANS_DELETED"] {
            if let id = model.debugSeedScannerProject(
                poses: 8, corrected: true, paper: .a4, spacingSeconds: 27) {
                if let capture = model.capture(id: id) {
                    model.deleteScanPage(Int(hook) ?? 3, from: capture)
                }
                selectedTab = .scans
                scansPath = [id]
            }
        }
        // `LL_SCANS_DOCS=<pages-per-doc>` — a grouped session, opened. Document
        // grouping is decided with a phone over a desk and stored in a sidecar,
        // so like every other Scanner state it cannot be reached on a simulator
        // at all: this stages the sections, their headers and the export
        // sheet's scope picker. `=1` is what "new scan = new doc" produces (a
        // document per page); anything higher is the toggle off with the New
        // Document button pressed every N pages.
        if let hook = environment["LL_SCANS_DOCS"] {
            let perDocument = max(1, Int(hook) ?? 1)
            if let id = model.debugSeedScannerProject(
                poses: 9, corrected: true, paper: .a4, spacingSeconds: 27) {
                let pages = model.capture(id: id)
                    .map(model.scanPageNumbers(for:)) ?? []
                model.debugSeedScanDocuments(
                    for: id, starts: stride(from: 1, through: pages.count, by: perDocument).map { $0 })
                selectedTab = .scans
                scansPath = [id]
            }
        }
        if environment["LL_SCANS_DETAIL"] != nil || environment["LL_SCANS_CORRECTED"] != nil {
            let fully = environment["LL_SCANS_CORRECTED"] != nil
            if let id = model.debugSeedScannerProject(
                poses: 8,
                corrected: true,
                paper: .a4,
                spacingSeconds: 27,
                // Leaves the last page uncorrected, which is the mixed state
                // the prompt strip and the header's partial ring describe.
                correctedLimit: fully ? nil : 7) {
                selectedTab = .scans
                scansPath = [id]
            }
        }
        // `LL_OPEN=latest` opens the newest capture in the Create flow;
        // `LL_OPEN=<capture-uuid>` a specific one — pairs with `LL_AUTO=process`
        // for a headless render of a project that is not the newest.
        if let openHook = environment["LL_OPEN"],
           let capture = openHook == "latest"
            ? model.newestCapture()
            : UUID(uuidString: openHook).flatMap { id in model.capture(id: id) } {
            model.openCapture(capture)
        } else if let seed = environment["LL_SEED"] {
            model.setSource(.video(URL(fileURLWithPath: seed)))
        }
        // LL_IMPORT_STILLS=<path>[:<path>…] — run a real stills import from
        // disk. The picker it stands in for is an NSOpenPanel/UIDocumentPicker,
        // which no headless run can drive, and this is the whole feature behind
        // it: the selection walk, the EXIF probe, the copy, the derived
        // sidecars and the registration. Paths may be folders or files.
        if let paths = environment["LL_IMPORT_STILLS"], !paths.isEmpty {
            model.importStills(from: paths.split(separator: ":").map {
                URL(fileURLWithPath: String($0))
            })
        }
        // LL_IMPORT_VIDEO=<path> — its movie twin.
        if let path = environment["LL_IMPORT_VIDEO"], !path.isEmpty {
            model.importVideo(from: URL(fileURLWithPath: path))
        }
        // LL_IMPORT_ARCHIVE=<path.lapse> — and the `.lapse` door, the same
        // one a Finder double-click or the picker opens, so the duplicate
        // question (by origin, Phase 1 W3) and the install can be driven
        // headless against a scratch library.
        if let path = environment["LL_IMPORT_ARCHIVE"], !path.isEmpty {
            model.openArchive(at: URL(fileURLWithPath: path))
        }
        // LL_DELETE=latest|<capture-uuid> — deletes that project through the
        // real path (tombstone → persist → `.trash`), for the W9 checks.
        if let which = environment["LL_DELETE"], !which.isEmpty {
            let capture = which == "latest"
                ? model.newestCapture()
                : UUID(uuidString: which).flatMap { id in model.capture(id: id) }
            if let capture {
                do {
                    try model.deleteCapture(capture)
                    LLog("LL_DELETE moved \(capture.id.uuidString) to the trash")
                } catch {
                    LLog("LL_DELETE failed: \(error)")
                }
            }
        }
        // LL_APPLY_PRESET=latest|<capture-uuid>:<Natural|Cinema|Matte|Vivid|
        // Original> — applies that built-in preset to the project through
        // the real grade path (`applyPreset` → `updateCapture`, queued), two
        // seconds after launch so the launch pass has finished: the M2 check
        // that a grade settle rewrites one document and one index row.
        if let raw = environment["LL_APPLY_PRESET"], let colon = raw.lastIndex(of: ":"),
           let preset = PhotoPreset(rawValue: String(raw[raw.index(after: colon)...])) {
            let which = String(raw[..<colon])
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                let capture = which == "latest"
                    ? model.newestCapture()
                    : UUID(uuidString: which).flatMap { id in model.capture(id: id) }
                guard let capture else { LLog("LL_APPLY_PRESET: no such project \(which)"); return }
                model.applyPreset(preset, for: capture)
                LLog("LL_APPLY_PRESET applied \(preset.rawValue) to \(capture.id.uuidString.prefix(8))")
            }
        }
        // LL_EXPORT_ARCHIVE=latest|<capture-uuid> — writes that project's
        // `.lapse` to the temporary directory and logs the path, so a round
        // trip (export → LL_IMPORT_ARCHIVE) needs no Share sheet.
        if let which = environment["LL_EXPORT_ARCHIVE"], !which.isEmpty {
            let capture = which == "latest"
                ? model.newestCapture()
                : UUID(uuidString: which).flatMap { id in model.capture(id: id) }
            if let capture {
                Task {
                    do {
                        let url = try await model.exportProject(capture)
                        LLog("LL_EXPORT_ARCHIVE wrote \(url.path)")
                    } catch {
                        LLog("LL_EXPORT_ARCHIVE failed: \(error)")
                    }
                }
            }
        }
        // `LL_DETAIL=latest|<capture-uuid>` — the project detail screen; a
        // UUID names a specific project (the PicPlace sync verification
        // seeds one into a scratch library and needs to land on it).
        if let detail = environment["LL_DETAIL"] {
            let capture = detail == "latest" ? model.newestCapture() : UUID(uuidString: detail).flatMap { model.capture(id: $0) }
            if let capture {
                selectedTab = .projects
                model.requestedProjectDetailID = capture.id
            }
        }
        // `LL_EDITOR=latest` — the photo editor on the LARGEST interval shoot
        // in the library (the bench wants the worst case), which is otherwise
        // behind a detail-screen button no headless run can press. On macOS it
        // opens the editor window directly; on iOS it routes to the project's
        // detail screen, whose own `LL_EDITOR` task slides the cover over. The
        // perf bench (docs/editor-performance-plan.md) pairs it with
        // `LL_PERFWIGGLE`; it is equally the editor-screen screenshot hook.
        // `LL_EDITOR=video` — the VIDEO editor on the newest movie project,
        // for the same reason: its rail (the shared adjustment panel with the
        // Rotation section, over a playing movie) is otherwise behind a tap.
        // Any other value is a capture UUID — a bench that needs one SPECIFIC
        // shoot (the text-overlay spike's sky project) rather than the biggest.
        if let editorHook = environment["LL_EDITOR"] {
            let capture: AppModel.CaptureProject? = switch editorHook {
            case "latest":
                // The largest interval shoot: the index's frame counts pick
                // the row, its document is read once.
                {
                    var query = LibraryIndex.ProjectQuery()
                    query.category = .interval
                    query.limit = Int(Int32.max)
                    let rows = ((try? model.libraryIndex?.projects(query).rows) ?? nil) ?? []
                    return rows.max(by: { $0.frameCount < $1.frameCount }).flatMap { model.capture(id: $0.id) }
                }()
            case "video":
                {
                    var query = LibraryIndex.ProjectQuery()
                    query.category = .video
                    return model.newestCapture(query)
                }()
            default:
                UUID(uuidString: editorHook).flatMap { id in model.capture(id: id) }
            }
            if let capture {
                #if os(macOS)
                // Once per process: the hooks can run again when the content
                // view is rebuilt, and each run opened ANOTHER editor window on
                // the same project — two or three stacked at one frame, which
                // sent a bench's clicks into whichever was on top
                // (2026-09-04). The first window is the one the hook meant.
                if llHookOpenedEditors.insert(capture.id).inserted {
                    if capture.kind == .video, let url = model.sourceClipURLs(for: capture).first {
                        openWindow(value: VideoEditorWindowRequest(
                            captureID: capture.id, url: url, title: capture.displayTitle))
                    } else if let url = model.sourceFrameURLs(for: capture).first {
                        openWindow(value: PhotoEditorWindowRequest(
                            captureID: capture.id, url: url, title: capture.displayTitle))
                    }
                }
                #else
                selectedTab = .projects
                model.requestedProjectDetailID = capture.id
                #endif
            }
        }
        // LL_PROJECT_SCANNER[=<poses>|corrected] — fabricate a finished Scanner
        // shoot and open its project. The only way to see that screen
        // off-device: a Scanner set cannot be captured on a simulator (no
        // camera to difference frames from, nothing flat to detect), so nothing
        // else can produce a project the Scanner route recognises. `corrected`
        // stages the set with its rectified pages already written, which is the
        // screen's other state.
        if let hook = environment["LL_PROJECT_SCANNER"] {
            let corrected = hook == "corrected"
            let poses = Int(hook) ?? 12
            if let id = model.debugSeedScannerProject(
                poses: max(1, min(poses, 72)), corrected: corrected) {
                selectedTab = .projects
                model.requestedProjectDetailID = id
            }
        }
        if let rawDestination = environment["LL_PUSH"],
           let destination = SettingsDestination(rawValue: rawDestination) {
            selectedTab = .settings
            settingsPath = [destination]
        }
        if let speed = environment["LL_SPEED"].flatMap(Int.init) {
            model.useRamp = false
            model.constantWindow = speed
        }
        if environment["LL_AUTO"] == "process" {
            // Wait for the flow to reach `.configure` rather than guessing at
            // it. The single 1.5 s shot this replaces silently did nothing on
            // any project big enough to take longer to open — a 483-still
            // import needs several seconds just to walk its files — so the
            // headless render hook no-opped on exactly the shoots worth
            // rendering headlessly, and looked like a hung app rather than a
            // missed window.
            func pressWhenReady(attemptsLeft: Int) {
                guard model.stage == .configure else {
                    guard attemptsLeft > 0 else {
                        LLog("LL_AUTO=process: gave up waiting for the configure stage")
                        return
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        pressWhenReady(attemptsLeft: attemptsLeft - 1)
                    }
                    return
                }
                model.startProcessing()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                pressWhenReady(attemptsLeft: 240)   // up to two minutes
            }
        }
        // LL_ADJUST=latest|demo|stills — open a capture on the Adjust screen:
        // the newest video capture, `demo`'s fabricated two-moment sequence
        // (the design's 8:16 sample), or the newest interval shoot whose
        // frames are on disk — the interval warp timeline's screenshot and
        // render hook. LL_STRETCH ("1=0.25,3=15") then pins warp stretch
        // speeds (×-real-time for video, blend depths for stills) for variant
        // screenshots, and LL_ADJUST_CREATE=1 presses Create — the reframe
        // hook's render-check pattern, for checking the finished clip without
        // a tappable UI.
        if let hook = environment["LL_ADJUST"] {
            if hook == "demo" {
                model.debugOpenAdjustDemo()
            } else if hook == "stills", let capture = model.newestCapture({ var q = LibraryIndex.ProjectQuery(); q.category = .interval; return q }(), where: { candidate in
                model.sourceFrameURLs(for: candidate).first
                    .map { FileManager.default.fileExists(atPath: $0.path) } == true
            }) {
                model.openCapture(capture)
            } else if hook != "stills", let capture = model.newestCapture({ var q = LibraryIndex.ProjectQuery(); q.category = .video; return q }()) {
                model.openCapture(capture)
            }
            if let overrides = environment["LL_STRETCH"] {
                model.debugApplyStretchOverrides(overrides)
            }
            // LL_CANVAS=9:16 — pin the Adjust canvas for variant screenshots.
            if let ratio = environment["LL_CANVAS"].flatMap(CanvasRatio.init(rawValue:)) {
                model.blendCanvasRatio = ratio
            }
            // LL_TIMESLICE="segs:8,lag:3,newest:left,output:both,regular:on" —
            // arm the time-slicing recipe for this session (all keys optional;
            // bare "1" takes every default). Set after openCapture, which
            // clears it; pairs with LL_ADJUST_CREATE for a headless render.
            if let hook = environment["LL_TIMESLICE"] {
                var settings = TimeSliceSettings()
                var plan: TimeSliceVariationPlan?
                var locks: [String] = []
                for pair in hook.split(separator: ",") {
                    let parts = pair.split(separator: ":", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { continue }
                    switch parts[0] {
                    case "segs": settings.segments = Int(parts[1]) ?? settings.segments
                    case "lag": settings.offsetFrames = Int(parts[1]) ?? settings.offsetFrames
                    case "newest":
                        settings.newestEdge = TimeSliceEdge(rawValue: parts[1]) ?? settings.newestEdge
                    case "output":
                        settings.output = TimeSliceOutput(rawValue: parts[1]) ?? settings.output
                    case "regular": settings.includeRegularClip = parts[1] != "off"
                    // grid:<corner> and metric:<name> arm a grid recipe — the
                    // state a batch member re-opens in, otherwise reachable
                    // only by rendering a batch first.
                    case "grid":
                        if let origin = TimeSliceGridOrigin(rawValue: parts[1]) {
                            settings.grid = TimeSliceGrid(
                                origin: origin, metric: settings.grid?.metric ?? .manhattan)
                        }
                    case "metric":
                        if let metric = TimeSliceGridMetric(rawValue: parts[1]) {
                            settings.grid = TimeSliceGrid(
                                origin: settings.grid?.origin ?? .topLeft, metric: metric)
                        }
                    // vars:<2|4|8>, mode:<horizontal|vertical|grid|mixed> and
                    // seed:<n> arm a variation batch; a fixed seed is what
                    // makes the readout screenshottable.
                    case "vars":
                        if let count = Int(parts[1]), count >= 2 {
                            plan = TimeSliceVariationPlan(
                                count: count, mode: plan?.mode ?? .mixed, seed: plan?.seed ?? 0x1A2B3C4D)
                        }
                    case "mode":
                        if let mode = TimeSliceVariationMode(rawValue: parts[1]) {
                            plan = TimeSliceVariationPlan(
                                count: plan?.count ?? 4, mode: mode, seed: plan?.seed ?? 0x1A2B3C4D)
                        }
                    case "seed":
                        if let seed = UInt64(parts[1]) {
                            plan = TimeSliceVariationPlan(
                                count: plan?.count ?? 4, mode: plan?.mode ?? .mixed, seed: seed)
                        }
                    // lock:edge+segments+origin — pin those to the baseline
                    // across the batch (the 2026-09-02 controls' fixed seats;
                    // anything not named stays Mixed).
                    case "lock":
                        locks = parts[1].split(separator: "+").map(String.init)
                    default: break
                    }
                }
                plan?.lockEdge = locks.contains("edge")
                plan?.lockSegments = locks.contains("segments")
                plan?.lockOrigin = locks.contains("origin")
                model.timeSlice = settings
                model.timeSliceVariations = plan
            }
            if environment["LL_ADJUST_CREATE"] == "1" {
                model.startProcessing()
            }
        }
        // LL_REFRAME=latest — open the newest video capture in the blended-
        // clip flow with the reframe lane expanded, exactly what the Adjust
        // screen's own "Punch-in reframe" row (which simctl can't tap) does.
        // LL_REFRAME_RATIO=9:16 pins the canvas for variant screenshots.
        if environment["LL_REFRAME"] == "latest",
           let capture = model.newestCapture({ var q = LibraryIndex.ProjectQuery(); q.category = .video; return q }()) {
            model.openCapture(capture)
            model.reframeLaneFocused = true
            if let ratio = environment["LL_REFRAME_RATIO"].flatMap(CanvasRatio.init(rawValue:)) {
                model.blendCanvasRatio = ratio
            }
            // LL_REFRAME_SEED=1 — plant a demo punch move. Screenshots and
            // render checks need keys to show; the product itself never
            // auto-adds any.
            if environment["LL_REFRAME_SEED"] == "1",
               let size = model.sourceDisplaySize(),
               let duration = capture.sourceDurationSeconds, duration > 1 {
                let cx = Double(size.width) / 2
                let cy = Double(size.height) / 2
                model.updateReframe {
                    $0.addKey(t: duration * 0.2, z: 1, cx: cx, cy: cy)
                    $0.addKey(t: duration * 0.45, z: 2.4, cx: cx * 1.3, cy: cy * 0.9)
                    $0.addKey(t: duration * 0.7, z: 1, cx: cx, cy: cy)
                    if $0.moves.count == 2 {
                        $0.setMove(.init(span: .one, curve: .ease), at: 0)
                        $0.setMove(.init(span: .two, curve: .ease), at: 1)
                    }
                }
            }
            // LL_REFRAME_RENDER=1 — go straight to Create, for checking the
            // baked clip without a tappable UI.
            if environment["LL_REFRAME_RENDER"] == "1" {
                model.startProcessing()
            }
        }
        // LL_GUIDED=latest — open the newest video capture in the guided
        // builder, exactly what the project's "Guided clip" button (which
        // simctl can't tap) does. LL_CANVAS=16:9 pins the clip's shape (and
        // with it the merged step's tall/wide layout); LL_STEP=<n> lands on a
        // later step, both for variant screenshots — GuidedBuilderView reads
        // LL_STEP itself, since the step index is its own state.
        if environment["LL_GUIDED"] == "latest",
           let capture = model.newestCapture({ var q = LibraryIndex.ProjectQuery(); q.category = .video; return q }()) {
            model.openCapture(capture)
            model.guidedBuilderFocused = true
            if let ratio = environment["LL_CANVAS"].flatMap(CanvasRatio.init(rawValue:)) {
                model.blendCanvasRatio = ratio
            }
        }
        // LL_COLLECTIONS=seed|list|detail|kenburns — bring the tab front; seed
        // demo collections from existing video blends (no-op without any);
        // detail additionally opens the first collection's timeline, kenburns
        // opens it with Ken Burns switched on.
        if let hook = environment["LL_COLLECTIONS"] {
            selectedTab = .collections
            if hook == "seed" || hook == "list" || hook == "detail" || hook == "kenburns" {
                model.debugSeedCollections()
            }
            if hook == "detail" || hook == "kenburns", let first = model.collections.first {
                if hook == "kenburns" {
                    model.setKenBurnsEnabled(true, for: first.id)
                }
                collectionsPath = [first.id]
            }
        }
        // LL_IMPORT=checking|extracting|installing|duplicate|failed — freeze the project
        // import sheet in one phase. A real import of a 2.4 GB archive is over
        // in about two seconds on an M-series Mac, which is too quick to
        // screenshot or design against; the sheet still has to be right for a
        // slow external drive or a much bigger project.
        if let phase = environment["LL_IMPORT"] {
            var demo = ArchiveImport(
                url: URL(fileURLWithPath: "/Demo/Morning tram 4k.lapse"),
                name: "Morning tram 4k",
                archiveBytes: 2_372_116_934)
            switch phase {
            case "extracting":
                demo.phase = .extracting
                demo.extractedBytes = 1_470_000_000
            case "installing":
                demo.phase = .installing
                demo.extractedBytes = demo.archiveBytes
            case "duplicate":
                demo.phase = .duplicate(existingName: "Morning tram 4k")
            case "failed":
                demo.phase = .failed(
                    "Not enough storage to import this project. It unpacks to at least 2,37 GB but only 1,1 GB is available. Free up space and try again.")
            default:
                demo.phase = .checking
            }
            model.archiveImport = demo
        }
        // LL_TAGS=demo — stamp scene metadata across the library so the Projects
        // search field and tag chips can be verified without a 3.3 GB model.
        if environment["LL_TAGS"] == "demo" {
            model.debugSeedSceneTags()
        }
        // LL_PROBE_FORMATS=1 — log the exposure/ISO envelope of every Bayer RAW
        // format on the back cameras (`LL_PROBE` lines, os_log category
        // "FormatProbe"). Delayed so the camera the launch opens has settled
        // and the active format reported at the end is the real one.
        // iOS-only, like the probe itself — none of what it reads exists on a
        // Mac camera.
        #if os(iOS)
        if environment["LL_PROBE_FORMATS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                HolyGrailFormatProbe.run()
            }
        }
        #endif
        // LL_DRAG=x1,y1,x2,y2[,delay] — a synthetic mouse drag in the main
        // window, in window points from its top-left (what `screencapture -l
        // <windowID>` shows, at 1×), `delay` seconds after launch (default
        // 4) and once per process. Built in-process and handed straight to
        // the view under the point (`DebugDrag`), never through the HID
        // stream, so a drawing gesture — a mask, a shape, a crop handle —
        // can be checked on a copy running beside somebody's own without
        // posting any real input.
        // Pair with the hooks that stage the state it is drawn in, e.g.
        // `LL_TAB=gallery LL_ITEM=latest:masks LL_SHAPETOOL=rect`.
        #if os(macOS)
        if let hook = environment["LL_DRAG"], !llHookDragFired {
            llHookDragFired = true
            let numbers = hook.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if numbers.count >= 4 {
                let delay = numbers.count > 4 ? numbers[4] : 4
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    DebugDrag.perform(from: CGPoint(x: numbers[0], y: numbers[1]),
                                      to: CGPoint(x: numbers[2], y: numbers[3]))
                }
            } else {
                LLog("LL_DRAG: expected x1,y1,x2,y2[,delay], got \(hook)")
            }
        }
        #endif
        // LL_AI=<image path> — run SceneAnalyser on one frame and log the result
        // (LL_AI_PLACE / LL_AI_LIGHT set the context). devicectl and simctl can't
        // tap the Settings row, so this is the automation path for the on-device
        // model, mirroring how the Phase 0 harness had to auto-run on launch.
        if let path = environment["LL_AI"] {
            let place = environment["LL_AI_PLACE"]
            let light = environment["LL_AI_LIGHT"]
            Task {
                let start = Date()
                do {
                    // Through the service, not the actor, so the hook exercises the same path
                    // the "Auto rename & tag" row does — including the installed-model lookup
                    // and, with it, whichever engine the active model names.
                    let result = try await SceneAnalyzerFactory.active().analyze(
                        SceneAnalysisRequest(
                            imageURLs: [URL(fileURLWithPath: path)], place: place, light: light),
                        status: { LLog("[ai] \($0)") })
                    LLog("[ai] title=\"\(result.title)\" tags=\(result.subjectTags) elements=\(result.elements) in \(String(format: "%.2f", Date().timeIntervalSince(start)))s")
                } catch {
                    LLog("[ai] FAILED: \(error)")
                }
            }
        }
    }
    #endif

    #if os(macOS)
    /// macOS uses the same floating pill bar as iOS instead of the native
    /// toolbar tabs: the native bar never reports a click on the already-
    /// selected tab, so reselect-to-pop behaviors are impossible with it.
    /// Only the selected tab is in the hierarchy — hidden-but-alive siblings
    /// would fight over the window title and stay in the accessibility tree.
    /// Navigation state lives in this view's paths, so "the screen you left"
    /// still restores on return.
    private var tabs: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch selectedTab {
                case .create:
                    createContent
                case .gallery:
                    GalleryView(path: $galleryPath, focus: $galleryFocus)
                case .scans:
                    ScansView(path: $scansPath)
                case .projects:
                    ProjectsView(path: $projectsPath)
                case .collections:
                    CollectionsView(path: $collectionsPath)
                case .settings:
                    NavigationStack(path: $settingsPath) {
                        SettingsView()
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                // Clearance so scrolling content and flow buttons stay above
                // the floating tab bar.
                Color.clear.frame(height: 58)
            }

            FloatingTabBar(
                selection: $selectedTab,
                tabs: visibleTabs,
                onReselect: handleReselect,
                // While the guided flow fronts the Create tab, no tab is
                // "where you are" — highlighting Create would claim its home
                // screen is showing. Parking the flow on another tab brings
                // the highlight back, because then it tells the truth again.
                showsSelection: !(selectedTab == .create
                    && model.stage != .home
                    && model.guidedBuilderFocused))
                .padding(.bottom, 12)
        }
    }

    /// The Create tab hosts the flow whenever one is active, so the tab bar
    /// stays reachable throughout a job.
    @ViewBuilder
    private var createContent: some View {
        if model.stage == .home {
            NavigationStack {
                CreateView(showCapture: $showCamera, captureIntent: $cameraIntent)
            }
        } else {
            FlowView()
                .background(LL.screenBackground.ignoresSafeArea())
        }
    }
    #else
    private var tabs: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                CreateView(showCapture: $showCamera, captureIntent: $cameraIntent)
                    .hiddenSystemTabBar()
            }
            .hiddenMoreNavigationBar()
            .tabItem { Label(LLTab.create.title, systemImage: LLTab.create.systemImage) }
            .tag(LLTab.create)

            GalleryView(path: $galleryPath, focus: $galleryFocus)
                .hiddenSystemTabBar()
                .hiddenMoreNavigationBar()
                .tabItem { Label(LLTab.gallery.title, systemImage: LLTab.gallery.systemImage) }
                .tag(LLTab.gallery)

            ScansView(path: $scansPath)
                .hiddenSystemTabBar()
                .hiddenMoreNavigationBar()
                .tabItem { Label(LLTab.scans.title, systemImage: LLTab.scans.systemImage) }
                .tag(LLTab.scans)

            ProjectsView(path: $projectsPath)
                .hiddenSystemTabBar()
                .hiddenMoreNavigationBar()
                .tabItem { Label(LLTab.projects.title, systemImage: LLTab.projects.systemImage) }
                .tag(LLTab.projects)

            CollectionsView(path: $collectionsPath)
                .hiddenSystemTabBar()
                .hiddenMoreNavigationBar()
                .tabItem { Label(LLTab.collections.title, systemImage: LLTab.collections.systemImage) }
                .tag(LLTab.collections)

            NavigationStack(path: $settingsPath) {
                SettingsView()
                    .hiddenSystemTabBar()
            }
            .hiddenMoreNavigationBar()
            .tabItem { Label(LLTab.settings.title, systemImage: LLTab.settings.systemImage) }
            .tag(LLTab.settings)
        }
    }
    #endif

    /// Whether the Scans tab is in the bar right now: allowed by the Layout
    /// setting AND earned by the library holding at least one scan — or simply
    /// being the tab you are standing on. Deleting your last scan empties the
    /// screen you are looking at; it should not also pull the screen out from
    /// under you. The tab drops out of the bar when you next leave it.
    private var showsScansTab: Bool {
        #if DEBUG
        if forcesScansTab { return true }
        #endif
        return scansMenuEnabled && (model.hasScanSessions || selectedTab == .scans)
    }

    /// What the tab bar draws. The hierarchy below it is unchanged either way —
    /// only the bar's own list shrinks.
    private var visibleTabs: [LLTab] {
        LLTab.visible(scans: showsScansTab)
    }

    /// Tab taps: switching tabs keeps each stack where it was, so the first
    /// tap back to a tab restores the screen you left; tapping the tab you're
    /// already on pops it back to its root.
    private func handleReselect(_ tab: LLTab) {
        switch tab {
        case .create:
            // Abandons a parked Adjust or Result and returns to the Create
            // root. A running job stays put — its Cancel button is the only
            // way to stop it. Otherwise (already home) reopen the camera, so a
            // tap on the current tab brings the camera back up.
            if model.stage == .configure || model.stage == .done {
                #if os(macOS)
                // A tap ON Create asks for Create: the origin tab does not apply.
                flowOriginTab = nil
                #endif
                model.reset()
            } else {
                #if os(iOS)
                openCameraForCreateTab()
                #endif
            }
        case .gallery:
            galleryPath = []
            galleryFocus = nil
        case .scans:
            scansPath = []
        case .projects:
            projectsPath = []
        case .collections:
            collectionsPath = []
        case .settings:
            settingsPath = []
        }
    }
}

private extension View {
    /// iOS hides the system tab bar in favor of the floating pill;
    /// macOS keeps its native tab styling.
    @ViewBuilder
    func hiddenSystemTabBar() -> some View {
        #if os(iOS)
        toolbar(.hidden, for: .tabBar)
        #else
        self
        #endif
    }

    /// With six tabs, iPhone's UITabBarController folds tabs 5+ into its
    /// legacy "More" navigation controller even though the system tab bar is
    /// hidden — and the More controller's glass bar floats a phantom back
    /// button (pop target: the invisible More list) over the folded tabs,
    /// Collections and Settings today, pushing their content down a bar's
    /// height. No SwiftUI toolbar preference reaches that bar (measured —
    /// `.toolbar(.hidden, for: .navigationBar)` outside the tab's stack does
    /// nothing), so a zero-size helper controller walks up to the
    /// UITabBarController and hides it with public API. Applied to every tab
    /// so a reorder can't re-surface it.
    @ViewBuilder
    func hiddenMoreNavigationBar() -> some View {
        #if os(iOS)
        background(MoreNavigationBarHider().frame(width: 0, height: 0))
        #else
        self
        #endif
    }
}

#if os(iOS)
/// Hides the tab bar controller's "More" navigation bar — the enclosing bar
/// UIKit gives tabs it folds beyond the first four on iPhone. Re-asserted on
/// every appearance because UIKit re-shows it when the folded selection
/// changes. The More controller's edge-swipe pop is disabled too: it would
/// drag the whole tab away to the never-shown More list.
private struct MoreNavigationBarHider: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Helper { Helper() }
    func updateUIViewController(_ controller: Helper, context: Context) {}

    final class Helper: UIViewController {
        override func viewDidLoad() {
            super.viewDidLoad()
            view.isUserInteractionEnabled = false
            view.isHidden = true
        }
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            hideMoreBar()
        }
        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            hideMoreBar()
        }
        private func hideMoreBar() {
            var walker: UIViewController? = self
            while let candidate = walker, !(candidate is UITabBarController) {
                walker = candidate.parent
            }
            guard let tabController = walker as? UITabBarController else { return }
            let more = tabController.moreNavigationController
            more.setNavigationBarHidden(true, animated: false)
            more.interactivePopGestureRecognizer?.isEnabled = false
        }
    }
}
#endif

/// The linear job flow. Back always pops one step; there are no dead ends:
/// cancelling processing returns to Adjust, finishing lands on the project.
struct FlowView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            switch model.stage {
            case .home:
                EmptyView()
            case .configure:
                if model.guidedBuilderFocused {
                    GuidedBuilderView()
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else {
                    AdjustView()
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            case .processing:
                ProcessingView()
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            case .done:
                ResultView()
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.88), value: model.stage)
    }
}

/// Circular chrome button used across flow screens ("‹" back, "⋯" menus).
struct FlowChromeButton: View {
    var systemImage: String
    var tint: Color = LL.accent
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(LL.cardBackground, in: Circle())
                .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
    }
}

/// Shared header for flow screens: back chevron + centered title.
struct FlowHeader<Trailing: View>: View {
    var title: String
    var onBack: (() -> Void)?
    /// Pins the title to the bar's true centre instead of the space left over
    /// between the controls. For screens whose trailing control is a label
    /// rather than a control the title should make room for — the guided
    /// builder's EXPERIMENTAL capsule, which was shunting the title left.
    var centersTitle = false
    var trailing: Trailing

    init(
        title: String,
        onBack: (() -> Void)? = nil,
        centersTitle: Bool = false,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.onBack = onBack
        self.centersTitle = centersTitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 8) {
            if let onBack {
                FlowChromeButton(systemImage: "chevron.left", action: onBack)
                    .accessibilityLabel("Back")
            } else {
                Color.clear.frame(width: 34, height: 34)
            }
            if centersTitle {
                Spacer(minLength: 0)
            } else {
                // The 34pt floor keeps the title optically centred when there
                // is no trailing control; a wider control (the Adjust screen's
                // canvas menu) nudges it like any nav bar would.
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            trailing
                .frame(minWidth: 34, minHeight: 34, alignment: .trailing)
        }
        .overlay {
            if centersTitle {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }
}

extension FlowHeader where Trailing == EmptyView {
    init(title: String, onBack: (() -> Void)? = nil, centersTitle: Bool = false) {
        self.init(
            title: title, onBack: onBack, centersTitle: centersTitle,
            trailing: { EmptyView() })
    }
}

/// Whether the Create tab opens the camera as its front surface — at launch,
/// on switching to the tab, and on reselecting it. Settings ▸ Recording.
///
/// The default states the two devices' postures: an iPhone is a camera that
/// edits, an iPad is an editor that can shoot — the Mac's posture, which has
/// never auto-opened anything. Read via `object(forKey:)` so the per-idiom
/// default holds until the human actually touches the toggle.
enum CreateCameraSetting {
    static let key = "letslapse.create.opensCamera"

    static var defaultValue: Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .phone
        #else
        return false
        #endif
    }

    static var opensCamera: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? defaultValue
    }
}


/// The library banner: one component, three stories. W7's — the manifest
/// could not be decoded, it was set aside, nothing is being saved (named
/// the file, because the file is the only copy of every edit); Phase 4's —
/// the manifest was rebuilt from the project folders and the set-aside file
/// is kept until the person has checked; and the lock's — another instance
/// has the library open and this one is read-only.
/// (SVG mirror owed after sign-off — docs/design/README.md.)
struct LibraryNoticeBanner: View {
    var title: String
    var detail: String

    init(failure: AppModel.LibraryLoadFailure) {
        if let rebuilt = failure.rebuiltFromDocuments {
            title = "Library rebuilt from \(rebuilt) project folders"
            detail = "\(failure.reason) The manifest was set aside as \(failure.setAsideName) in the Projects folder and the library was rebuilt from each project's own record\(failure.collectionsRecovered ? "" : " — the collections could not be recovered"). Check that nothing is missing before deleting the set-aside file."
        } else {
            title = "Library not loaded — nothing is being saved"
            detail = "\(failure.reason) The manifest was set aside as \(failure.setAsideName) in the Projects folder; every grade, tag and blend record is still in it. Quit, repair or restore it, and relaunch."
        }
    }

    init(readOnly: AppModel.LibraryReadOnly) {
        title = "Library open read-only"
        detail = "Another LetsLapse (pid \(readOnly.holder.pid), version \(readOnly.holder.build)) has this library open, so nothing done here will be saved. Quit the other copy and relaunch this one to edit."
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(LL.amber)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(LL.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(LL.amber.opacity(0.6), lineWidth: 1))
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
    }
}
