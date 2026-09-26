import Foundation
import LetsLapseKit

// MARK: - What a device holds, and what that allows (2026-09-25)
//
// docs/connected-asset-states-plan.md §3. A device may hold all, some or
// none of a project's files — its originals, its blends, and always the
// preview that stands in for both. The app looks and behaves the same
// whatever it holds; only what a control can do changes. Every control
// that needs a file asks here — the editor's groups and pages, presets,
// New blended clip, a blend's play, an export — rather than keeping a file
// check of its own, and the prompt that offers to fetch what is missing
// reads its size from the same answer.

/// What a control needs to do its work.
enum ProjectCapability: Hashable {
    /// The preview — browsing and swiping. Always.
    case browse
    /// Names, tags, the IPTC record, notes. Always (rule 5).
    case metadata
    /// The editor's groups and pages, presets from anywhere, Rotate 90°
    /// (rule 6): the originals — a Photo capture, its picture.
    case pixelEdit
    /// A new blend of any kind (rule 1): every original.
    case newBlend
    /// The shoot's frames one by one — View all photos, Review, Stabilise,
    /// Save all to Photos.
    case frames
    /// One blend's file — play it, open it, put it in a collection (rule 4).
    case blend(UUID)
    /// The whole project leaving the device — a `.lapse`, a nearby
    /// transfer, a DNG archive: the originals and every blend.
    case exportProject
}

/// A capability here, or what it is short of.
enum CapabilityAvailability: Equatable {
    case available
    case needs(ProjectHoldings.Shortfall)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    var shortfall: ProjectHoldings.Shortfall? {
        if case .needs(let shortfall) = self { return shortfall }
        return nil
    }
}

/// What this device holds of each project, as far as it has been asked —
/// the cache behind `AppModel.holdings(for:)`. Observed by what shows
/// holdings (the badges, the preview page, the *Here* row, the prompt), not
/// through the model: its revision moves batch by batch as tiles scroll in.
@MainActor
final class ProjectHoldingsStore: ObservableObject {
    /// One folder walk per project, dropped by `noteFilesChanged(for:)`.
    var cache: [UUID: ProjectHoldings] = [:]
    /// The walks in flight off the main actor, so a list of tiles asks once.
    var loading: Set<UUID> = []
    /// Tiles that asked in the last beat, walked together (`requestHoldings`).
    var requested: Set<UUID> = []
    var flush: Task<Void, Never>?
    /// The last answer per project, kept across a drop until the walk
    /// after it lands — what a pill shows meanwhile, so it does not blink
    /// out while its project is walked again. Display only.
    var shown: [UUID: ProjectHoldings] = [:]
    /// Moves whenever a project's holdings are known anew or dropped.
    @Published var revision = 0
}

extension AppModel {

    // MARK: Holdings

    /// The store's revision — read where a value is compared; a view that
    /// has to redraw on it observes `holdingsStore` itself.
    var holdingsRevision: Int { holdingsStore.revision }

    /// What one project's holdings are built from — read on the main actor,
    /// walked off it.
    struct HoldingsInputs {
        var folder: URL
        var originals: [(name: String, files: [String])]
        var blends: [(id: UUID, fileName: String)]
        var pictureBlendID: UUID?
    }

    func holdingsInputs(for capture: CaptureProject) -> HoldingsInputs {
        Self.holdingsInputs(capture: capture, blends: blends(for: capture), folder: projectFolderURL(for: capture))
    }

    /// The same from a document read anywhere — the status sweep's, off the
    /// main actor. `blends` are the live ones, newest first.
    nonisolated static func holdingsInputs(capture: CaptureProject, blends: [BlendProject], folder: URL) -> HoldingsInputs {
        let originals: [(name: String, files: [String])] = capture.sourceFileNames
            .filter { !$0.hasSuffix(".json") }
            .map { name in
                // A clip converted to another codec is here while any of
                // its encodings is — the rule playback and blending use.
                guard capture.kind == .video else { return (name, [name]) }
                let stored = capture.clipEncodings?[name] ?? []
                return (name, stored.isEmpty ? [name] : stored.map(\.fileName))
            }
        // A Photo capture is edited on its picture — its stack (T3).
        let picture = capture.isPhotoCapture ? blends.first { $0.kind == .image }?.id : nil
        return HoldingsInputs(
            folder: folder,
            originals: originals,
            blends: blends.map { ($0.id, $0.outputFileName) },
            pictureBlendID: picture)
    }

