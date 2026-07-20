import SwiftUI

/// One card per original, versions always visible as a thumbnail strip —
/// Library and Blends unified, with no expand/collapse state at all.
struct ProjectsView: View {
    @EnvironmentObject var model: AppModel
    /// Owned by ContentView so the tab bar can pop this stack to the list.
    @Binding var path: [UUID]
    @State private var previewItem: MediaPreviewItem?

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Projects")
                        .font(.system(size: 34, weight: .bold))
                        .padding(.horizontal, 4)
                        .padding(.top, 8)

                    if model.captures.isEmpty {
                        emptyState
                    } else {
                        ForEach(model.captures) { capture in
                            ProjectCard(
                                capture: capture,
                                onOpen: { path.append(capture.id) },
                                onNewVersion: { model.openCapture(capture) },
                                onOpenVersion: { blend in model.openBlend(blend) },
                                onPreview: { preview(capture) }
                            )
                        }
                    }

                    Spacer(minLength: 96)
                }
                .padding(.horizontal, 16)
            }
            .background(LL.screenBackground)
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #else
            .navigationTitle("Projects")
            #endif
            .navigationDestination(for: UUID.self) { captureID in
                ProjectDetailView(captureID: captureID)
            }
            .sheet(item: $previewItem) { item in
                ProjectMediaPreviewSheet(item: item)
            }
        }
        .onAppear(perform: consumeDetailRequest)
        .onReceive(model.$requestedProjectDetailID) { _ in
            consumeDetailRequest()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No projects yet")
                .font(.headline)
            Text("Record or import something in Create — every original becomes a project here, with all its versions.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
        .padding(20)
        .llCard(cornerRadius: 18)
    }

    private func preview(_ capture: AppModel.CaptureProject) {
        guard let url = model.mediaURL(for: capture) else { return }
        previewItem = MediaPreviewItem(
            title: capture.displayTitle,
            subtitle: capture.formatLine,
            url: url,
            kind: model.mediaKind(for: capture)
        )
    }

    private func consumeDetailRequest() {
        guard let requested = model.requestedProjectDetailID else { return }
        model.requestedProjectDetailID = nil
        guard model.captures.contains(where: { $0.id == requested }) else { return }
        path = [requested]
    }
}

// MARK: - Project card

private struct ProjectCard: View {
    @EnvironmentObject var model: AppModel
    var capture: AppModel.CaptureProject
    var onOpen: () -> Void
    var onNewVersion: () -> Void
    var onOpenVersion: (AppModel.BlendProject) -> Void
    var onPreview: () -> Void

    var body: some View {
        let versions = model.blends(for: capture)

        VStack(alignment: .leading, spacing: 0) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    ZStack(alignment: .bottomTrailing) {
                        ProjectThumbnailView(url: model.mediaURL(for: capture), kind: model.mediaKind(for: capture))
                            .frame(width: 86, height: 64)
                        MediaBadge(text: durationBadge)
                            .scaleEffect(0.82, anchor: .bottomTrailing)
                            .padding(4)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(capture.displayTitle)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text("\(capture.formatLine) · \(capture.createdAt.formatted(.relative(presentation: .named)))")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(versionsLine(count: versions.count))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(versions.isEmpty ? Color.secondary : LL.accent)
                            .padding(.top, 2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(versions) { blend in
                        Button {
                            onOpenVersion(blend)
                        } label: {
                            ZStack(alignment: .bottomLeading) {
                                ProjectThumbnailView(url: model.mediaURL(for: blend), kind: model.mediaKind(for: blend))
                                    .frame(width: 96, height: 54)
                                MediaBadge(text: blend.badgeLabel, tint: LL.amber)
                                    .scaleEffect(0.78, anchor: .bottomLeading)
                                    .padding(4)
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    Button(action: onNewVersion) {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(
                                Color.primary.opacity(0.18),
                                style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                            )
                            .frame(width: versions.isEmpty ? 96 : 54, height: 54)
                            .overlay {
                                Image(systemName: "plus")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundStyle(LL.accent)
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("New version")
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }
        }
        .llCard(cornerRadius: 18)
        .contextMenu {
            Button {
                onPreview()
            } label: {
                Label("Play original", systemImage: "play.rectangle")
            }
            Button {
                onNewVersion()
            } label: {
                Label("New version", systemImage: "plus")
            }
            Button {
                onOpen()
            } label: {
                Label("Project details", systemImage: "info.circle")
            }
        }
    }

    private var durationBadge: String {
        if capture.kind == .photos {
            return "\(capture.sourceMediaCount) photos"
        }
        if let duration = capture.sourceDurationSeconds {
            return DurationFormatter.recordingTime(from: duration)
        }
        return "Video"
    }

    private func versionsLine(count: Int) -> String {
        switch count {
        case 0: return "No versions yet — create one"
        case 1: return "1 version"
        default: return "\(count) versions"
        }
    }
}
