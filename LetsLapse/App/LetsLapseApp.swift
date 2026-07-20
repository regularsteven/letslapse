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
        case blends
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
                BlendsView {
                    selectedTab = .job
                }
            }
            .tabItem {
                Label("Blends", systemImage: "square.stack.3d.up")
            }
            .tag(AppTab.blends)

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
    @State private var displayMode: ProjectBrowserDisplayMode = .list
    @State private var expandedCaptureIDs: Set<UUID> = []
    @State private var previewItem: MediaPreviewItem?

    var body: some View {
        ScrollView {
            if model.captures.isEmpty {
                ProjectEmptyState(title: "No captures yet", systemImage: "rectangle.stack")
            } else {
                ProjectBrowserView(
                    items: model.captures,
                    displayMode: displayMode,
                    title: { $0.originalName },
                    subtitle: { $0.summary },
                    metadata: { $0.createdAt.formatted(date: .abbreviated, time: .shortened) },
                    mediaURL: { model.mediaURL(for: $0) },
                    mediaKind: { model.mediaKind(for: $0) }
                ) { capture in
                    CaptureProjectActions(
                        canPreview: model.mediaURL(for: capture) != nil,
                        blendCount: model.blends(for: capture).count,
                        isExpanded: expandedCaptureIDs.contains(capture.id),
                        onPreview: {
                            previewItem = previewItem(for: capture)
                        },
                        onOpen: {
                            model.openCapture(capture)
                            onOpenJob()
                        },
                        onToggleExpanded: {
                            toggleExpanded(capture)
                        }
                    )
                } expandedContent: { capture in
                    if expandedCaptureIDs.contains(capture.id) {
                        CaptureBlendGroup(
                            capture: capture,
                            blends: model.blends(for: capture),
                            previewItem: $previewItem,
                            onOpenJob: onOpenJob
                        )
                        .environmentObject(model)
                    }
                }
                .padding()
            }
        }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ProjectBrowserModePicker(selection: $displayMode)
            }
        }
        .sheet(item: $previewItem) { item in
            ProjectMediaPreviewSheet(item: item)
        }
    }

    private func toggleExpanded(_ capture: AppModel.CaptureProject) {
        if expandedCaptureIDs.contains(capture.id) {
            expandedCaptureIDs.remove(capture.id)
        } else {
            expandedCaptureIDs.insert(capture.id)
        }
    }

    private func previewItem(for capture: AppModel.CaptureProject) -> MediaPreviewItem? {
        guard let url = model.mediaURL(for: capture) else { return nil }
        return MediaPreviewItem(
            title: capture.originalName,
            subtitle: capture.summary,
            url: url,
            kind: model.mediaKind(for: capture)
        )
    }
}

struct BlendsView: View {
    @EnvironmentObject var model: AppModel
    var onOpenJob: () -> Void
    @State private var displayMode: ProjectBrowserDisplayMode = .list
    @State private var previewItem: MediaPreviewItem?

    var body: some View {
        ScrollView {
            if model.blends.isEmpty {
                ProjectEmptyState(title: "No blends yet", systemImage: "square.stack.3d.up")
            } else {
                ProjectBrowserView(
                    items: model.blends,
                    displayMode: displayMode,
                    title: { $0.parameterSummary },
                    subtitle: { $0.summary },
                    metadata: { blend in
                        if let capture = model.capture(for: blend) {
                            return "\(capture.originalName) · \(blend.createdAt.formatted(date: .abbreviated, time: .shortened))"
                        }
                        return blend.createdAt.formatted(date: .abbreviated, time: .shortened)
                    },
                    mediaURL: { model.mediaURL(for: $0) },
                    mediaKind: { model.mediaKind(for: $0) }
                ) { blend in
                    BlendProjectActions(
                        onPreview: {
                            previewItem = previewItem(for: blend)
                        },
                        onOpen: {
                            model.openBlend(blend)
                            onOpenJob()
                        },
                        onAdjust: {
                            model.openBlend(blend)
                            model.stage = .configure
                            onOpenJob()
                        }
                    )
                } expandedContent: { _ in
                    EmptyView()
                }
                .padding()
            }
        }
        .navigationTitle("Blends")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ProjectBrowserModePicker(selection: $displayMode)
            }
        }
        .sheet(item: $previewItem) { item in
            ProjectMediaPreviewSheet(item: item)
        }
    }

    private func previewItem(for blend: AppModel.BlendProject) -> MediaPreviewItem {
        MediaPreviewItem(
            title: blend.parameterSummary,
            subtitle: model.capture(for: blend)?.originalName ?? blend.summary,
            url: model.mediaURL(for: blend),
            kind: model.mediaKind(for: blend)
        )
    }
}

