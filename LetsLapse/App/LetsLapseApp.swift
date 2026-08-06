import SwiftUI

@main
struct LetsLapseApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Self.quietenMetalShaderCompiler()

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

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                #if os(iOS)
                .onAppear {
                    WatchRemoteControlReceiver.shared.setAppActive(scenePhase != .background)
                }
                // .inactive still counts as active: Control Center or the app
                // switcher over a live camera shouldn't read as "phone away".
                .onChange(of: scenePhase) { phase in
                    WatchRemoteControlReceiver.shared.setAppActive(phase != .background)
                }
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 760, height: 680)
        #endif

        #if os(macOS)
        // The grading viewer opens as its own window on the Mac — macOS sheets
        // are fixed-size, and an editor wants free resizing and full screen.
        // One window per photo: reopening the same photo fronts its window.
        WindowGroup(for: PhotoEditorWindowRequest.self) { $request in
            if let request {
                PhotoViewerView(
                    captureID: request.captureID,
                    url: request.url,
                    title: request.title
                )
                .environmentObject(model)
                .navigationTitle(request.title)
                // Floor only. The rail is fixed at 340pt, so 720 leaves the
                // image pane a workable ~380pt at the smallest.
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
    /// The Punch-In Reframe editor, laid over whatever tab is showing. Opened
    /// from a project's "Punch-in reframe" button — and, in DEBUG, by
    /// `LL_REFRAME`.
    @State private var reframeSource: ReframeSourceRequest?
    #if os(macOS)
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
        }
        .animation(.spring(response: 0.36, dampingFraction: 0.86), value: model.stage)
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
        .onAppear(perform: openCameraOnLaunch)
        #endif
        #if os(macOS)
        .onChange(of: model.stage) { newStage in
            // A flow can start from any tab (e.g. "New blended clip" in Projects);
            // bring the Create tab front so the flow is on screen.
            if newStage != .home, lastStage == .home {
                selectedTab = .create
            }
            lastStage = newStage
        }
        #endif
        .reframeEditor(item: $reframeSource)
        .tint(LL.accent)
        #if DEBUG
        .onAppear(perform: applyUIPreviewHooks)
        #endif
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

    /// Create is the launch tab and its purpose is the camera, so present it on
    /// first appear too — but never when a DEBUG preview hook is steering the
    /// app to a specific screen for screenshots.
    private func openCameraOnLaunch() {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        let hookKeys = ["LL_TAB", "LL_OPEN", "LL_SEED", "LL_DETAIL", "LL_PUSH", "LL_CAPTURE", "LL_AUTO", "LL_COLLECTIONS", "LL_ADJUST", "LL_REFRAME"]
        if hookKeys.contains(where: { environment[$0] != nil }) { return }
        #endif
        guard selectedTab == .create else { return }
        openCameraForCreateTab()
    }
    #endif

    #if DEBUG
    /// Drive the app into a specific screen from `simctl launch` env vars,
    /// so screens can be screenshot-verified without tap automation.
    private func applyUIPreviewHooks() {
        let environment = ProcessInfo.processInfo.environment
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
        // LL_REFRAME=latest — open the newest video capture in the Punch-In
        // Reframe editor, over whichever tab is showing. The editor is
        // otherwise reached from a project's "Punch-in reframe" button, which
        // simctl can't tap. LL_REFRAME_RATIO=9:16 pins the output shape for
        // variant screenshots.
        if environment["LL_REFRAME"] == "latest",
           let capture = model.captures.first(where: { $0.kind == .video }),
           let url = model.mediaURL(for: capture) {
            let size: CGSize
            if let width = capture.sourceWidth, let height = capture.sourceHeight,
               width > 0, height > 0 {
                size = CGSize(width: width, height: height)
            } else {
                size = CGSize(width: 3840, height: 2160)
            }
            reframeSource = ReframeSourceRequest(
                url: url,
                title: capture.displayTitle,
                size: size,
                duration: capture.sourceDurationSeconds ?? 0,
                fps: capture.sourceFPS,
                ratio: environment["LL_REFRAME_RATIO"].flatMap(ReframeRatio.init(rawValue:)))
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
        // LL_TAGS=demo — stamp scene metadata across the library so the Projects
        // search field and tag chips can be verified without a 3.3 GB model.
        if environment["LL_TAGS"] == "demo" {
            model.debugSeedSceneTags()
        }
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

            FloatingTabBar(selection: $selectedTab, onReselect: handleReselect)
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
                AdjustView()
                    .transition(.move(edge: .trailing).combined(with: .opacity))
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
    var trailing: Trailing

    init(title: String, onBack: (() -> Void)? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.onBack = onBack
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
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity)
            // The 34pt floor keeps the title optically centred when there is
            // no trailing control; a wider control (the Adjust screen's
            // canvas menu) nudges it like any nav bar would.
            trailing
                .frame(minWidth: 34, minHeight: 34, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }
}

extension FlowHeader where Trailing == EmptyView {
    init(title: String, onBack: (() -> Void)? = nil) {
        self.init(title: title, onBack: onBack, trailing: { EmptyView() })
    }
}
