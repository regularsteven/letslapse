import SwiftUI

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
                model.openArchive(at: url)
            }
            #if os(macOS)
            // The warm half of the same door, and the earliest point a file
            // that launched the app can be acted on: the model exists from
            // here, so anything the delegate caught before now is released.
            .onAppear {
                LetsLapseAppDelegate.handler = { model.openArchive(at: $0) }
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
        .commands { CameraCommands() }
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

        // The grading viewer opens as its own window on the Mac — macOS sheets
        // are fixed-size, and an editor wants free resizing and full screen.
        // One window per photo: reopening the same photo fronts its window.
        WindowGroup(for: PhotoEditorWindowRequest.self) { $request in
            if let request {
                PhotoViewerView(captureID: request.captureID, url: request.url)
                .environmentObject(model)
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
                .navigationTitle(request.title)
                .frame(minWidth: 720, minHeight: 480)
            }
        }
        .defaultSize(width: 1000, height: 700)
        #endif
    }
}

/// Five tabs — Create, Gallery, Projects, Collections, Settings — with the
/// blended-clip flow (Adjust → Processing → Result) laid over them whenever a
/// job is active. Collections is a placeholder while its UX is designed; it
/// took the parked Music spike's slot (MusicView stays in the codebase).
struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var selectedTab: LLTab = .create
    @State private var galleryPath: [UUID] = []
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
    #if os(macOS)
    #if DEBUG
    /// Used only by `applyUIPreviewHooks` to front the remote window for a
    /// screenshot run — the remote is otherwise behind ⌘⇧R, which no headless
    /// verification can press.
    @Environment(\.openWindow) private var openWindow
    #endif
    @State private var lastStage: AppModel.Stage = .home
    #endif

    var body: some View {
        ZStack {
            tabs

            // On iOS the flow is a full-screen overlay and the tab bar steps
            // aside. On macOS the flow lives inside the Create tab instead
            // (see `tabs`), so the native tab bar stays visible and clickable
            // throughout — switching away parks the flow, switching back
            // resumes it.
            #if os(iOS)
            if model.stage == .home {
                VStack {
                    Spacer()
                    FloatingTabBar(selection: $selectedTab, onReselect: handleReselect)
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
        }
        .onChange(of: model.requestedProjectDetailID) { requested in
            guard requested != nil else { return }
            selectedTab = .projects
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
        .onChange(of: model.progress) { _ in publishFlowContext() }
        .onChange(of: model.processingETADate) { _ in publishFlowContext() }
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
                selectedTab = .create
            }
            lastStage = newStage
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
    private func openCameraForCreateTab() {
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
            lastCaptureAt: model.captures.first?.createdAt
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
        let hookKeys = ["LL_TAB", "LL_OPEN", "LL_SEED", "LL_DETAIL", "LL_PUSH", "LL_CAPTURE", "LL_AUTO", "LL_COLLECTIONS", "LL_ADJUST", "LL_REFRAME", "LL_GUIDED", "LL_PROBE_FORMATS", "LL_SECTIONS", "LL_VIEWER", "LL_PROJECT_SCANNER"]
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
        #endif
        switch environment["LL_TAB"] {
        case "projects": selectedTab = .projects
        case "gallery": selectedTab = .gallery
        case "settings": selectedTab = .settings
        case "create": selectedTab = .create
        case "collections": selectedTab = .collections
        default: break
        }
        if environment["LL_OPEN"] == "latest", let capture = model.captures.first {
            model.openCapture(capture)
        } else if let seed = environment["LL_SEED"] {
            model.setSource(.video(URL(fileURLWithPath: seed)))
        }
        if environment["LL_DETAIL"] == "latest", let capture = model.captures.first {
            selectedTab = .projects
            model.requestedProjectDetailID = capture.id
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if model.stage == .configure {
                    model.startProcessing()
                }
            }
        }
        // LL_ADJUST=latest|demo — open the newest video capture on the Adjust
        // screen; `demo` wraps it in a fabricated two-moment sequence (the
        // design's 8:16 sample) so the warp timeline shows structure without
        // needing a real burst shoot on the simulator. LL_STRETCH
        // ("1=0.25,3=15") then pins warp stretch speeds (×-real-time) for
        // variant screenshots.
        if let hook = environment["LL_ADJUST"] {
            if hook == "demo" {
                model.debugOpenAdjustDemo()
            } else if let capture = model.captures.first(where: { $0.kind == .video }) {
                model.openCapture(capture)
            }
            if let overrides = environment["LL_STRETCH"] {
                model.debugApplyStretchOverrides(overrides)
            }
            // LL_CANVAS=9:16 — pin the Adjust canvas for variant screenshots.
            if let ratio = environment["LL_CANVAS"].flatMap(CanvasRatio.init(rawValue:)) {
                model.blendCanvasRatio = ratio
            }
        }
        // LL_REFRAME=latest — open the newest video capture in the blended-
        // clip flow with the reframe lane expanded, exactly what the
        // project's "Punch-in reframe" button (which simctl can't tap) does.
        // LL_REFRAME_RATIO=9:16 pins the canvas for variant screenshots.
        if environment["LL_REFRAME"] == "latest",
           let capture = model.captures.first(where: { $0.kind == .video }) {
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
           let capture = model.captures.first(where: { $0.kind == .video }) {
            model.openCapture(capture)
            model.guidedBuilderFocused = true
            if let ratio = environment["LL_CANVAS"].flatMap(CanvasRatio.init(rawValue:)) {
                model.blendCanvasRatio = ratio
            }
        }
        // LL_COLLECTIONS=seed|list|detail — bring the tab front; seed demo
        // collections from existing video blends (no-op without any); detail
        // additionally opens the first collection's timeline.
        if let hook = environment["LL_COLLECTIONS"] {
            selectedTab = .collections
            if hook == "seed" || hook == "list" || hook == "detail" {
                model.debugSeedCollections()
            }
            if hook == "detail", let first = model.collections.first {
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
                    GalleryView(path: $galleryPath)
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
            .tabItem { Label(LLTab.create.title, systemImage: LLTab.create.systemImage) }
            .tag(LLTab.create)

            GalleryView(path: $galleryPath)
                .hiddenSystemTabBar()
                .tabItem { Label(LLTab.gallery.title, systemImage: LLTab.gallery.systemImage) }
                .tag(LLTab.gallery)

            ProjectsView(path: $projectsPath)
                .hiddenSystemTabBar()
                .tabItem { Label(LLTab.projects.title, systemImage: LLTab.projects.systemImage) }
                .tag(LLTab.projects)

            CollectionsView(path: $collectionsPath)
                .hiddenSystemTabBar()
                .tabItem { Label(LLTab.collections.title, systemImage: LLTab.collections.systemImage) }
                .tag(LLTab.collections)

            NavigationStack(path: $settingsPath) {
                SettingsView()
                    .hiddenSystemTabBar()
            }
            .tabItem { Label(LLTab.settings.title, systemImage: LLTab.settings.systemImage) }
            .tag(LLTab.settings)
        }
    }
    #endif

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
                model.reset()
            } else {
                #if os(iOS)
                openCameraForCreateTab()
                #endif
            }
        case .gallery:
            galleryPath = []
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
}

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
