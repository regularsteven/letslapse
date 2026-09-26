import LetsLapseKit
import SwiftUI

// MARK: - The holdings pill (2026-09-25, Direction B)
//
// docs/connected-asset-states-plan.md §4.3. One pill, two halves, on every
// Gallery tile, Projects card and Mac filmstrip tile — Steven's four states
// on the left, PicPlace on the right:
//
//   left — on this device   (nothing)  the project only: records + preview (a)
//                           camera     every original (b) — a Photo
//                                      capture's picture is its original
//                           layers     blends (c)
//                           camera layers  both (d)
//                           ring       the originals coming down
//                           triangle   the originals are neither here nor
//                                      on PicPlace
//   right — PicPlace        (nothing)  not there
//                           cloud      there — records at least
//                           cloud ✓    everything heavy here is verified
//                                      there (`heavyDigest`); with nothing
//                                      heavy here, PicPlace holds the
//                                      originals
//                           cloud ↑    sending now (amber)
//                           cloud !    a sync failed (the failure tint)
//
// No glyph appears twice: content on the left, clouds on the right. In a
// library never connected to PicPlace the pill shows only what is not the
// norm — layers, a triangle — or every tile there would carry a camera.
// Drawn in the PicPlace pill's dress (18 high, black at 50 %).

/// A project's holdings pill.
struct HoldingsPill: View {
    @EnvironmentObject private var model: AppModel
    let captureID: UUID

    var body: some View {
        HoldingsPillContent(picplace: model.picplace, holdings: model.holdingsStore, captureID: captureID)
    }
}

/// What the pill says, read from the holdings and the PicPlace record.
struct HoldingsPillState: Equatable {
    enum Here: Equatable {
        case nothing
        case originals
        case blends
        case both
        case downloading(Double)
        case missing
    }
    enum Cloud: Equatable {
        case none
        case onPicPlace
        case backedUp
        case sending
        case failed
    }
    var here: Here
    var cloud: Cloud

    static let empty = HoldingsPillState(here: .nothing, cloud: .none)
    var isEmpty: Bool { self == .empty }
}

extension AppModel {
    /// The pill's state for a project — nil until its holdings are known
    /// (the pill keeps its seat and asks).
    func holdingsPillState(for captureID: UUID, holdings: ProjectHoldings?) -> HoldingsPillState? {
        guard let capture = capture(id: captureID) else { return nil }
        let connected = picplace.binding != nil
        let origin = originID(of: capture)
        let record = picplace.records[origin]
        let progress = picplace.progress[captureID]

        // Right: PicPlace — what the Projects pill said, split: a record
        // there is a cloud; verified originals turn it green. Not
        // `listState`, which stats the folder on every draw.
        var cloud = HoldingsPillState.Cloud.none
        if connected {
            let failed = picplace.conflicts.contains { $0.originID == origin }
                || (picplace.canSync && record?.lastError != nil)
            if failed {
                cloud = .failed
            } else if let progress, progress.phase != .downloading {
                cloud = .sending
            } else if let record, record.revision > 0 || record.policy == "pull" {
                cloud = .onPicPlace
                if let holdings, Self.isBackedUp(record, holdings: holdings) { cloud = .backedUp }
            }
        }

        // Left: this device.
        if let progress, progress.phase == .downloading {
            return HoldingsPillState(here: .downloading(progress.fraction), cloud: cloud)
        }
        guard let holdings else { return cloud == .none ? nil : HoldingsPillState(here: .nothing, cloud: cloud) }
        let originals = holdings.tier == .originals
        let blends = holdings.otherBlendsHere > 0
        var here: HoldingsPillState.Here
        switch (originals, blends) {
        case (true, true): here = .both
        case (true, false): here = .originals
        case (false, true): here = .blends
        case (false, false): here = .nothing
        }
        if here == .nothing, cloud == .none || cloud == .failed, record.map({ $0.revision > 0 || $0.policy == "pull" }) != true {
            // Neither here nor accounted for by PicPlace — gone.
            here = .missing
        }
        // Unconnected: the norm (every original here) says nothing.
        if !connected, here == .originals || here == .both {
            here = here == .both ? .blends : .nothing
        }
        return HoldingsPillState(here: here, cloud: cloud)
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
    }
}

/// The pill as drawn — the project's, and a blend row's.
struct HoldingsPillBody: View {
    let state: HoldingsPillState

    var body: some View {
        HStack(spacing: 3) {
            leftHalf(state.here)
            if state.here != .nothing, state.cloud != .none {
                Rectangle()
                    .fill(Color.white.opacity(0.35))
                    .frame(width: 0.5, height: 10)
                    .padding(.horizontal, 1)
            }
            rightHalf(state.cloud)
        }
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(Color.white.opacity(0.85))
        .padding(.horizontal, 5)
        .frame(minWidth: 22, minHeight: 18, maxHeight: 18)
        .background(Color.black.opacity(0.5), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.label(state))
    }

