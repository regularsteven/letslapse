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
        /// The tags the sheet will apply. Started as whatever the model returned, then edited
        /// freely — dropped, added back from the taxonomy, or typed. There is no longer a
        /// ticked/unticked distinction to carry: a tag is in this list or it is not.
        var tags: [String]
        let elements: [String]
        let place: String?
        let light: String?

        /// The record to store, once the user has had their say about the title and the tags.
        /// `elements` rides along untouched: they are not editable here (they describe the frame
        /// rather than classify it), but they are what makes a project findable by what is in it.
        var accepted: SceneMetadata {
            SceneMetadata(
                title: title,
                tags: tags,
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
                tags: result.subjectTags,
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

/// The proposal, before anything is written. The title is editable, the subject tags are the
/// model's guesses and are freely editable — dropped, added back, or typed — and the light and
/// place chips are shown but not editable, being the capture's own facts, handed *to* the model
/// rather than produced by it.
struct AutoNameSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// Edited locally: nothing the user does here touches the project until Apply, and Cancel is
    /// then genuinely free rather than a rollback.
    @State private var proposal: AutoNameController.Proposal
    /// Every tag already used somewhere in this library, for the picker's YOUR TAGS group. Passed
    /// in rather than read from an `@EnvironmentObject`, because this is presented as a sheet and
    /// the list is a plain value the presenter already has.
    private let libraryTags: [String]
    private let onApply: (SceneMetadata) -> Void

    init(
        proposal: AutoNameController.Proposal,
        libraryTags: [String] = [],
        onApply: @escaping (SceneMetadata) -> Void
    ) {
        _proposal = State(initialValue: proposal)
        self.libraryTags = libraryTags
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

                    // Unconditional. This used to be wrapped in `if !proposal.tags.isEmpty`,
                    // which meant a proposal the analysis found no tags for showed no tag
                    // section at all — and since the project row was guarded the same way, the
                    // sheet's only possible outcome was a rename and the project could never be
                    // tagged by hand. With nothing applied the field is just its "+ Add tag"
                    // chip, which is the whole fix.
                    LLSectionHeader("Subject tags")
                        .padding(.top, 8)
                    VStack(alignment: .leading, spacing: 10) {
                        TagField(tags: $proposal.tags, libraryTags: libraryTags)
                        Text(proposal.tags.isEmpty
                             ? "The analysis found no subject tags. Add your own."
                             : "Tap a tag to drop it, or add one of your own.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                    .llCard()

                    if proposal.place != nil || proposal.light != nil {
                        LLSectionHeader("From this capture")
                            .padding(.top, 8)
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                if let place = proposal.place {
                                    chip(place, systemImage: "mappin.and.ellipse")
                                }
                                if let light = proposal.light {
                                    chip(light.capitalized, systemImage: "sun.horizon")
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
        // Pinned rather than left to AppKit, which sizes a sheet from its content and lands near
        // 470pt — at which the card's content box is 406 and the tag chips wrap differently from
        // the phone's for no reason a reader could name. At 393 the box is 329 on both platforms
        // and the tag field is literally the same layout in both places.
        #if os(macOS)
        .frame(width: 393)
        #endif
    }

    /// A chip for a fact the capture already knew — place, light. Inert by design: these were
    /// handed *to* the model, so there is nothing here for the user to correct.
    private func chip(_ text: String, systemImage: String) -> some View {
        HStack(spacing: 5) {
            // Decorative: the text beside it already says what the chip is, and VoiceOver
            // otherwise reads the symbol's own name ("sun.horizon").
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 14))
        }
        .foregroundStyle(Color.primary.opacity(0.75))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.07), in: Capsule())
    }
}
