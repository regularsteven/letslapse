import ImageIO
import LetsLapseKit
import SwiftUI

// MARK: - Status glyphs (2026-09-26, Steven's sign-off of the "Holdings Pill States" canvas, revision 2)
//
// Green means here — on this device, ready to edit or play — and nothing
// else is ever green. The asset glyphs say where each thing is: the camera
// is the originals, the layers the blends; green here, grey on PicPlace (it
// can come down), grey and slashed nowhere reachable. One cloud, never
// green, says whether what is HERE is also on PicPlace, and whether anything
// moves:
//
//   cloud ✓   PicPlace holds everything the project has: all of it here
//             verified there (`heavyDigest`), or — nothing heavy here — its
//             originals there. Removing the originals keeps the tick: the
//             camera greys, nothing was lost (Steven, 2026-09-26).
//   cloud ↑   something here is not on PicPlace yet
//   amber ↑ ↓ ↻  uploading, downloading, checking — a removal's check, and a
//             fresh upload PicPlace is still reading back (never ↑ beside
//             "Here and on PicPlace"); never a records-only sync
//   cloud ‖   an upload job waits (paused, Wi-Fi, iOS stopped it)
//   red !     needs attention: a failure, a conflict
//   (none)    no PicPlace, or PicPlace holds nothing of it
//
// Every surface — tiles, list rows, blend rows, the PicPlace card, the
// editor's banner, the filters — draws from `StatusGlyph`: one glyph, one
// meaning (the 2026-09-26 review found a green tick meaning "backed up", an
// outline cloud meaning four things, an upload arrow over a removal).

/// One status glyph.
enum StatusGlyph: Equatable {
    enum Asset: Equatable { case originals, blends }
    enum Place: Equatable { case here, there, nowhere }
    enum Cloud: Equatable { case safe, needsUploading, uploading, downloading, checking, waiting, attention }
    case asset(Asset, Place)
    case cloud(Cloud)
    /// Not a status: an ordinary symbol in the neutral colour (a filter's All).
    case symbol(String)

    /// The blends' glyph as a status: the layers, drawn solid.
    static let blendsSolid = "square.3.layers.3d.top.filled"
}

/// A status glyph as drawn. `photo`: on a picture, in the pill's dark dress,
/// whatever the appearance; `adaptive`: lists and cards, light or dark.
struct StatusGlyphView: View {
    enum Surface { case photo, adaptive }
    let glyph: StatusGlyph
    var size: CGFloat
    var surface: Surface = .adaptive
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        content.font(.system(size: size, weight: .semibold))
    }

    @ViewBuilder private var content: some View {
        switch glyph {
        case .asset(let asset, let place):
            assetImage(asset, place).foregroundStyle(place == .here ? green : grey)
        case .cloud(let cloud):
            cloudImage(cloud).foregroundStyle(colour(for: cloud))
        case .symbol(let name):
            Image(systemName: name).foregroundStyle(neutral)
        }
    }

    @ViewBuilder private func assetImage(_ asset: StatusGlyph.Asset, _ place: StatusGlyph.Place) -> some View {
        switch (asset, place) {
        case (.originals, .nowhere):
            // No slashed camera in SF Symbols: the slash is drawn, a gap
            // knocked through the camera first.
            Image(systemName: "camera.fill")
                .overlay { SlashLine().stroke(style: StrokeStyle(lineWidth: size * 0.34, lineCap: .round)).blendMode(.destinationOut) }
                .overlay { SlashLine().stroke(style: StrokeStyle(lineWidth: size * 0.13, lineCap: .round)) }
                .compositingGroup()
        case (.originals, _):
            Image(systemName: "camera.fill")
        case (.blends, .nowhere):
            Image(systemName: "square.3.layers.3d.slash")
        case (.blends, _):
            Image(systemName: StatusGlyph.blendsSolid)
        }
    }

    @ViewBuilder private func cloudImage(_ cloud: StatusGlyph.Cloud) -> some View {
        switch cloud {
        case .safe: Image(systemName: "checkmark.icloud.fill")
        case .needsUploading, .uploading: Image(systemName: "icloud.and.arrow.up.fill")
        case .downloading: Image(systemName: "icloud.and.arrow.down.fill")
        case .checking: Image(systemName: "arrow.clockwise.icloud.fill")
        case .attention: Image(systemName: "exclamationmark.icloud.fill")
        case .waiting:
            // No paused cloud in SF Symbols: pause bars knocked out of a cloud.
            Image(systemName: "icloud.fill")
                .overlay {
                    Image(systemName: "pause.fill")
                        .font(.system(size: size * 0.42, weight: .black))
                        .offset(y: size * 0.08)
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
        }
    }

    private var dark: Bool { surface == .photo || scheme == .dark }
    private var green: Color { dark ? Color(red: 48 / 255, green: 209 / 255, blue: 88 / 255) : Color(red: 36 / 255, green: 138 / 255, blue: 61 / 255) }
    private var grey: Color { dark ? Color.white.opacity(0.45) : Color(white: 0.68) }
    private var neutral: Color { dark ? Color.white.opacity(0.9) : Color(white: 0.28) }

    private func colour(for cloud: StatusGlyph.Cloud) -> Color {
        switch cloud {
        case .safe, .needsUploading, .waiting: return neutral
        case .uploading, .downloading, .checking: return dark ? LL.amber : LL.accent
        // Red, not the old failure tint (`levelOff`, an orange beside the amber).
        case .attention: return dark ? Color(red: 1, green: 69 / 255, blue: 58 / 255) : Color(red: 215 / 255, green: 0, blue: 21 / 255)
        }
    }
}

