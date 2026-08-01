import SwiftUI

/// The "Add clips" sheet: every blended clip in the library, two shapes —
/// By project (sections with horizontal reels) or All clips (one flat grid).
///
/// A clip already in this collection shows ADDED and won't select — once per
/// collection, though other collections may reuse it freely. Long-exposure
/// stills are visible but locked: collections are video-only in v1.
struct CollectionClipPicker: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let collectionID: UUID
    /// The toast the detail screen shows once the sheet is down.
    var onFinish: (String?) -> Void

    private enum Mode: String, CaseIterable, Identifiable {
        case byProject = "By project"
        case allClips = "All clips"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .byProject
    /// Selection in tap order — the order the clips join the timeline.
    @State private var selection: [UUID] = []
    @State private var toast: String?

    private let disabledCTA = Color(red: 200 / 255, green: 200 / 255, blue: 205 / 255)

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                Group {
                    if mode == .byProject {
                        projectSections
                    } else {
                        flatGrid
                    }
                }
                .padding(16)
            }

            footer
        }
        .background(LL.screenBackground)
        .llToast($toast)
        #if os(iOS)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        #else
        .frame(minWidth: 480, minHeight: 520)
        #endif
    }

    private var header: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack {
                    Button("Cancel") { dismiss() }
                        .font(.system(size: 16))
                        .foregroundStyle(LL.accent)
                        .buttonStyle(.plain)
                    Spacer()
                }
                Text("Add clips")
                    .font(.system(size: 17, weight: .semibold))
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)

            Picker("Browse", selection: $mode) {
                ForEach(Mode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.top, 14)
        }
    }

    // MARK: - By project

    private var projectSections: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(sectionedCaptures, id: \.capture.id) { section in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(section.capture.displayTitle)
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                        Spacer()
                        Text(sectionMeta(section))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 2)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(section.blends) { blend in
                                tile(blend, width: 96, height: 54)
                            }
                        }
                        .padding(.bottom, 2)
                    }

                    if section.blends.contains(where: { $0.kind == .image }) {
                        Text("Long-exposure stills can’t join a collection — v1 is video-only.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 2)
                    }
                }
            }

            if sectionedCaptures.isEmpty {
                noClipsCard
            }
        }
    }

    // MARK: - All clips

    private var flatGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 12) {
            ForEach(allBlends) { blend in
                VStack(alignment: .leading, spacing: 3) {
                    tile(blend, width: nil, height: 64)
                    Text(model.capture(for: blend)?.displayTitle ?? "")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .overlay {
            if allBlends.isEmpty { noClipsCard }
        }
    }

    private var noClipsCard: some View {
        Text("No blended clips yet — make one from any project first.")
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .llCard()
    }

    // MARK: - Tiles

    @ViewBuilder
    private func tile(_ blend: AppModel.BlendProject, width: CGFloat?, height: CGFloat) -> some View {
        let added = collection?.entry(for: blend.id) != nil
        let still = blend.kind == .image
        let selected = selection.contains(blend.id) && !added

        Button {
            tap(blend, added: added, still: still)
        } label: {
            ZStack(alignment: .bottomLeading) {
                ProjectThumbnailView(url: model.mediaURL(for: blend), kind: model.mediaKind(for: blend))
                    .frame(width: width, height: height)
                    .frame(maxWidth: width == nil ? .infinity : nil)

                Text(blend.speedLabel)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(LL.amber)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.5), in: Capsule())
                    .padding(4)
            }
            .overlay(alignment: .topTrailing) {
                if added {
                    cornerBadge("ADDED", background: .green.opacity(0.9), foreground: .white)
                } else if still {
                    cornerBadge("STILL", background: .black.opacity(0.55), foreground: .white.opacity(0.8))
                } else if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(LL.ink)
                        .frame(width: 18, height: 18)
                        .background(LL.amber, in: Circle())
                        .padding(4)
                }
            }
            .opacity(added || still ? 0.45 : 1)
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(selected ? LL.amber : .clear, lineWidth: 2.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func cornerBadge(_ text: String, background: Color, foreground: Color) -> some View {
        Text(text)
            .font(.system(size: 8.5, weight: .bold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(background, in: Capsule())
            .padding(4)
    }

    private func tap(_ blend: AppModel.BlendProject, added: Bool, still: Bool) {
        if still {
            toast = "Stills can’t join a collection — v1 is video-only"
            return
        }
        if added {
            toast = "Already in \(collection?.name ?? "this collection") — one appearance per collection"
            return
        }
        if let index = selection.firstIndex(of: blend.id) {
            selection.remove(at: index)
        } else {
            selection.append(blend.id)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        Button {
            add()
        } label: {
            Text(selection.isEmpty
                 ? "Add clips"
                 : "Add \(selection.count) clip\(selection.count == 1 ? "" : "s")")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(
                    selection.isEmpty ? disabledCTA : LL.accent,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(selection.isEmpty)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 16)
    }

    private func add() {
        guard !selection.isEmpty else { return }
        let hadCanvas = collection?.ratio != nil
        let setRatio = model.addBlends(selection, to: collectionID)
        let count = selection.count
        dismiss()
        if !hadCanvas, let setRatio {
            onFinish("Canvas set to \(setRatio.rawValue) — from your first clip")
        } else {
            onFinish("Added \(count) clip\(count == 1 ? "" : "s")")
        }
    }

    // MARK: - Data

    private var collection: LapseCollection? {
        model.collection(withID: collectionID)
    }

    private struct Section {
        var capture: AppModel.CaptureProject
        var blends: [AppModel.BlendProject]
    }

    /// Interval and Video projects with at least one blended clip, newest
    /// first — Photo captures are one asset and have nothing to place.
    private var sectionedCaptures: [Section] {
        model.captures.compactMap { capture in
            guard !capture.isPhotoCapture else { return nil }
            let blends = model.blends(for: capture)
            guard !blends.isEmpty else { return nil }
            return Section(capture: capture, blends: blends)
        }
    }

    private var allBlends: [AppModel.BlendProject] {
        sectionedCaptures.flatMap(\.blends)
    }

    /// "Video · 2 blended clips" / "Interval · 1 clip + 1 still"
    private func sectionMeta(_ section: Section) -> String {
        let kind = section.capture.kind == .video ? "Video" : "Interval"
        let clips = section.blends.filter { $0.kind == .video }.count
        let stills = section.blends.filter { $0.kind == .image }.count
        if clips > 0 && stills > 0 {
            return "\(kind) · \(clips) clip\(clips == 1 ? "" : "s") + \(stills) still\(stills == 1 ? "" : "s")"
        }
        if stills > 0 {
            return "\(kind) · \(stills) still\(stills == 1 ? "" : "s")"
        }
        return "\(kind) · \(clips) blended clip\(clips == 1 ? "" : "s")"
    }
}
