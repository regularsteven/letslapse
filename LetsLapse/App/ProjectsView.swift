import SwiftUI

/// One card per original, versions always visible as a thumbnail strip —
/// Library and Blends unified, with no expand/collapse state at all.
/// A List (restyled to match the ScrollView look) so cards get native
/// swipe-to-delete.
struct ProjectsView: View {
    @EnvironmentObject var model: AppModel
    /// Owned by ContentView so the tab bar can pop this stack to the list.
    @Binding var path: [UUID]
    @State private var previewItem: MediaPreviewItem?
    @State private var deleteFailure: String?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Group {
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
                                onPreview: { preview(capture) },
                                onDelete: { delete(capture) }
                            )
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    delete(capture)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }

                    // Clearance for the floating tab bar.
                    Color.clear.frame(height: 82)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(LL.screenBackground)
            .alert(
                "Couldn't delete",
                isPresented: Binding(get: { deleteFailure != nil }, set: { if !$0 { deleteFailure = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(deleteFailure ?? "")
            }
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
        .onAppear { consumeDetailRequest(model.requestedProjectDetailID) }
        .onReceive(model.$requestedProjectDetailID) { requested in
            consumeDetailRequest(requested)
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
        // A Photo-mode capture previews as its one photo, not a burst frame.
        let url = capture.isPhotoCapture
            ? model.heroImageURL(for: capture)
            : model.mediaURL(for: capture)
        guard let url else { return }
        previewItem = MediaPreviewItem(
            title: capture.displayTitle,
            subtitle: capture.formatLine,
            url: url,
            kind: model.mediaKind(for: capture)
        )
    }

    /// `requested` must arrive as a parameter: @Published emits on willSet, so
    /// during the emission the model property still holds the OLD value — the
    /// previous re-read here made a live ProjectsView drop every request (the
    /// macOS "clicking a project in Settings does nothing" bug; iOS was saved
    /// only by onAppear re-firing on tab switches).
    private func consumeDetailRequest(_ requested: UUID?) {
        guard let requested else { return }
        guard model.captures.contains(where: { $0.id == requested }) else { return }
        path = [requested]
        // Clear once the emission has settled; writing back during it would
        // re-enter the publisher mid-publish.
        DispatchQueue.main.async {
            if model.requestedProjectDetailID == requested {
                model.requestedProjectDetailID = nil
            }
        }
    }

    /// Deliberately unconfirmed: swiping is the confirmation. Failures
    /// (e.g. the project is mid-processing) surface in an alert.
    private func delete(_ capture: AppModel.CaptureProject) {
        do {
            try withAnimation {
                try model.deleteCapture(capture)
            }
        } catch {
            deleteFailure = error.localizedDescription
        }
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
    var onDelete: () -> Void

    @State private var projectBytes: Int64?

    var body: some View {
        let versions = model.blends(for: capture)

        VStack(alignment: .leading, spacing: 0) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    ZStack(alignment: .bottomTrailing) {
                        ProjectThumbnailView(url: thumbnailURL, kind: model.mediaKind(for: capture))
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
                            .foregroundStyle(
                                versions.isEmpty || capture.isPhotoCapture
                                    ? Color.secondary : LL.accent)
                            .padding(.top, 2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // A photo is one asset — no version strip, nothing to add.
            if !capture.isPhotoCapture {
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
        }
        .llCard(cornerRadius: 18)
        .contextMenu {
            Button {
                onPreview()
            } label: {
                Label(capture.isPhotoCapture ? "View photo" : "Play original",
                      systemImage: capture.isPhotoCapture ? "photo" : "play.rectangle")
            }
            if !capture.isPhotoCapture {
                Button {
                    onNewVersion()
                } label: {
                    Label("New version", systemImage: "plus")
                }
            }
            Button {
                onOpen()
            } label: {
                Label("Project details", systemImage: "info.circle")
            }
            Divider()
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete project", systemImage: "trash")
            }
        }
        .task(id: versions.count) {
            projectBytes = await model.storageBytes(for: capture)
        }
    }

    /// A photo project's tile is the photo itself; everything else shows its
    /// source media.
    private var thumbnailURL: URL? {
        capture.isPhotoCapture ? model.heroImageURL(for: capture) : model.mediaURL(for: capture)
    }

    private var durationBadge: String {
        if capture.isPhotoCapture {
            return "Photo"
        }
        if capture.kind == .photos {
            return "\(capture.sourceMediaCount) photos"
        }
        if let duration = capture.sourceDurationSeconds {
            return DurationFormatter.recordingTime(from: duration)
        }
        return "Video"
    }

    private func versionsLine(count: Int) -> String {
        let size = projectBytes.map(LLFormat.bytes)
        // A photo capture is a single asset: size only, never a version count.
        if capture.isPhotoCapture {
            return size ?? "…"
        }
        switch count {
        case 0: return size ?? "…"
        case 1: return size.map { "1 version · \($0)" } ?? "1 version"
        default: return size.map { "\(count) versions · \($0)" } ?? "\(count) versions"
        }
    }
}
