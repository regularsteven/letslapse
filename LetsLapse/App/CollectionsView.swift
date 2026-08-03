import SwiftUI

/// Collections tab — a collection strings blended clips from across projects
/// into one timeline and exports as a single video.
///
/// Zero collections shows an empty-state card whose CTA and the header's "+"
/// are the same action: the name sheet. With collections, one card each —
/// name, clip count · total length · canvas, last-export line, and a
/// three-thumb strip in the project-card thumbnail language.
struct CollectionsView: View {
    @EnvironmentObject var model: AppModel
    /// Owned by ContentView so the tab bar can pop this stack to the list.
    @Binding var path: [UUID]

    @State private var showNameSheet = false
    @State private var toast: String?
    @State private var collectionPendingDelete: LapseCollection?

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header

                    if model.collections.isEmpty {
                        emptyState
                    } else {
                        ForEach(model.collections) { collection in
                            collectionCard(collection)
                                .swipeToDelete(cornerRadius: 18) {
                                    collectionPendingDelete = collection
                                }
                        }
                    }

                    Spacer(minLength: 96)
                }
                .padding(.horizontal, 16)
            }
            .background(LL.screenBackground)
            #if os(iOS)
            // The tab draws its own 34pt title; the hidden bar still lends
            // its title to pushed screens' back buttons ("‹ Collections").
            .toolbar(.hidden, for: .navigationBar)
            #endif
            .navigationTitle("Collections")
            .navigationDestination(for: UUID.self) { collectionID in
                CollectionDetailView(collectionID: collectionID)
            }
        }
        .sheet(isPresented: $showNameSheet) {
            CollectionNameSheet { name in
                let collection = model.createCollection(named: name)
                path.append(collection.id)
            }
        }
        // The same warning the detail screen's ⋯ menu gives — a swipe reaches
        // the identical delete, confirmation included.
        .alert(item: $collectionPendingDelete) { collection in
            Alert(
                title: Text("Delete “\(collection.name)”?"),
                message: Text("The clips themselves stay in their projects — only the collection and its kept export are deleted."),
                primaryButton: .destructive(Text("Delete")) {
                    model.deleteCollection(collection.id)
                },
                secondaryButton: .cancel()
            )
        }
        .llToast($toast)
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            Text("Collections")
                .font(.system(size: 34, weight: .bold))
            Spacer()
            Button {
                showNameSheet = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(LL.accent)
                    .frame(width: 34, height: 34)
                    .background(LL.accent.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New collection")
            .padding(.bottom, 2)
        }
        .padding(.horizontal, 4)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            Image(systemName: "film.stack")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No collections yet")
                .font(.system(size: 17, weight: .semibold))
                .padding(.top, 18)
            Text("A collection strings blended clips from your projects into one timeline, and exports as a single video.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.top, 6)
            Button {
                showNameSheet = true
            } label: {
                Text("New collection")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 13)
                    .background(LL.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.top, 22)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.top, 44)
        .padding(.bottom, 32)
        .llCard(cornerRadius: 18)
        .padding(.top, 12)
    }

    private func collectionCard(_ collection: LapseCollection) -> some View {
        Button {
            path.append(collection.id)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(collection.name)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                Text(metaLine(for: collection))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LL.accent)
                    .padding(.top, 3)
                Text(exportLine(for: collection))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)

                if !collection.entries.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(collection.entries.prefix(3)) { entry in
                            CollectionClipThumb(blendID: entry.blendID)
                        }
                    }
                    .padding(.top, 10)
                }
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .llCard(cornerRadius: 18)
    }

    /// "3 clips · 0:09 · 16:9"
    private func metaLine(for collection: LapseCollection) -> String {
        var parts = [collection.clipCountLabel, CollectionMath.timecode(model.collectionSeconds(collection))]
        if let ratio = collection.ratio {
            parts.append(ratio.rawValue)
        }
        return parts.joined(separator: " · ")
    }

    private func exportLine(for collection: LapseCollection) -> String {
        guard let last = collection.lastExport else { return "Not exported yet" }
        return "Exported \(last.exportedAt.formatted(.relative(presentation: .named))) · kept"
    }
}

// MARK: - Clip thumb

/// The 96×54 thumbnail-with-pill tile shared by collection cards and the
/// clip picker — the Projects cards' thumbnail language.
struct CollectionClipThumb: View {
    @EnvironmentObject var model: AppModel
    var blendID: UUID

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ProjectThumbnailView(
                url: model.blendMediaURL(for: blendID),
                kind: blend.map { model.mediaKind(for: $0) } ?? .video
            )
            .frame(width: 96, height: 54)

            if let blend {
                Text(blend.speedLabel)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(LL.amber)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.5), in: Capsule())
                    .padding(4)
            }
        }
    }

    private var blend: AppModel.BlendProject? {
        model.blends.first { $0.id == blendID }
    }
}

// MARK: - Name sheet

/// Naming at creation, pre-filled with the suggested default. Rename later
/// lives in ⋯ on the collection.
struct CollectionNameSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var onCreate: (String) -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Text("New collection")
                .font(.system(size: 17, weight: .semibold))
                .padding(.top, 26)

            TextField("Collection name", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .padding(14)
                .background(LL.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.05), radius: 1.5, y: 1)
                .focused($focused)
                .submitLabel(.done)
                .onSubmit(create)
                .padding(.top, 18)

            Text("You can rename it later from ⋯ on the collection.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .padding(.top, 8)

            HStack(spacing: 10) {
                Button("Cancel") { dismiss() }
                    .buttonStyle(LLSecondaryButtonStyle(tint: .secondary))
                Button("Create", action: create)
                    .buttonStyle(LLPrimaryButtonStyle())
            }
            .padding(.top, 18)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .background(LL.screenBackground)
        .onAppear {
            draft = model.suggestedCollectionName
            focused = true
        }
        #if os(iOS)
        .presentationDetents([.height(290)])
        .presentationDragIndicator(.visible)
        #else
        .frame(minWidth: 360, minHeight: 240)
        #endif
    }

    private func create() {
        dismiss()
        onCreate(draft)
    }
}

// MARK: - Toast

/// The transient confirmation capsule the collection screens use ("Added to
/// City set", "Collection retimed — now 0:08"). Auto-dismisses; setting a new
/// message restarts the clock.
struct LLToastModifier: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let message {
                Text(message)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(LL.ink.opacity(0.95), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .frame(maxWidth: 350)
                    .padding(.bottom, 96)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .id(message)
                    .task(id: message) {
                        try? await Task.sleep(nanoseconds: 2_600_000_000)
                        if self.message == message { self.message = nil }
                    }
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.25), value: message)
    }
}

extension View {
    func llToast(_ message: Binding<String?>) -> some View {
        modifier(LLToastModifier(message: message))
    }
}