    @ViewBuilder private func leftHalf(_ here: HoldingsPillState.Here) -> some View {
        switch here {
        case .nothing:
            EmptyView()
        case .originals:
            Image(systemName: "camera")
        case .blends:
            Image(systemName: Self.blendsGlyph)
        case .both:
            Image(systemName: "camera")
            Image(systemName: Self.blendsGlyph)
        case .downloading(let fraction):
            ring(fraction)
        case .missing:
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(LL.levelOff)
        }
    }

    @ViewBuilder private func rightHalf(_ cloud: HoldingsPillState.Cloud) -> some View {
        switch cloud {
        case .none:
            EmptyView()
        case .onPicPlace:
            Image(systemName: "icloud")
        case .backedUp:
            Image(systemName: "checkmark.icloud")
                .foregroundStyle(.green)
        case .sending:
            Image(systemName: "icloud.and.arrow.up")
                .foregroundStyle(LL.amber)
        case .failed:
            Image(systemName: "exclamationmark.icloud")
                .foregroundStyle(LL.levelOff)
        }
    }

    private func ring(_ fraction: Double) -> some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.25), lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0.04, fraction))
                .stroke(LL.amber, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 10, height: 10)
    }

    /// Layers — a blend is frames laid over each other. Not `square.stack`,
    /// the Projects tab's own glyph.
    static let blendsGlyph = "square.3.layers.3d"

    /// The pill in the Gallery's PicPlace filter names (plan §1b: one set
    /// of words for VoiceOver, the Mac's tooltips and the filters).
    static func label(_ state: HoldingsPillState) -> String {
        var parts: [String] = []
        let originalsHere = state.here == .originals || state.here == .both
        switch state.here {
        case .originals: parts.append("On this device")
        case .both: parts.append("On this device"); parts.append("Blends on this device")
        case .blends: parts.append("Blends on this device")
        case .downloading: parts.append("Downloading")
        case .missing, .nothing: break
        }
        switch state.cloud {
        case .failed: parts.append("Needs attention")
        case .sending: parts.append("Uploading")
        case .backedUp: parts.append(originalsHere ? "Backed up" : "Download available")
        case .onPicPlace: parts.append(originalsHere ? "Needs uploading" : "Not available to download")
        case .none:
            if originalsHere {
                parts.append("Needs uploading")
            } else if state.here == .missing {
                parts.append("Not available to download")
            }
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

/// A blend row's pill (the project screen, the Gallery panel): layers when
/// the clip's file is here | PicPlace — the project pill's halves for one
/// clip. Nothing in a library never connected to PicPlace while the file
/// is here (the norm).
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
    /// A blend's pill: layers when its file is here; PicPlace's half from
    /// its own confirmed entry in PicPlace's list once read (`serverHeavy`),
    /// else from the markers — the whole set or every blend here verified.
    /// A clip that is not here, before the list is read, claims nothing —
    /// unless PicPlace's count says it holds none of the project's heavy
    /// files: *not available* (`blendAvailability`; it used to claim "On
    /// PicPlace" for a blend never uploaded, 2026-09-26).
    func blendPillState(for blend: BlendProject, holdings: ProjectHoldings?) -> HoldingsPillState {
        guard let capture = capture(for: blend) else { return .empty }
        let here = !blendFileMissing(blend)
        let connected = picplace.binding != nil
        let origin = originID(of: capture)
        var cloud = HoldingsPillState.Cloud.none
        var unknown = false
        if connected, let record = picplace.records[origin], record.revision > 0 || record.policy == "pull" {
            if let listed = picplace.serverHeavy[origin] {
                if let asset = listed.first(where: { $0.name == blend.outputFileName && $0.isConfirmed }) {
                    cloud = asset.isVerified ? .backedUp : .onPicPlace
                }
            } else if here, let holdings,
                      Self.isBackedUp(record, holdings: holdings)
                        || (record.blendsDigest != nil && record.blendsDigest == holdings.localBlendsDigest) {
                cloud = .backedUp
            } else if !here {
                unknown = picplace.blendAvailability(blend, of: capture) == .unknown
            }
        }
        var left: HoldingsPillState.Here = here ? .blends : .nothing
        if !here, let progress = picplace.progress[capture.id], progress.phase == .downloading {
            left = .downloading(progress.fraction)
        } else if !here, cloud == .none, !unknown {
            left = .missing
        }
        if !connected, here { left = .nothing }
        return HoldingsPillState(here: left, cloud: cloud)
    }
}