    /// One walk of the folder and one read of `assets.ndjson` — safe off the
    /// main actor.
    nonisolated static func buildHoldings(_ inputs: HoldingsInputs) -> ProjectHoldings {
        let entries = (try? PicPlaceSyncRun.listFiles(in: inputs.folder)) ?? []
        var present: [String: Int64] = [:]
        for entry in entries { present[entry.name] = entry.bytes }
        var recorded: [String: Int64] = [:]
        for record in AssetRecords.load(inProjectFolder: inputs.folder).ordered {
            if let bytes = record.bytes { recorded[record.name] = bytes }
        }
        var holdings = ProjectHoldings(
            originals: inputs.originals, blends: inputs.blends, pictureBlendID: inputs.pictureBlendID,
            present: present, recordedBytes: recorded,
            hasPreview: present[ProjectFileRegistry.posterName] != nil)
        // The heavy set here, fingerprinted as PicPlace's backed-up marker
        // is (`heavyDigest`) — what the holdings pill's green tick compares.
        let heavy = PicPlaceController.heavyFiles(entries)
        holdings.localHeavyDigest = PicPlaceOriginalsCheck.digest(heavy)
        holdings.localHeavyFiles = heavy.count
        holdings.localBlendsDigest = PicPlaceOriginalsCheck.digest(heavy.filter { $0.kind == .blend })
        return holdings
    }

    /// A Photo capture's picture when it is a stack (a JPEG burst): the
    /// newest image blend. What its editor, tile and hero stand for.
    func pictureBlend(for capture: CaptureProject) -> BlendProject? {
        guard capture.isPhotoCapture else { return nil }
        return blends(for: capture).first { $0.kind == .image }
    }

    /// What this device holds of `capture` — cached; a miss walks the
    /// folder here, so call it where one project is in focus (a tap, a
    /// page), and `loadHoldings(for:)` for a list.
    func holdings(for capture: CaptureProject) -> ProjectHoldings {
        if let cached = holdingsStore.cache[capture.id] { return cached }
        let holdings = Self.buildHoldings(holdingsInputs(for: capture))
        holdingsStore.cache[capture.id] = holdings
        holdingsStore.shown[capture.id] = holdings
        return holdings
    }

    func cachedHoldings(for id: UUID) -> ProjectHoldings? {
        holdingsStore.cache[id]
    }

    /// For a badge: the answer, else the last one while it is walked again.
    /// Never for a capability — that reads `holdings(for:)`.
    func shownHoldings(for id: UUID) -> ProjectHoldings? {
        holdingsStore.cache[id] ?? holdingsStore.shown[id]
    }

    /// Walks the projects not yet known, off the main actor, and publishes
    /// them together — the tiles of a list, the page a swipe is heading to.
    func loadHoldings(for ids: [UUID]) {
        let wanted = ids.filter { holdingsStore.cache[$0] == nil && !holdingsStore.loading.contains($0) }
        guard !wanted.isEmpty else { return }
        let jobs: [(id: UUID, inputs: HoldingsInputs)] = wanted.compactMap { id in
            capture(id: id).map { (id, holdingsInputs(for: $0)) }
        }
        holdingsStore.loading.formUnion(jobs.map(\.id))
        Task { [weak self] in
            let built = await Task.detached(priority: .utility) {
                jobs.map { job in
                    (job.id, AppModel.buildHoldings(job.inputs), ProjectLocalStatus.signature(folder: job.inputs.folder))
                }
            }.value
            guard let self else { return }
            for (id, holdings, signature) in built where self.holdingsStore.loading.contains(id) {
                self.holdingsStore.cache[id] = holdings
                self.holdingsStore.shown[id] = holdings
                self.holdingsStore.loading.remove(id)
                // The Gallery's PicPlace filters read the same answer.
                self.noteHoldings(holdings, for: id, signature: signature)
            }
            self.holdingsStore.revision &+= 1
        }
    }

