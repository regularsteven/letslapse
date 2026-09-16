import Foundation
import LetsLapseKit
import SwiftUI

// MARK: - The review session

/// One batch review of Auto rename & tag over the Gallery's selection (2026-09-16,
/// macOS/gallery.batch.autorename.svg): a row per project, filled in as its analysis lands,
/// accepted or discarded one at a time or all at once.
///
/// The rows are the selection in the grid's order. Each starts **pending** — a spinner and
/// skeletons, the capture's own chips already there since they need no model — and fills in
/// as the engine answers, in whatever order that happens. Accept writes that row and drops it;
/// Discard drops it and writes nothing (the analysis stays cached, so re-running is free).
/// Apply all writes every ready row and cancels the rest; Cancel writes nothing. When the list
/// empties by any road the Gallery goes back to its grid with the selection it had.
///
/// Nothing here touches a project until an accept: the rows are values, the writes are one call
/// on `AppModel.applyAutoRename`, and that call is one undo registration however many rows it
/// carried.
@MainActor
final class AutoRenameReviewSession: ObservableObject {

    /// Above this the review list is refused: two hundred rows are not a review, and with Gemma
    /// they are a several-minute stall.
    static let selectionCap = 50

    enum Status: Equatable {
        case pending
        case ready
        case failed(String)
        /// Accepted a moment ago — the tick's beat before the row collapses.
        case accepted
    }

    struct Row: Identifiable, Equatable {
        /// The project.
        let id: UUID
        var status: Status = .pending
        /// Place and light, from the capture itself — populated first.
        var facts: AutoRenameEngine.Facts?
        /// The editable name. Empty means keep the existing name — clearing the field is how a
        /// row is tagged without renaming.
        var name = ""
        /// What the field opened with, so an accept knows whether the person edited it.
        var suggestedName = ""
        /// The suggested tags, as the person has left them — dropped, or added through the picker.
        var tags: [String] = []
        var elements: [String] = []
        /// The project already carries a name a person chose: the row wears *Renaming*.
        var isNameUserSet = false
        var engine: SceneAnalysisRecord.Engine?
        /// Whether Stage A came from the record on disk.
        var fromCache = false
    }

    /// How the review ended.
    enum Outcome: Equatable {
        case cancelled
        /// Rows written, possibly zero — every row discarded is a finished review too.
        case applied(Int)
        /// Nothing could be analysed: the Gallery says so once instead of showing an empty list.
        case allFailed(String)
    }

    @Published var rows: [Row]
    @Published private(set) var isFinished = false
    /// The window's undo manager, handed over by the view so the writes register on it.
    var undoManager: UndoManager?
    var onFinish: ((Outcome) -> Void)?

    private unowned let model: AppModel
    private let engine: AutoRenameEngine
    private var analyses: [UUID: Task<Void, Never>] = [:]
    private var written = 0
    /// Whether any row ever became ready — the difference between "one row failed" (its row says
    /// so, with a retry) and "nothing here could be read" (the Gallery says so once).
    private var anyReady = false

    init(captures: [AppModel.CaptureProject], model: AppModel, engine: AutoRenameEngine = .shared) {
        self.model = model
        self.engine = engine
        rows = captures.map { capture in
            Row(id: capture.id, isNameUserSet: model.isNameUserSet(capture))
        }
    }

    var total: Int { rows.count }
    var readyCount: Int { rows.filter { $0.status == .ready }.count }
    var pendingCount: Int { rows.filter { $0.status == .pending }.count }
    var failedCount: Int { rows.filter { if case .failed = $0.status { return true }; return false }.count }

    /// The panel's readiness line: "2 of 3 ready." — and what Apply all would leave behind.
    var readinessLine: String {
        var line = "\(readyCount) of \(total) ready."
        if pendingCount > 0 {
            line += " Apply all uses what is finished and leaves the rest untouched."
        } else if failedCount > 0 {
            line += failedCount == 1 ? " One couldn't be read." : " \(failedCount) couldn't be read."
        }
        return line
    }

    // MARK: Running

    /// Starts every row's analysis. The engine bounds how many run at once.
    func start() {
        for row in rows { launch(row.id) }
    }

