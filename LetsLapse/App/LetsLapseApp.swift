import SwiftUI

@main
struct LetsLapseApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                #if os(iOS)
                .onAppear {
                    WatchRemoteControlReceiver.shared.activate()
                }
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 760, height: 680)
        #endif
    }
}

/// Three tabs — Create, Projects, Settings — with the version flow
/// (Adjust → Processing → Result) laid over them whenever a job is active.
struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var selectedTab: LLTab = .create

    var body: some View {
        ZStack {
            tabs

            #if os(iOS)
            if model.stage == .home {
                VStack {
                    Spacer()
                    FloatingTabBar(selection: $selectedTab)
                        .padding(.bottom, 6)
                }
                .transition(.opacity)
            }
            #endif

            if model.stage != .home {
                FlowView()
                    .background(LL.screenBackground.ignoresSafeArea())
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(1)
            }
        }
        .animation(.spring(response: 0.36, dampingFraction: 0.86), value: model.stage)
        .onChange(of: model.requestedProjectDetailID) { requested in
            guard requested != nil else { return }
            selectedTab = .projects
        }
        .tint(LL.accent)
        #if DEBUG
        .onAppear(perform: applyUIPreviewHooks)
        #endif
    }

    #if DEBUG
    /// Drive the app into a specific screen from `simctl launch` env vars,
    /// so screens can be screenshot-verified without tap automation.
    private func applyUIPreviewHooks() {
        let environment = ProcessInfo.processInfo.environment
        switch environment["LL_TAB"] {
        case "projects": selectedTab = .projects
        case "settings": selectedTab = .settings
        case "create": selectedTab = .create
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

    private var tabs: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                CreateView()
                    .hiddenSystemTabBar()
            }
            .tabItem { Label(LLTab.create.title, systemImage: LLTab.create.systemImage) }
            .tag(LLTab.create)

            ProjectsView()
                .hiddenSystemTabBar()
                .tabItem { Label(LLTab.projects.title, systemImage: LLTab.projects.systemImage) }
                .tag(LLTab.projects)

            NavigationStack {
                SettingsView()
                    .hiddenSystemTabBar()
            }
            .tabItem { Label(LLTab.settings.title, systemImage: LLTab.settings.systemImage) }
            .tag(LLTab.settings)
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
