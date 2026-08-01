import SwiftUI

@main
struct LetsLapseApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if os(iOS)
        // Activate in init, not view onAppear: when the Watch messages a
        // not-running phone app, iOS launches it in the background to deliver —
        // no UI is built there, so an onAppear-tied activation never runs and
        // the Watch's message dies with a timeout.
        WatchRemoteControlReceiver.shared.activate()
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

/// Five tabs — Create, Gallery, Projects, Music, Settings — with the version
/// flow (Adjust → Processing → Result) laid over them whenever a job is active.
/// Music is an experimental spike and isn't wired to project data yet.
struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var selectedTab: LLTab = .create
    @State private var galleryPath: [UUID] = []
    @State private var projectsPath: [UUID] = []
    @State private var settingsPath: [SettingsDestination] = []
    /// Owns the camera presentation so that selecting the Create tab can open
    /// the camera straight away, over the Create screen (the tab's home).
    @State private var showCamera = false
    @State private var cameraIntent = CaptureIntent()
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
            // A flow can start from any tab (e.g. "New version" in Projects);
            // bring the Create tab front so the flow is on screen.
            if newStage != .home, lastStage == .home {
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
        let hookKeys = ["LL_TAB", "LL_OPEN", "LL_SEED", "LL_DETAIL", "LL_PUSH", "LL_CAPTURE", "LL_AUTO"]
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
        case "music": selectedTab = .music
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
                case .music:
                    MusicView()
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

            MusicView()
                .hiddenSystemTabBar()
                .tabItem { Label(LLTab.music.title, systemImage: LLTab.music.systemImage) }
                .tag(LLTab.music)

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
        case .music:
            // A single screen with no stack — nothing to pop, and a reselect
            // deliberately doesn't stop playback.
            break
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
struct FlowHeader: View {
    var title: String
    var onBack: (() -> Void)?

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
            Color.clear.frame(width: 34, height: 34)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }
}
