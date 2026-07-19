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

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var selectedTab: AppTab = .capture

    private enum AppTab {
        case capture
        case job
        case library
        case settings
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                HomeView {
                    selectedTab = .job
                }
            }
            .tabItem {
                Label("Capture", systemImage: "camera")
            }
            .tag(AppTab.capture)

            NavigationStack {
                switch model.stage {
                case .home:
                    JobEmptyView {
                        selectedTab = .capture
                    }
                case .configure:
                    BlendOptionsView()
                case .processing:
                    ProcessingView()
                case .done:
                    ResultView()
                }
            }
            .tabItem {
                Label("Job", systemImage: "wand.and.stars")
            }
            .tag(AppTab.job)

            NavigationStack {
                LibraryView {
                    selectedTab = .job
                }
            }
            .tabItem {
                Label("Library", systemImage: "rectangle.stack")
            }
            .tag(AppTab.library)

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
            .tag(AppTab.settings)
        }
    }
}

struct JobEmptyView: View {
    var onChooseSource: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "wand.and.stars")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No Active Job")
                .font(.headline)
            Text("Capture or import a source to start blending.")
                .foregroundStyle(.secondary)
            Button {
                onChooseSource()
            } label: {
                Label("Go to Capture", systemImage: "camera")
            }
        }
        .multilineTextAlignment(.center)
        .padding()
        .navigationTitle("Job")
    }
}

struct LibraryView: View {
    @EnvironmentObject var model: AppModel
    var onOpenJob: () -> Void

    var body: some View {
        List {
            if model.captures.isEmpty {
                Section {
                    Text("No captures yet.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Captures") {
                    ForEach(model.captures) { capture in
                        NavigationLink {
                            CaptureProjectDetailView(captureID: capture.id, onOpenJob: onOpenJob)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(capture.originalName)
                                    .font(.headline)
                                Text(capture.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(capture.createdAt, style: .date)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            if !model.blends.isEmpty {
                Section("Recent blends") {
                    ForEach(model.blends.prefix(8)) { blend in
                        Button {
                            model.openBlend(blend)
                            onOpenJob()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(blend.parameterSummary)
                                    .font(.headline)
                                Text(blend.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Library")
    }
}

struct CaptureProjectDetailView: View {
    @EnvironmentObject var model: AppModel
    let captureID: UUID
    var onOpenJob: () -> Void

    private var capture: AppModel.CaptureProject? {
        model.captures.first { $0.id == captureID }
    }

    var body: some View {
        List {
            if let capture {
                Section("Source") {
                    LabeledContent("Type", value: capture.kind.label)
                    LabeledContent("Captured", value: capture.createdAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Source", value: capture.originalName)
                    Text(capture.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button {
                        model.openCapture(capture)
                        onOpenJob()
                    } label: {
                        Label("Re-blend from Source", systemImage: "slider.horizontal.3")
                    }
                }

                Section("Blends") {
                    let captureBlends = model.blends(for: capture)
                    if captureBlends.isEmpty {
                        Text("No blends generated yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(captureBlends) { blend in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(blend.parameterSummary)
                                    .font(.headline)
                                Text(blend.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                HStack {
                                    Button {
                                        model.openBlend(blend)
                                        onOpenJob()
                                    } label: {
                                        Label("Open", systemImage: "play.rectangle")
                                    }
                                    Button {
                                        model.openBlend(blend)
                                        model.stage = .configure
                                        onOpenJob()
                                    } label: {
                                        Label("Adjust", systemImage: "slider.horizontal.3")
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            } else {
                Section {
                    Text("Capture not found.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Project")
    }
}
