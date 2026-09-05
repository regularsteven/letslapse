import Foundation
import LetsLapseKit

/// "Add Crafted Text": a brief in, on-screen copy out.
///
/// The model's job is deliberately narrow — split what someone wants to say
/// into at most five LINES, say which words carry the weight, and rank them
/// so the layout knows which is the payoff. Everything visual is decided by
/// `CraftedTextLayout` from those three facts, so a model that answers
/// oddly produces plainer copy rather than a broken frame.
///
/// Nothing leaves the device: this is the same on-device Gemma 4 the Scenes
/// work loads, and the sheet says so because people are right to ask.
@MainActor
final class CraftedTextService {
    static let shared = CraftedTextService()

    private let models: ModelManager

    init(models: ModelManager = .shared) {
        self.models = models
    }

    /// What the sheet calls the model. The design names Gemma 4 E2B, which
    /// is the app's own catalogue entry, but the copy follows whatever is
    /// actually installed rather than promising one model by name.
    static var modelDisplayName: String {
        CraftedTextService.shared.languageModel?.name ?? "Gemma 4 E2B"
    }

    /// The active model, but only when it is one that can WRITE.
    ///
    /// Not every catalogue entry is a language model: the built-in Vision
    /// entry tags scenes with Apple's own classifier and the Core ML entry
    /// segments them, and neither has any text generation in it. Selecting
    /// one of those and opening this sheet used to show the prompt and then
    /// quietly fall back to the splitter — the sheet now goes straight to
    /// the plain field, which is the honest state.
    var languageModel: CatalogModel? {
        guard let model = models.activeModel, model.engine == .mlx else { return nil }
        return model
    }

    /// True when a language model is installed and this device can run it.
    /// The sheet asks first: without one it offers the plain multi-line
    /// field instead of pretending to think.
    var isAvailable: Bool {
        guard models.isReady, let model = languageModel else { return false }
        return models.runtimeBlocker(for: model) == nil
    }

    // MARK: - Asking

    /// The brief as lines. Falls back to the splitter rather than failing:
    /// someone who typed their copy and pressed Send should get layers, and
    /// a model that answered badly is not their problem.
    func parts(for brief: String) async -> [CraftedTextPart] {
        let trimmed = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard isAvailable else { return CraftedTextLayout.split(trimmed) }
        do {
            // Temperature 0. This answer has to be well-formed JSON, and
            // sampling is measurably where that goes wrong: on 2026-09-04,
            // one brief that Gemma answered 5/5 times at 0.0 came back
            // usable only 2/5 at 0.7 and 1/5 at 0.3 — the failures were the
            // model echoing the prompt's own quoting instead of answering.
            // A 22-brief sweep at 0.0 parsed 22/22. The creativity in this
            // task is which words it picks, not how it punctuates JSON.
            let raw = try await compose(
                CraftedTextPrompt.split(brief: trimmed), maxTokens: 320, temperature: 0)
            return try CraftedTextResponse.parts(from: raw)
        } catch {
            return CraftedTextLayout.split(trimmed)
        }
    }

    /// Three directions to choose between. An empty result means the sheet
    /// should say so rather than show an empty list.
    func candidates(for brief: String) async -> [String] {
        let trimmed = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isAvailable else { return [] }
        do {
            // Variety IS the point here — "More like these" that returned
            // the same three directions would be a broken button — so this
            // one keeps its sampling.
            let raw = try await compose(CraftedTextPrompt.candidates(brief: trimmed),
                                        maxTokens: 240, temperature: 0.7)
            return try CraftedTextResponse.options(from: raw)
        } catch {
            return []
        }
    }

    private func compose(
        _ prompt: String, maxTokens: Int, temperature: Float
    ) async throws -> String {
        guard let model = languageModel,
              let snapshot = models.snapshotDirectory(for: model)
        else { throw SceneAnalyser.Failure.noModel }
        // The same last gate the scene path uses: past this line a device
        // without the headroom is killed rather than thrown from.
        if let blocker = models.runtimeBlocker(for: model) {
            throw SceneAnalyser.Failure.insufficientMemory(blocker.message)
        }
        await SceneAnalyser.shared.use(snapshot: snapshot)
        return try await SceneAnalyser.shared.compose(
            prompt: prompt, maxTokens: maxTokens, temperature: temperature)
    }

}