/// The slash of a slashed glyph, corner to corner.
private struct SlashLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.06, y: rect.minY + rect.height * 0.02))
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.06, y: rect.maxY - rect.height * 0.02))
        return path
    }
}

// MARK: - The holdings pill

/// A project's holdings pill.
struct HoldingsPill: View {
    @EnvironmentObject private var model: AppModel
    let captureID: UUID

    var body: some View {
        HoldingsPillContent(picplace: model.picplace, holdings: model.holdingsStore, captureID: captureID)
    }
}

/// What the pill says: where the originals and the blends are, and the cloud.
/// A nil part is not drawn.
struct HoldingsPillState: Equatable {
    var originals: StatusGlyph.Place?
    var blends: StatusGlyph.Place?
    var cloud: StatusGlyph.Cloud?

    static let empty = HoldingsPillState(originals: nil, blends: nil, cloud: nil)
    var isEmpty: Bool { self == .empty }
}

extension AppModel {
    /// The pill's state for a project — nil until its holdings are known
    /// (the pill keeps its seat and asks).
    func holdingsPillState(for captureID: UUID, holdings: ProjectHoldings?) -> HoldingsPillState? {
        guard let capture = capture(id: captureID), let holdings else { return nil }
        let connected = picplace.binding != nil
        let origin = originID(of: capture)
        let record = picplace.records[origin]
        let known = record.map { $0.revision > 0 || $0.policy == "pull" } ?? false

        // Where each thing is. The originals: here, else on PicPlace by the
        // filters' own rule (`originalsOnPicPlace`), else nowhere reachable.
        let originalsHere = holdings.tier == .originals
        var originals: StatusGlyph.Place? = originalsHere ? .here
            : known && originalsOnPicPlace(origin: origin, record: record) ? .there : .nowhere
        // The blends — a Photo's stack is its picture, not a blend here.
        // Green only when every one is here; grey when a missing one can
        // come down (or PicPlace has not said); slashed when none can.
        var blends: StatusGlyph.Place?
        let others = holdings.blends.filter { $0.id != holdings.pictureBlendID }
        if !others.isEmpty {
            if others.allSatisfy(\.isHere) {
                blends = .here
            } else {
                let canCome = others.contains { held in
                    guard !held.isHere, let blend = blend(id: held.id) else { return false }
                    return picplace.blendAvailability(blend, of: capture) != .notOnPicPlace
                }
                blends = canCome ? .there : .nowhere
            }
        }
        // A library never connected to PicPlace: every original here is
        // the norm, and a camera on every tile would say nothing.
        if !connected, originals == .here { originals = nil }

        // Whether what is here is safe, and whether anything moves.
        var cloud: StatusGlyph.Cloud?
        if connected {
            let progress = picplace.progress[captureID]
            let job = picplace.uploadJobs[captureID]
            if let progress, progress.phase == .downloading {
                cloud = .downloading
            } else if let progress, progress.phase == .verifying || progress.phase == .removing {
                cloud = .checking
            } else if progress != nil, picplace.uploadStops[captureID] != nil {
                // Only a heavy run (originals, blends) has a stop signal: a
                // records-only sync draws nothing.
                cloud = .uploading
            } else if picplace.conflicts.contains(where: { $0.originID == origin })
                        || (picplace.canSync && record?.lastError != nil) || job?.hold == .failed {
                cloud = .attention
            } else if let hold = job?.hold, hold == .paused || hold == .waitingForWiFi || hold == .interrupted {
                cloud = .waiting
            } else if holdings.localHeavyFiles > 0 {
                let safe = known && record.map {
                    Self.isBackedUp($0, holdings: holdings)
                        || (!originalsHere && $0.blendsDigest != nil && $0.blendsDigest == holdings.localBlendsDigest)
                } == true
                if safe {
                    cloud = .safe
                } else if let since = record?.verifyPendingSince, Date().timeIntervalSince(since) < PicPlaceSyncRecord.verifyWindow {
                    // Uploaded and confirmed; PicPlace still reading it back.
                    cloud = .checking
                } else {
                    cloud = .needsUploading
                }
            } else if originals == .there, blends != .nowhere {
                // Nothing heavy here, and PicPlace holds the project.
                cloud = .safe
            }
        }
        return HoldingsPillState(originals: originals, blends: blends, cloud: cloud)
    }