    /// One tile asking as it appears: gathered for a beat, so a grid of
    /// tiles scrolling in is one walk off the main actor, not one each.
    func requestHoldings(_ id: UUID) {
        guard holdingsStore.cache[id] == nil, !holdingsStore.loading.contains(id) else { return }
        holdingsStore.requested.insert(id)
        guard holdingsStore.flush == nil else { return }
        holdingsStore.flush = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard let self else { return }
            let ids = Array(self.holdingsStore.requested)
            self.holdingsStore.requested.removeAll()
            self.holdingsStore.flush = nil
            self.loadHoldings(for: ids)
        }
    }

    /// The picture that stands for a project whose own is not on this device
    /// — today its `poster.jpg`. The one door every reader of the preview
    /// goes through (the preview page, the badges' neighbours), so the
    /// server-side renditions Steven plans (D2, plan §5) replace one line.
    func previewPictureURL(for capture: CaptureProject) -> URL? {
        posterURL(for: capture)
    }

    /// Forgets what is known of one project's files — every path that
    /// changes them comes through `noteFilesChanged(for:)`, which calls this.
    func dropHoldings(for id: UUID) {
        let known = holdingsStore.cache.removeValue(forKey: id) != nil
        // A walk in flight read the folder before the change.
        let loading = holdingsStore.loading.remove(id) != nil
        if known || loading { holdingsStore.revision &+= 1 }
        // The filters' summary is walked again a beat later.
        noteStatusStale(id)
    }

    // MARK: Capabilities

    /// What `capability` needs of this device.
    func need(for capability: ProjectCapability, in holdings: ProjectHoldings) -> ProjectHoldings.Need {
        switch capability {
        case .browse, .metadata: return .nothing
        case .pixelEdit: return holdings.pictureNeed
        case .newBlend, .frames: return .originals
        case .blend(let id): return .blends([id])
        case .exportProject: return ProjectHoldings.Need(originals: true, blendIDs: Set(holdings.blends.map(\.id)))
        }
    }

    /// The whole answer — what is missing and what it weighs. Walks the
    /// folder on a cache miss: for a tap, a prompt, a page.
    func availability(of capability: ProjectCapability, for capture: CaptureProject) -> CapabilityAvailability {
        let holdings = holdings(for: capture)
        guard let shortfall = holdings.shortfall(for: need(for: capability, in: holdings)) else { return .available }
        return .needs(shortfall)
    }

    /// Yes or no, cheaply — for a view body: the cached holdings when they
    /// are known, else the same existence checks the rest of the app makes
    /// (a stat per frame once per session for a complete shoot, one stat
    /// for a missing one).
    func isAvailable(_ capability: ProjectCapability, for capture: CaptureProject) -> Bool {
        if let holdings = holdingsStore.cache[capture.id] {
            return holdings.shortfall(for: need(for: capability, in: holdings)) == nil
        }
        switch capability {
        case .browse, .metadata:
            return true
        case .pixelEdit:
            if let picture = pictureBlend(for: capture) { return !blendFileMissing(picture) }
            return !sourcesMissing(capture)
        case .newBlend, .frames:
            return !sourcesMissing(capture)
        case .blend(let id):
            guard let blend = blends(for: capture).first(where: { $0.id == id }) else { return true }
            return !blendFileMissing(blend)
        case .exportProject:
            return !heavyFilesMissing(capture)
        }
    }
}

// MARK: - Words

extension ProjectHoldings.Shortfall {
    /// "the originals", "the rest of the originals", "this blend", "2 blends",
    /// "the originals and a blend" — what the prompt says is missing.
    var noun: String {
        var parts: [String] = []
        if needsOriginals { parts.append(isPartial ? "the rest of the originals" : "the originals") }
        if needsBlends {
            parts.append(blendIDs.count == 1 ? (needsOriginals ? "a blend" : "this blend") : "\(blendIDs.count) blends")
        }
        return parts.joined(separator: " and ")
    }

