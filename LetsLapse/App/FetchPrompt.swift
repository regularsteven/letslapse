import LetsLapseKit
import SwiftUI

// MARK: - The just-in-time question (2026-09-25)
//
// docs/connected-asset-states-plan.md §4.2. A control that needs a file this
// device does not hold is drawn greyed in place and still answers a tap —
// with this: what is missing, its size, and **Download and Continue** or
// **Stay as Is**. Declining changes nothing; downloading runs in the
// background (the project card's run, its progress, its Cancel), and once
// the files are here the tap that asked is carried out — if the place that
// asked is still on screen. The preview page asks the same question in its
// own words for its own pages (EditorPreviewPage.swift); everything else —
// the Gallery panel, the project screen, the tile menu — asks through
// `.fetchPrompt(_:)`.

/// How the prompt and the preview page's line name what is missing, and
/// agree with it.
struct FetchNoun: Equatable {
    var text: String
    var isPlural: Bool

    var capitalized: String { text.prefix(1).uppercased() + text.dropFirst() }
    var pronoun: String { isPlural ? "they" : "it" }
    var object: String { isPlural ? "them" : "it" }
    var verb: String { isPlural ? "are" : "is" }

    /// "the originals", "the rest of the originals", "this blend" — and a
    /// Photo capture's picture, "the full-size photo".
    static func `for`(_ shortfall: ProjectHoldings.Shortfall?, isPhotoCapture: Bool) -> FetchNoun {
        if isPhotoCapture, shortfall?.needsBlends == true || shortfall?.needsOriginals == true || shortfall == nil {
            return FetchNoun(text: "the full-size photo", isPlural: false)
        }
        guard let shortfall else { return FetchNoun(text: "the originals", isPlural: true) }
        return FetchNoun(text: shortfall.noun,
                         isPlural: shortfall.needsOriginals || shortfall.blendIDs.count != 1)
    }
}

/// The words of one question: the title and the message for what was
/// tapped, what it is short of, and what PicPlace can do about it.
struct FetchPromptContent {
    /// "Light", "Presets", "The Text page", "New clip".
    var subject: String
    var shortfall: ProjectHoldings.Shortfall
    var noun: FetchNoun
    var offer: PicPlaceController.FetchOffer

    var title: String {
        switch offer {
        case .download: return "Download \(noun.text)?"
        case .downloading: return "Downloading \(noun.text)"
        case .signIn: return "Sign in to PicPlace?"
        case .connect: return "This library isn't connected"
        case .notUploaded: return "\(noun.capitalized) \(noun.verb)n't on PicPlace yet"
        case .unavailable: return "\(noun.capitalized) \(noun.verb)n't here"
        }
    }

    @MainActor var message: String {
        let needs = "\(subject) needs \(noun.text)"
        switch offer {
        case .download:
            return "\(needs) — \(shortfall.sizeText) on PicPlace. You can keep browsing while \(noun.pronoun) download\(noun.isPlural ? "" : "s")."
        case .downloading(let progress):
            let percent = Int((progress.fraction * 100).rounded())
            return "\(percent) % so far. \(subject) can go ahead as soon as \(noun.pronoun) \(noun.verb) here."
        case .signIn:
            return "\(needs). \(noun.capitalized) \(noun.verb) on PicPlace — sign in to download \(noun.object)."
        case .connect:
            return "\(needs), which \(noun.verb) on PicPlace. Connect this library to your PicPlace account in Settings to download \(noun.object)."
        case .notUploaded(let device):
            return "\(needs). \(noun.capitalized) \(noun.verb) still only on \(device ?? "the device that made \(noun.object)") — once \(noun.pronoun) \(noun.verb) uploaded from there, \(noun.pronoun) can come down here."
        case .unavailable:
            return "\(needs), and \(noun.pronoun) \(noun.verb)n't on \(PicPlaceController.deviceWord) or on PicPlace."
        }
    }
}