    /// Everything heavy here is verified on PicPlace — the heavy set's
    /// marker matches what is here now (an originals upload, the blends
    /// queue's whole look, the check before a removal: the digest of
    /// nothing once all of it left). With nothing heavy here and no
    /// marker, PicPlace holding the originals is what counts (a pull).
    nonisolated static func isBackedUp(_ record: PicPlaceSyncRecord, holdings: ProjectHoldings) -> Bool {
        if let marker = record.heavyDigest, marker == holdings.localHeavyDigest { return true }
        if holdings.localHeavyFiles == 0 { return (record.serverHeavyFiles ?? 0) > 0 }
        return false
    }
}

private struct HoldingsPillContent: View {
    @EnvironmentObject private var model: AppModel
    /// Observed for the records, a sync's or a download's progress.
    @ObservedObject var picplace: PicPlaceController
    /// Observed for the holdings, which land batch by batch as tiles appear.
    @ObservedObject var holdings: ProjectHoldingsStore
    let captureID: UUID

    var body: some View {
        let known = model.shownHoldings(for: captureID)
        let state = model.holdingsPillState(for: captureID, holdings: known)
        Group {
            if let state, !state.isEmpty {
                HoldingsPillBody(state: state)
            } else {
                // A fixed seat, drawn or not: the ask below always has a
                // view to run on.
                Color.clear.frame(width: 22, height: 18)
            }
        }
        .allowsHitTesting(false)
        // Asks again whenever the answer is dropped — a removal, a download
        // landing, a render — not only when the tile first appears (the
        // 11:32 tile that lost its badge after *Remove originals*).
        .task(id: HoldingsAsk(id: captureID, missing: model.cachedHoldings(for: captureID) == nil ? holdings.revision : nil)) {
            model.requestHoldings(captureID)
        }
        #if DEBUG
        // `LL_DUMP_PILLS=1`: every drawn pill's words as they change — the
        // device check of the mapping on a real library (2026-09-26).
        .onChange(of: state, initial: true) { _, now in
            guard HoldingsPillBody.dumps, let now else { return }
            LLog("pill: \(model.capture(id: captureID)?.displayTitle ?? "?") — \(HoldingsPillBody.label(now))")
        }
        #endif
    }
}

/// The pill as drawn — the project's, and a blend row's. Real size: 18 pt
/// high, 9 pt glyphs, the cloud a point larger.
struct HoldingsPillBody: View {
    let state: HoldingsPillState

    var body: some View {
        HStack(spacing: 3) {
            if let place = state.originals {
                StatusGlyphView(glyph: .asset(.originals, place), size: 9, surface: .photo)
            }
            if let place = state.blends {
                StatusGlyphView(glyph: .asset(.blends, place), size: 9, surface: .photo)
            }
            if state.originals != nil || state.blends != nil, state.cloud != nil {
                Rectangle()
                    .fill(Color.white.opacity(0.35))
                    .frame(width: 0.5, height: 10)
                    .padding(.horizontal, 1)
            }
            if let cloud = state.cloud {
                StatusGlyphView(glyph: .cloud(cloud), size: 10, surface: .photo)
            }
        }
        .padding(.horizontal, 5)
        .frame(minWidth: 22, minHeight: 18, maxHeight: 18)
        .background(Color.black.opacity(0.5), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.label(state))
    }