    /// "412 files · 2.4 GB", "1 file · 86 MB", "at least 2.1 GB" when a size
    /// was never recorded.
    var sizeText: String {
        let count = fileCountForText
        let files = "\(count.formatted()) file\(count == 1 ? "" : "s")"
        guard bytes > 0 else { return files }
        let size = LLFormat.bytes(bytes)
        return "\(files) · \(bytesAreComplete ? size : "at least \(size)")"
    }

    /// Originals by logical name (a converted clip's encodings are one
    /// original), blends one each.
    private var fileCountForText: Int { originals.count + blendIDs.count }
}

extension ProjectHoldings.Tier {
    /// "Originals here" · "Blends here" · "Preview only".
    var label: String {
        switch self {
        case .originals: return "Originals here"
        case .blends: return "Blends here"
        case .preview: return "Preview only"
        }
    }

    var systemImage: String {
        switch self {
        case .originals: return "internaldrive"
        case .blends: return "square.stack"
        case .preview: return "icloud"
        }
    }
}

// MARK: - A genuine preview without a server (DEBUG)

#if DEBUG
extension AppModel {
    /// `LL_DROP_SOURCES=<latest|uuid>[:originals|blends|all]` — makes a real
    /// preview-only project on a machine with no server: renders the poster
    /// a push would (`poster.jpg`, and a still for each blend it drops), then
    /// deletes the heavy files. Only on a scratch root on the Mac
    /// (`-storage.libraryRootPath`) or in the Simulator — never a library a
    /// person keeps their shoots in. The records stay, so the project is
    /// exactly what a pull, or free up space, would leave.
    func debugDropSources(_ raw: String) async {
        #if os(macOS)
        guard StorageRoot.rootCameFromArguments else {
            LLog("LL_DROP_SOURCES refused — not a scratch root (-storage.libraryRootPath)")
            return
        }
        #elseif !targetEnvironment(simulator)
        LLog("LL_DROP_SOURCES refused — only in the Simulator on iOS")
        return
        #endif
        let parts = raw.split(separator: ":").map(String.init)
        let which = parts.first ?? "latest"
        let scope = parts.count > 1 ? parts[1] : "originals"
        guard let capture = which == "latest" ? newestCapture() : UUID(uuidString: which).flatMap({ capture(id: $0) }) else {
            LLog("LL_DROP_SOURCES: no such project \(which)")
            return
        }
        let folder = projectFolderURL(for: capture)
        // The poster first, from the files that are still here.
        if posterURL(for: capture) == nil, let source = thumbnailURL(for: capture) {
            let token = picplace.currentPosterToken(for: capture)
            _ = await PicPlacePoster.ensure(sourceURL: source, kind: mediaKind(for: capture), grade: photoGrade(for: capture),
                                            token: token, lastToken: nil, in: folder)
        }
        let dropsBlends = scope == "blends" || scope == "all"
        let dropsOriginals = scope == "originals" || scope == "all"
        if dropsBlends {
            _ = await ensureBlendPosters(for: capture, fileNames: Set(blends(for: capture).map(\.outputFileName)))
        }
        let heavy = await Task.detached(priority: .utility) { PicPlaceController.heavyFiles(in: folder) }.value
        var dropped = 0
        for file in heavy where (file.kind == .source && dropsOriginals) || (file.kind == .blend && dropsBlends) {
            do {
                try FileManager.default.removeItem(at: folder.appendingPathComponent(file.name))
                dropped += 1
            } catch {
                LLog("LL_DROP_SOURCES: could not remove \(file.name): \(error)")
            }
        }
        noteFilesChanged(for: capture.id)
        noteIndexChanged()
        LLog("LL_DROP_SOURCES dropped \(dropped) file(s) (\(scope)) of \(capture.id.uuidString.prefix(8)) \(capture.displayTitle) — poster \(posterURL(for: capture) == nil ? "missing" : "here")")
    }
}
#endif
