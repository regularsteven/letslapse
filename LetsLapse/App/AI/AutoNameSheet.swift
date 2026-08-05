import CoreLocation
import SwiftUI

/// Drives one "Auto rename & tag" run: sample frames, gather context, generate, propose.
///
/// Nothing is written until the user confirms. The controller's whole job is to get from a tap to
/// a filled-in sheet — `Apply` is one call on `AppModel` from the view.
@MainActor
final class AutoNameController: ObservableObject {
    /// What the row shows while a run is in flight.
    @Published private(set) var status: String?
    @Published var failure: String?
    @Published var proposal: Proposal?

    var isRunning: Bool { status != nil }

    struct Proposal: Identifiable {
        let id = UUID()
        var title: String
        /// Every tag the model returned, with the ones the user has kept ticked.
        var tags: [Tag]
        let elements: [String]
        let place: String?
        let light: String?

        struct Tag: Identifiable, Equatable {
            let value: String
            var isOn: Bool
            var id: String { value }
        }

        var acceptedTags: [String] {
            tags.filter(\.isOn).map(\.value)
        }

        /// The record to store, once the user has had their say about the title and the tags.
        /// `elements` rides along untouched: they are not editable here (they describe the frame
        /// rather than classify it), but they are what makes a project findable by what is in it.
        var accepted: SceneMetadata {
            SceneMetadata(
                title: title,
                tags: acceptedTags,
                elements: elements,
                place: place,
                light: light)
        }
    }

    /// Resolved per run rather than held: the active model can change in Settings between one run
    /// and the next, and with it which engine answers.
    private let analyzer: (any SceneAnalyzing)?

    init(analyzer: (any SceneAnalyzing)? = nil) {
        self.analyzer = analyzer
    }

    /// - Parameter fallbackTitle: the name to propose when the backend writes none. Vision
    ///   classifies without describing, so its proposal starts from the project's current name and
    ///   the sheet is about the tags.
    func run(
        source: SceneFrameSampler.Source,
        capturedAt: Date,
        duration: TimeInterval,
        locationFile: URL?,
        fallbackTitle: String = ""
    ) async {
        guard !isRunning else { return }
        status = "Preparing frames…"
        failure = nil

        var sample: SceneFrameSampler.Sample?
        defer {
            if let sample { SceneFrameSampler.cleanUp(sample) }
            status = nil
        }

        do {
            let taken = try await SceneFrameSampler.sample(source)
            sample = taken

            status = "Reading capture details…"
            let light = SceneContext.light(from: capturedAt, duration: duration)
            let place = await SceneContext.place(for: Self.location(of: locationFile))

            let engine = analyzer ?? SceneAnalyzerFactory.active()
            let result = try await engine.analyze(
                SceneAnalysisRequest(imageURLs: taken.frameURLs, place: place, light: light),
                status: { line in Task { @MainActor [weak self] in self?.status = line } })

            let proposedTitle = result.title.trimmingCharacters(in: .whitespacesAndNewlines)
            proposal = Proposal(
                title: proposedTitle.isEmpty ? fallbackTitle : proposedTitle,
                tags: result.subjectTags.map { Proposal.Tag(value: $0, isOn: true) },
                elements: result.elements,
                place: place,
                light: light)
        } catch {
            failure = error.localizedDescription
        }
    }

    /// The capture's own fix, read off the file it was written into — EXIF for a still, the
    /// QuickTime location atom for a recording.
    private static func location(of url: URL?) async -> CLLocation? {
        guard let url else { return nil }
        return await Task.detached(priority: .userInitiated) {
            let isImage = ["jpg", "jpeg", "heic", "png", "dng", "tiff"]
                .contains(url.pathExtension.lowercased())
            return isImage ? CLLocation.fromEXIF(of: url) : MovieLocation.locationForSaving(at: url)
        }.value
    }
}

// MARK: - Review sheet