    /// Layers — a blend is frames laid over each other. Not `square.stack`,
    /// the Projects tab's own glyph. (The outline, where it is not a status:
    /// a filter's Has blends.)
    static let blendsGlyph = "square.3.layers.3d"

    #if DEBUG
    static let dumps = ProcessInfo.processInfo.environment["LL_DUMP_PILLS"] != nil
    #endif

    /// The pill in the Gallery's PicPlace filter names (plan §1b: one set
    /// of words for VoiceOver, the Mac's tooltips and the filters).
    static func label(_ state: HoldingsPillState) -> String {
        var parts: [String] = []
        switch state.originals {
        case .here?: parts.append("On this device")
        case .there?: parts.append("Download available")
        case .nowhere?: parts.append("Not available to download")
        case nil: break
        }
        switch state.blends {
        case .here?: parts.append("Blends on this device")
        case .there?: parts.append("Blends on PicPlace")
        case .nowhere?: parts.append("Blends not available")
        case nil: break
        }
        switch state.cloud {
        case .safe?: parts.append("Backed up")
        case .needsUploading?: parts.append("Needs uploading")
        case .uploading?: parts.append("Uploading")
        case .downloading?: parts.append("Downloading")
        case .checking?: parts.append("Checking with PicPlace")
        case .waiting?: parts.append("Upload waiting")
        case .attention?: parts.append("Needs attention")
        case nil: break
        }
        return parts.joined(separator: " · ")
    }
}

/// The pill's ask: again whenever the project's holdings are not known and
/// the store moves.
private struct HoldingsAsk: Hashable {
    var id: UUID
    var missing: Int?
}

// MARK: - One blend's pill

/// A blend row's pill (the project screen, the Gallery panel): the layers,
/// where the clip is | the cloud for it. Nothing in a library never
/// connected to PicPlace while the file is here (the norm).
struct BlendHoldingsPill: View {
    @EnvironmentObject private var model: AppModel
    let blend: AppModel.BlendProject

    var body: some View {
        BlendHoldingsPillContent(picplace: model.picplace, holdings: model.holdingsStore, blend: blend)
    }
}

private struct BlendHoldingsPillContent: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var picplace: PicPlaceController
    @ObservedObject var holdings: ProjectHoldingsStore
    let blend: AppModel.BlendProject

    var body: some View {
        let state = model.blendPillState(for: blend, holdings: model.shownHoldings(for: blend.captureID))
        Group {
            if !state.isEmpty { HoldingsPillBody(state: state) }
        }
        .allowsHitTesting(false)
        .task(id: HoldingsAsk(id: blend.captureID, missing: model.cachedHoldings(for: blend.captureID) == nil ? holdings.revision : nil)) {
            model.requestHoldings(blend.captureID)
        }
    }
}

extension AppModel {
    /// A blend's pill. Where: here, else PicPlace's answer for this clip
    /// (`blendAvailability`: its list once read, a count of none) — grey
    /// until it says no. The cloud, for a clip here: its own confirmed
    /// entry in PicPlace's list once read, else the markers (the whole set
    /// or every blend here verified); amber while its project moves.
    func blendPillState(for blend: BlendProject, holdings: ProjectHoldings?) -> HoldingsPillState {
        guard let capture = capture(for: blend) else { return .empty }
        let here = !blendFileMissing(blend)
        let connected = picplace.binding != nil
        if !connected, here { return .empty }
        let origin = originID(of: capture)
        let place: StatusGlyph.Place = here ? .here
            : picplace.blendAvailability(blend, of: capture) == .notOnPicPlace ? .nowhere : .there
        var cloud: StatusGlyph.Cloud?
        if connected {
            let progress = picplace.progress[capture.id]
            let record = picplace.records[origin]
            let known = record.map { $0.revision > 0 || $0.policy == "pull" } ?? false
            let pending = record?.verifyPendingSince.map { Date().timeIntervalSince($0) < PicPlaceSyncRecord.verifyWindow } ?? false
            let listed = picplace.serverHeavy[origin].map { $0.contains { $0.name == blend.outputFileName && $0.isConfirmed } }
            if !here, let progress, progress.phase == .downloading {
                cloud = .downloading
            } else if here, progress != nil, picplace.uploadStops[capture.id] != nil {
                cloud = .uploading
            } else if here {
                if let listed {
                    cloud = listed ? .safe : pending ? .checking : .needsUploading
                } else if known, let record, let holdings, Self.isBackedUp(record, holdings: holdings)
                            || (record.blendsDigest != nil && record.blendsDigest == holdings.localBlendsDigest) {
                    cloud = .safe
                } else {
                    cloud = pending ? .checking : .needsUploading
                }
            } else if listed == true {
                // Not here, and PicPlace holds it: safe, just not on this device.
                cloud = .safe
            }
        }
        return HoldingsPillState(originals: nil, blends: place, cloud: cloud)
    }
}

