import CoreLocation
import SwiftUI

/// Drives one "Auto rename & tag" run: the capture's facts, the cached analysis, a proposal.
///
/// Nothing is written until the user confirms. The controller's whole job is to get from a tap to
/// a filled-in sheet — `Apply` is one call on `AppModel` from the view. Since 2026-09-16 the run
/// goes through `AutoRenameEngine`: the multi-frame sampler is no longer called from here (the
/// silent capture-time pass still uses it), and a second run on the same project reads the
/// record beside it instead of the model.
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
        /// The title the sheet opened with — the model's, or the project's current name where the
        /// model wrote none — so Apply can tell an accepted suggestion from a typed one
        /// (`CaptureProject.nameWasUserSet`).
        var suggestedTitle: String = ""
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

    /// Stage A from the record beside the project when it is current — one look at the
    /// thumbnail's frame, ever — and Stage B over it (brief §2). The sheet it fills is the same
    /// one; what changes is that a second run costs nothing, whichever screen made the first. The
    /// tags open as the project's own plus the reconciled suggestions, so Apply adds rather than
    /// replaces (a hand-typed tag survives an accepted proposal). With no title from the engine
    /// (Vision) the field opens on the project's current title and the sheet is about the tags.
    func run(capture: AppModel.CaptureProject, model: AppModel) async {
        guard !isRunning else { return }
        status = "Looking at this one…"
        failure = nil
        defer { status = nil }
        do {
            let engine = AutoRenameEngine.shared
            let facts = await engine.facts(for: capture, model: model)
            let suggestion = try await engine.suggestion(for: capture, model: model, facts: facts)
            let opening = suggestion.title.isEmpty ? capture.displayTitle : suggestion.title
            let applied = model.resolvedKeywords(for: capture)
            proposal = Proposal(
                title: opening,
                suggestedTitle: opening,
                tags: applied + suggestion.tags.map(\.tag),
                elements: suggestion.elements,
                place: facts.place,
                light: facts.light)
        } catch {
            failure = error.localizedDescription
        }
    }

    /// The capture's own fix, read off the file it was written into — EXIF for a still, the
    /// QuickTime location atom for a recording.
    static func location(of url: URL?) async -> CLLocation? {
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
    /// The accepted record, and whether the person changed the title before accepting it.
    private let onApply: (SceneMetadata, _ nameEdited: Bool) -> Void

    init(
        proposal: AutoNameController.Proposal,
        libraryTags: [String] = [],
        onApply: @escaping (SceneMetadata, _ nameEdited: Bool) -> Void
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
                        let edited = proposal.title.trimmingCharacters(in: .whitespacesAndNewlines)
                            != proposal.suggestedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                        onApply(proposal.accepted, edited)
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

// MARK: - Shared presentation

/// The sheet and its failure alert, attached wherever a screen holds an `AutoNameController` — the
/// project screen's management card and, since 2026-09-16, the Gallery's preview panel. One
/// presentation, one Apply: `AppModel.applySceneMetadata` with the edited-title flag.
private struct AutoNamePresentation: ViewModifier {
    @EnvironmentObject var model: AppModel
    @ObservedObject var controller: AutoNameController
    var captureID: UUID

    func body(content: Content) -> some View {
        content
            .sheet(item: $controller.proposal) { proposal in
                AutoNameSheet(proposal: proposal, libraryTags: model.libraryTags) { metadata, nameEdited in
                    if let capture = model.capture(id: captureID) {
                        model.applySceneMetadata(metadata, to: capture, nameEdited: nameEdited)
                    }
                }
            }
            .alert(
                "Couldn't analyse this project",
                isPresented: Binding(
                    get: { controller.failure != nil },
                    set: { if !$0 { controller.failure = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(controller.failure ?? "")
            }
    }
}

extension View {
    /// Presents `controller`'s proposal for the project `captureID` as the Auto rename & tag sheet.
    func autoNamePresentation(_ controller: AutoNameController, captureID: UUID) -> some View {
        modifier(AutoNamePresentation(controller: controller, captureID: captureID))
    }
}