/// The proposal, before anything is written. The title is editable, subject tags are the model's
/// guesses and can be dropped, and the light and place chips are shown but not editable — they are
/// the capture's own facts, handed *to* the model rather than produced by it.
struct AutoNameSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// Edited locally: nothing the user does here touches the project until Apply, and Cancel is
    /// then genuinely free rather than a rollback.
    @State private var proposal: AutoNameController.Proposal
    private let onApply: (SceneMetadata) -> Void

    init(
        proposal: AutoNameController.Proposal,
        onApply: @escaping (SceneMetadata) -> Void
    ) {
        _proposal = State(initialValue: proposal)
        self.onApply = onApply
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    LLSectionHeader("Name")
                    VStack(spacing: 0) {
                        TextField("Project name", text: $proposal.title)
                            .font(.system(size: 17))
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                    }
                    .llCard()

                    if !proposal.elements.isEmpty {
                        Text("Saw \(proposal.elements.joined(separator: ", "))")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                    }

                    if !proposal.tags.isEmpty {
                        LLSectionHeader("Subject tags")
                            .padding(.top, 8)
                        VStack(alignment: .leading, spacing: 10) {
                            LLChipFlow(proposal.tags) { tag in
                                Button {
                                    toggle(tag)
                                } label: {
                                    chip(
                                        SceneMetadata.label(for: tag.value),
                                        isOn: tag.isOn,
                                        systemImage: tag.isOn ? "checkmark" : nil)
                                }
                                .buttonStyle(.plain)
                            }
                            Text("Tap to drop a tag you don't want.")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 13)
                        .llCard()
                    }

                    if proposal.place != nil || proposal.light != nil {
                        LLSectionHeader("From this capture")
                            .padding(.top, 8)
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                if let place = proposal.place {
                                    chip(place, isOn: false, systemImage: "mappin.and.ellipse")
                                }
                                if let light = proposal.light {
                                    chip(light.capitalized, isOn: false, systemImage: "sun.horizon")
                                }
                            }
                            Text("Read from the capture's location and time, not from the image.")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 13)
                        .llCard()
                    }

                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .background(LL.screenBackground)
            .navigationTitle("Auto rename & tag")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        onApply(proposal.accepted)
                        dismiss()
                    }
                    .disabled(proposal.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func toggle(_ tag: AutoNameController.Proposal.Tag) {
        guard let index = proposal.tags.firstIndex(where: { $0.id == tag.id }) else { return }
        proposal.tags[index].isOn.toggle()
    }

    private func chip(_ text: String, isOn: Bool, systemImage: String?) -> some View {
        HStack(spacing: 5) {
            if let systemImage {
                // Decorative: the text beside it already says what the chip is, and VoiceOver
                // otherwise reads the symbol's own name ("sun.horizon").
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(.system(size: 14, weight: isOn ? .semibold : .regular))
        }
        .foregroundStyle(isOn ? Color.white : Color.primary.opacity(0.75))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(isOn ? LL.accent : Color.primary.opacity(0.07), in: Capsule())
    }
}

/// A plain wrapping row of chips. `LazyVGrid` can't do variable-width items and `Flow` layouts
/// need iOS 16's `Layout`, which is available — but this stays a simple measured wrap so the sheet
/// behaves the same on macOS.
struct LLChipFlow<Data: RandomAccessCollection, Content: View>: View where Data.Element: Identifiable {
    private let items: [Data.Element]
    private let content: (Data.Element) -> Content

    init(_ data: Data, @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.items = Array(data)
        self.content = content
    }

    var body: some View {
        ChipFlowLayout(spacing: 8) {
            ForEach(items) { item in
                content(item)
            }
        }
    }
}

private struct ChipFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var total = CGSize(width: 0, height: 0)

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > width {
                total.width = max(total.width, rowWidth)
                total.height += rowHeight + spacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += rowWidth > 0 ? spacing + size.width : size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        total.width = max(total.width, rowWidth)
        total.height += rowHeight
        return total
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