private struct CaptureProjectActions: View {
    var canPreview: Bool
    var blendCount: Int
    var isExpanded: Bool
    var onPreview: () -> Void
    var onOpen: () -> Void
    var onToggleExpanded: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                buttons
            }
            VStack(alignment: .leading, spacing: 8) {
                buttons
            }
        }
        .buttonStyle(.bordered)
    }

    @ViewBuilder
    private var buttons: some View {
        Button(action: onPreview) {
            Label("Preview", systemImage: "play.rectangle")
        }
        .disabled(!canPreview)

        Button(action: onOpen) {
            Label("Blend", systemImage: "slider.horizontal.3")
        }

        if blendCount > 0 {
            Button(action: onToggleExpanded) {
                Label(
                    "\(blendCount)",
                    systemImage: isExpanded ? "chevron.up.circle" : "chevron.down.circle"
                )
            }
        }
    }
}

private struct BlendProjectActions: View {
    var onPreview: () -> Void
    var onOpen: () -> Void
    var onAdjust: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                buttons
            }
            VStack(alignment: .leading, spacing: 8) {
                buttons
            }
        }
        .buttonStyle(.bordered)
    }

    @ViewBuilder
    private var buttons: some View {
        Button(action: onPreview) {
            Label("Preview", systemImage: "play.rectangle")
        }
        Button(action: onOpen) {
            Label("Open", systemImage: "arrow.up.forward.app")
        }
        Button(action: onAdjust) {
            Label("Adjust", systemImage: "slider.horizontal.3")
        }
    }
}

private struct CaptureBlendGroup: View {
    @EnvironmentObject var model: AppModel
    var capture: AppModel.CaptureProject
    var blends: [AppModel.BlendProject]
    @Binding var previewItem: MediaPreviewItem?
    var onOpenJob: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()

            HStack(spacing: 10) {
                ProjectThumbnailView(url: model.mediaURL(for: capture), kind: model.mediaKind(for: capture))
                    .frame(width: 56, height: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Original")
                        .font(.subheadline.weight(.semibold))
                    Text(capture.summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    if let url = model.mediaURL(for: capture) {
                        previewItem = MediaPreviewItem(
                            title: capture.originalName,
                            subtitle: capture.summary,
                            url: url,
                            kind: model.mediaKind(for: capture)
                        )
                    }
                } label: {
                    Image(systemName: "play.rectangle")
                }
                .disabled(model.mediaURL(for: capture) == nil)
            }

            ForEach(blends) { blend in
                HStack(spacing: 10) {
                    ProjectThumbnailView(url: model.mediaURL(for: blend), kind: model.mediaKind(for: blend))
                        .frame(width: 56, height: 42)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(blend.parameterSummary)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(blend.summary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button {
                        previewItem = MediaPreviewItem(
                            title: blend.parameterSummary,
                            subtitle: blend.summary,
                            url: model.mediaURL(for: blend),
                            kind: model.mediaKind(for: blend)
                        )
                    } label: {
                        Image(systemName: "play.rectangle")
                    }
                    Button {
                        model.openBlend(blend)
                        onOpenJob()
                    } label: {
                        Image(systemName: "arrow.up.forward.app")
                    }
                }
            }
        }
        .buttonStyle(.bordered)
    }
}

private struct ProjectEmptyState: View {
    var title: String
    var systemImage: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
        .padding()
    }
}

struct CaptureProjectDetailView: View {
    @EnvironmentObject var model: AppModel
    let captureID: UUID
    var onOpenJob: () -> Void
    @State private var previewItem: MediaPreviewItem?

    private var capture: AppModel.CaptureProject? {
        model.captures.first { $0.id == captureID }
    }

    var body: some View {
        List {
            if let capture {
                Section("Source") {
                    HStack(spacing: 12) {
                        ProjectThumbnailView(url: model.mediaURL(for: capture), kind: model.mediaKind(for: capture))
                            .frame(width: 90, height: 68)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(capture.originalName)
                                .font(.headline)
                            Text(capture.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("Type", value: capture.kind.label)
                    LabeledContent("Captured", value: capture.createdAt.formatted(date: .abbreviated, time: .shortened))

                    Button {
                        if let url = model.mediaURL(for: capture) {
                            previewItem = MediaPreviewItem(
                                title: capture.originalName,
                                subtitle: capture.summary,
                                url: url,
                                kind: model.mediaKind(for: capture)
                            )
                        }
                    } label: {
                        Label("Preview Original", systemImage: "play.rectangle")
                    }
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
                            HStack(spacing: 12) {
                                ProjectThumbnailView(url: model.mediaURL(for: blend), kind: model.mediaKind(for: blend))
                                    .frame(width: 72, height: 54)
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(blend.parameterSummary)
                                        .font(.headline)
                                    Text(blend.summary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    HStack {
                                        Button {
                                            previewItem = MediaPreviewItem(
                                                title: blend.parameterSummary,
                                                subtitle: blend.summary,
                                                url: model.mediaURL(for: blend),
                                                kind: model.mediaKind(for: blend)
                                            )
                                        } label: {
                                            Label("Preview", systemImage: "play.rectangle")
                                        }
                                        Button {
                                            model.openBlend(blend)
                                            onOpenJob()
                                        } label: {
                                            Label("Open", systemImage: "arrow.up.forward.app")
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
        .sheet(item: $previewItem) { item in
            ProjectMediaPreviewSheet(item: item)
        }
    }
}