    func retry(_ id: UUID) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].status = .pending
        launch(id)
    }

    private func launch(_ id: UUID) {
        analyses[id]?.cancel()
        analyses[id] = Task { [weak self] in
            guard let self, let capture = model.capture(id: id) else { return }
            // The chips first: metadata needs no model, and the row should carry them while the
            // spinner turns.
            let facts = await engine.facts(for: capture, model: model)
            guard !Task.isCancelled else { return }
            update(id) { $0.facts = facts }
            do {
                let suggestion = try await engine.suggestion(for: capture, model: model, facts: facts)
                guard !Task.isCancelled else { return }
                anyReady = true
                update(id) { row in
                    row.name = suggestion.title
                    row.suggestedName = suggestion.title
                    row.tags = suggestion.tags.map(\.tag)
                    row.elements = suggestion.elements
                    row.engine = suggestion.engine
                    row.fromCache = suggestion.fromCache
                    row.status = .ready
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                LLog("[autorename] \(id.uuidString.prefix(8)) failed: \(error)")
                update(id) { $0.status = .failed("Couldn't read this one") }
                if !anyReady, rows.allSatisfy({ if case .failed = $0.status { return true }; return false }) {
                    finish(.allFailed(rows.count == 1
                        ? "Couldn't read this project's frame."
                        : "Couldn't read any of these projects' frames."))
                }
            }
            analyses[id] = nil
        }
    }

    private func update(_ id: UUID, _ change: (inout Row) -> Void) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        change(&rows[index])
    }

    // MARK: Row bindings

    /// The name field's binding, by project rather than by index. A `ForEach` over `$rows`
    /// hands each field an index-based binding, and the field's end-of-editing callback fires
    /// after the row it belonged to was accepted and removed — AppKit ends editing during the
    /// layout that follows — which read past the array's end and crashed (found 2026-09-16).
    /// By id, a stale field reads an empty string and writes nowhere.
    func nameBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { [weak self] in self?.rows.first { $0.id == id }?.name ?? "" },
            set: { [weak self] value in self?.update(id) { $0.name = value } })
    }

    func tagsBinding(_ id: UUID) -> Binding<[String]> {
        Binding(
            get: { [weak self] in self?.rows.first { $0.id == id }?.tags ?? [] },
            set: { [weak self] value in self?.update(id) { $0.tags = value } })
    }

    // MARK: The row controls

    /// Accept: writes this row's name and tags to the project and removes the row — after the
    /// tick's beat, so the collapse reads as a confirmation rather than a discard.
    func accept(_ id: UUID) {
        guard let row = rows.first(where: { $0.id == id }), row.status == .ready else { return }
        model.applyAutoRename([write(for: row)], undoManager: undoManager)
        written += 1
        update(id) { $0.status = .accepted }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(420))
            self?.remove(id)
        }
    }

    /// Discard: the row goes, nothing is written, the analysis in flight is cancelled. The record
    /// on disk stays — re-running is free.
    func discard(_ id: UUID) {
        analyses[id]?.cancel()
        analyses[id] = nil
        remove(id)
    }

    private func remove(_ id: UUID) {
        guard !isFinished else { return }
        withAnimation(.easeInOut(duration: 0.28)) {
            rows.removeAll { $0.id == id }
        }
        if rows.isEmpty { finish(.applied(written)) }
    }

    // MARK: The panel controls

    /// Apply all: every ready row written as one action, the pending ones cancelled untouched.
    func applyAll() {
        let ready = rows.filter { $0.status == .ready }
        if !ready.isEmpty {
            model.applyAutoRename(ready.map(write(for:)), undoManager: undoManager)
            written += ready.count
        }
        finish(.applied(written))
    }

    /// Cancel: back to the grid, nothing written, nothing left running.
    func cancel() {
        finish(.cancelled)
    }

    /// A project that left the library while under review drops its row silently.
    func dropDeleted() {
        let gone = rows.map(\.id).filter { model.capture(id: $0) == nil }
        guard !gone.isEmpty else { return }
        for id in gone {
            analyses[id]?.cancel()
            analyses[id] = nil
        }
        withAnimation(.easeInOut(duration: 0.28)) {
            rows.removeAll { gone.contains($0.id) }
        }
        if rows.isEmpty { finish(.applied(written)) }
    }

    private func finish(_ outcome: Outcome) {
        guard !isFinished else { return }
        isFinished = true
        for task in analyses.values { task.cancel() }
        analyses.removeAll()
        onFinish?(outcome)
    }

    private func write(for row: Row) -> AppModel.AutoRenameWrite {
        let name = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return AppModel.AutoRenameWrite(
            captureID: row.id,
            name: name.isEmpty ? nil : name,
            nameEdited: name != row.suggestedName.trimmingCharacters(in: .whitespacesAndNewlines),
            tags: row.tags,
            elements: row.elements)
    }

    // MARK: Staging

    #if DEBUG
    /// `LL_AUTORENAME=demo` — the rows in their three drawn states without a model: the first two
    /// ready with distinct suggestions, the last pending for good. For screenshots of the mirror.
    func stageDemo() {
        let names = ["Building on the horizon", "Ridgeline at last light", ""]
        let tags = [["urban", "Architecture", "Waterfront"], ["Sunset", "skyWeather", "Hills"], []]
        let places = ["Karlín", "Šumava", "Karlín"]
        let lights = ["dusk", "dusk", "morning"]
        for index in rows.indices {
            rows[index].facts = AutoRenameEngine.Facts(place: places[index % 3], light: lights[index % 3])
            guard index % 3 != 2 else { continue }
            rows[index].name = names[index % 3]
            rows[index].suggestedName = names[index % 3]
            rows[index].tags = tags[index % 3]
            rows[index].status = .ready
        }
        anyReady = true
    }
    #endif
}