/// One question to ask: what was tapped and what it needs; `onArrival` is
/// the tap carried out once the files are here.
struct FetchPromptRequest: Identifiable {
    let id = UUID()
    let captureID: UUID
    let capability: ProjectCapability
    let subject: String
    var onArrival: (() -> Void)?
}

extension AppModel {
    /// A tap on a control that needs `capability`: runs `action` when the
    /// device holds what it needs, else returns the question to ask.
    func request(_ capability: ProjectCapability, for capture: CaptureProject, subject: String,
                 then action: @escaping () -> Void) -> FetchPromptRequest? {
        guard !availability(of: capability, for: capture).isAvailable else {
            action()
            return nil
        }
        return FetchPromptRequest(captureID: capture.id, capability: capability, subject: subject, onArrival: action)
    }
}

extension View {
    /// Asks the question `request` names (see `FetchPromptRequest`).
    func fetchPrompt(_ request: Binding<FetchPromptRequest?>) -> some View {
        modifier(FetchPromptModifier(request: request))
    }
}

private struct FetchPromptModifier: ViewModifier {
    @EnvironmentObject private var model: AppModel
    @Binding var request: FetchPromptRequest?
    /// The question on screen, worded when it was asked.
    @State private var asked: Asked?
    /// A *Download and Continue* waiting for its files.
    @State private var waiting: FetchPromptRequest?

    private struct Asked: Identifiable {
        var request: FetchPromptRequest
        var content: FetchPromptContent
        var id: UUID { request.id }
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: request?.id) { _, _ in word() }
            .onAppear { word() }
            .onReceive(model.holdingsStore.$revision) { _ in carryOn(model.picplace.progress) }
            // The download's end: `$progress` publishes before it changes,
            // so the value it hands over is the one to read.
            .onReceive(model.picplace.$progress) { progress in carryOn(progress) }
            .alert(asked?.content.title ?? "", isPresented: Binding(
                get: { asked != nil }, set: { if !$0 { asked = nil; request = nil } }), presenting: asked) { asked in
                actions(asked)
            } message: { asked in
                Text(asked.content.message)
            }
    }

    private func word() {
        guard let request, asked?.id != request.id, let capture = model.capture(id: request.captureID) else { return }
        guard let shortfall = model.availability(of: request.capability, for: capture).shortfall else {
            // Here after all: the tap goes ahead.
            self.request = nil
            request.onArrival?()
            return
        }
        let content = FetchPromptContent(
            subject: request.subject, shortfall: shortfall,
            noun: .for(shortfall, isPhotoCapture: capture.isPhotoCapture),
            offer: model.picplace.fetchOffer(for: capture, shortfall: shortfall))
        asked = Asked(request: request, content: content)
    }

    @ViewBuilder private func actions(_ asked: Asked) -> some View {
        switch asked.content.offer {
        case .download:
            Button("Download and Continue") {
                guard let capture = model.capture(id: asked.request.captureID) else { return }
                if model.picplace.fetch(capture, shortfall: asked.content.shortfall) { waiting = asked.request }
            }
            Button("Stay as Is", role: .cancel) {}
        case .downloading:
            Button("Continue When Ready") { waiting = asked.request }
            Button("Stay as Is", role: .cancel) {}
        case .signIn:
            Button("Sign In") { model.picplace.signIn() }
            Button("Stay as Is", role: .cancel) {}
        case .connect, .notUploaded, .unavailable:
            Button("OK", role: .cancel) {}
        }
    }

    /// The files a *Download and Continue* waited for are here: the tap
    /// goes ahead — only while the view that asked is still on screen,
    /// which it is if this modifier is.
    private func carryOn(_ progress: [UUID: PicPlaceSyncProgress]) {
        guard let waiting, let capture = model.capture(id: waiting.captureID) else { return }
        guard progress[capture.id]?.phase != .downloading else { return }
        guard model.availability(of: waiting.capability, for: capture).isAvailable else { return }
        self.waiting = nil
        waiting.onArrival?()
    }
}