#if DEBUG
// MARK: - Every state, rendered on the device (`LL_PILL_SHEET=1`)

/// Every pill state on a bright and a dark ground, and the adaptive glyphs
/// on a light list — rendered by the device itself at its own scale into
/// `Logs/pill-sheet.png`, the size check no Mac drawing can make
/// (2026-09-26).
struct HoldingsPillSheet: View {
    static let states: [(String, HoldingsPillState)] = [
        ("Here · backed up", .init(originals: .here, cloud: .safe)),
        ("Here · needs uploading", .init(originals: .here, cloud: .needsUploading)),
        ("Preview only (removed here)", .init(originals: .there, cloud: .safe)),
        ("Just uploaded · PicPlace checking", .init(originals: .here, cloud: .checking)),
        ("Uploading", .init(originals: .here, cloud: .uploading)),
        ("All here · backed up", .init(originals: .here, blends: .here, cloud: .safe)),
        ("Blend on PicPlace", .init(originals: .here, blends: .there, cloud: .safe)),
        ("Uploading the blend", .init(originals: .here, blends: .here, cloud: .uploading)),
        ("New blend not up", .init(originals: .here, blends: .here, cloud: .needsUploading)),
        ("Checking", .init(originals: .here, cloud: .checking)),
        ("Not available", .init(originals: .nowhere, blends: .nowhere)),
        ("Waiting", .init(originals: .here, cloud: .waiting)),
        ("Needs attention", .init(originals: .here, cloud: .attention)),
        ("Downloading", .init(originals: .there, cloud: .downloading)),
        ("Photos on PicPlace · blend here", .init(originals: .there, blends: .here, cloud: .safe)),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Self.states.indices, id: \.self) { index in
                let (name, state) = Self.states[index]
                HStack(spacing: 10) {
                    Text(name).font(.system(size: 11)).frame(width: 170, alignment: .leading)
                    ground(Color(red: 0.91, green: 0.86, blue: 0.77), state)
                    ground(Color(red: 0.12, green: 0.12, blue: 0.14), state)
                }
            }
            HStack(spacing: 14) {
                ForEach(PicPlaceFilter.allCases) { filter in
                    StatusGlyphView(glyph: filter.statusGlyph, size: 14)
                }
            }
            .padding(.top, 8)
        }
        .padding(14)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }

    private func ground(_ colour: Color, _ state: HoldingsPillState) -> some View {
        ZStack(alignment: .bottomTrailing) {
            colour.frame(width: 96, height: 30)
            HoldingsPillBody(state: state).padding(6)
        }
    }

    /// Renders the sheet at the screen's scale into the logs folder.
    @MainActor static func renderToLogs() {
        let renderer = ImageRenderer(content: HoldingsPillSheet())
        #if os(iOS)
        renderer.scale = UIScreen.main.scale
        #else
        renderer.scale = 2
        #endif
        guard let image = renderer.cgImage else { LLog("pill sheet: could not render"); return }
        let url = StorageRoot.logsURL.appendingPathComponent("pill-sheet.png")
        try? FileManager.default.createDirectory(at: StorageRoot.logsURL, withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        LLog(CGImageDestinationFinalize(destination) ? "pill sheet: \(image.width)×\(image.height) at \(url.path)" : "pill sheet: could not write")
    }
}
#endif