// MARK: - The write, and its undo

extension AppModel {

    /// One project's accepted suggestion.
    struct AutoRenameWrite {
        var captureID: UUID
        /// Nil keeps the existing name — the empty field's meaning.
        var name: String?
        /// Whether the person changed the suggested name before accepting it (`nameWasUserSet`).
        var nameEdited: Bool
        /// Added to whatever the project carries; never removes a tag already there.
        var tags: [String]
        var elements: [String]
    }

    /// What one write changed, for the undo: the prior name and its flag, the tags this action
    /// added (and only those — tags the person had already applied are not this action's to
    /// remove), the prior elements and marker.
    struct AutoRenameUndoEntry {
        var captureID: UUID
        var priorName: String?
        var priorNameWasUserSet: Bool?
        var addedTags: [String]
        var priorElements: [String]?
        var priorTaggedAutomatically: Bool?
    }

    /// Writes the accepted rows — names overwritten, tags added, elements replaced where the
    /// engine named any — as **one** undo registration on `undoManager`, titled for the count.
    func applyAutoRename(_ writes: [AutoRenameWrite], undoManager: UndoManager?) {
        var entries: [AutoRenameUndoEntry] = []
        for write in writes {
            guard let current = capture(id: write.captureID) else { continue }
            let existing = resolvedKeywords(for: current)
            let merged = Self.cleanedSceneTags(existing + write.tags)
            let added = merged.filter { tag in !existing.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }
            let entry = AutoRenameUndoEntry(
                captureID: current.id,
                priorName: current.name,
                priorNameWasUserSet: current.nameWasUserSet,
                addedTags: added,
                priorElements: current.sceneElements,
                priorTaggedAutomatically: current.sceneTaggedAutomatically)

            // An edit: a person accepted this. One manifest write for the name, the tags and the
            // elements, then the keywords layer beside it (tags ARE keywords, Part 2 §4.5).
            let changed = updateCapture(current.id) { capture in
                if let name = write.name, !name.isEmpty, name != capture.displayTitle {
                    capture.name = name
                    capture.nameWasUserSet = write.nameEdited
                }
                capture.sceneTags = merged.isEmpty ? nil : merged
                if !write.elements.isEmpty { capture.sceneElements = write.elements }
                capture.sceneTaggedAutomatically = nil
            }
            guard changed else { continue }
            if let updated = capture(id: current.id) { writeProjectKeywords(merged, for: updated) }
            entries.append(entry)
        }
        guard !entries.isEmpty else { return }
        registerAutoRenameUndo(entries: entries, writes: writes, on: undoManager)
    }

    private func registerAutoRenameUndo(entries: [AutoRenameUndoEntry], writes: [AutoRenameWrite], on undoManager: UndoManager?) {
        guard let undoManager else {
            LLog("[autorename] \(entries.count) written with no undo manager to register on")
            return
        }
        LLog("[autorename] \(entries.count) written, undo registered")
        undoManager.registerUndo(withTarget: self) { model in
            model.revertAutoRename(entries, writes: writes, undoManager: undoManager)
        }
        undoManager.setActionName(entries.count == 1 ? "Auto rename & tag" : "Auto rename & tag (\(entries.count) projects)")
    }

    /// The undo: prior names back, this action's tags off, prior elements back — and the redo
    /// registered as the same writes again.
    private func revertAutoRename(_ entries: [AutoRenameUndoEntry], writes: [AutoRenameWrite], undoManager: UndoManager) {
        for entry in entries {
            guard let current = capture(id: entry.captureID) else { continue }
            let tags = resolvedKeywords(for: current).filter { tag in
                !entry.addedTags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
            }
            updateCapture(current.id) { capture in
                capture.name = entry.priorName
                capture.nameWasUserSet = entry.priorNameWasUserSet
                capture.sceneTags = tags.isEmpty ? nil : tags
                capture.sceneElements = entry.priorElements
                capture.sceneTaggedAutomatically = entry.priorTaggedAutomatically
            }
            if let updated = capture(id: current.id) { writeProjectKeywords(tags, for: updated) }
        }
        undoManager.registerUndo(withTarget: self) { model in
            model.applyAutoRename(writes, undoManager: undoManager)
        }
        undoManager.setActionName(entries.count == 1 ? "Auto rename & tag" : "Auto rename & tag (\(entries.count) projects)")
    }
}
