import Foundation
import LetsLapseKit

// MARK: - Fetching what a capability is short of (2026-09-25)
//
// docs/connected-asset-states-plan.md §4.2. A greyed control asks the
// model what it is short of (`AppModel.availability(of:for:)`); this says
// whether PicPlace can supply it, and starts the download that does. The
// just-in-time prompt and the preview page's line read the offer; the
// download itself is the card's (`downloadOriginals(_:kinds:only:)`) — the
// same run, the same progress, the same Cancel.

extension PicPlaceController {

    /// What PicPlace can do about a shortfall.
    enum FetchOffer: Equatable {
        /// Signed in, connected, and PicPlace holds the files (or has not
        /// said otherwise yet): *Download and Continue*.
        case download
        /// A download of this project is already under way — or an import
        /// from a nearby device (`progress.source` names it).
        case downloading(PicPlaceSyncProgress)
        /// A device of this account on the same network holds all of it
        /// (docs/nearby-originals-plan.md): *Import and Continue*, ahead of
        /// PicPlace (N12) — `alsoOnPicPlace` when PicPlace could supply it
        /// too, the prompt's second button.
        case nearby(NearbyOffer, alsoOnPicPlace: Bool)
        /// The files are on PicPlace, and this device is signed out.
        case signIn
        /// Signed in, but this library is not connected to the account.
        case connect
        /// PicPlace knows the project but holds none of these files — they
        /// are still only on the device that made them (named when PicPlace
        /// said which).
        case notUploaded(device: String?)
        /// Not on PicPlace at all: the files are simply not here.
        case unavailable
    }

    /// Whether PicPlace can bring a blend that is not here down to this
    /// device. Its list for the project, once read, is the answer; before
    /// that, a count of none of the project's heavy files says no; anything
    /// else is not known yet — and claimed neither way (2026-09-26: the 18
    /// Pro offered *Victory Bridge Sunset*'s blend, never uploaded, four
    /// times; each Download found nothing).
    enum BlendAvailability { case onPicPlace, notOnPicPlace, unknown }

    func blendAvailability(_ blend: AppModel.BlendProject, of capture: AppModel.CaptureProject) -> BlendAvailability {
        let key = model.originID(of: capture)
        guard let record = records[key], record.revision > 0 || record.policy == "pull" else { return .notOnPicPlace }
        if let remote = serverHeavy[key] {
            return remote.contains { $0.isConfirmed && $0.name == blend.outputFileName } ? .onPicPlace : .notOnPicPlace
        }
        if record.serverHeavyFiles == 0 { return .notOnPicPlace }
        return .unknown
    }

    /// PicPlace's list for a project a view shows something of that is not
    /// here — read at most once a minute per project (`refreshProject`), so
    /// the rows and prompts can say what PicPlace really holds.
    func askForListing(_ captureID: UUID) {
        guard canSync, let capture = model.capture(id: captureID) else { return }
        let key = model.originID(of: capture)
        if let asked = listingAskedAt[key], Date().timeIntervalSince(asked) < 60 { return }
        listingAskedAt[key] = Date()
        refreshProject(captureID)
    }

    /// Whether a device nearby or PicPlace can supply `shortfall` for
    /// `capture` — a nearby device first (N12).
    func fetchOffer(for capture: AppModel.CaptureProject, shortfall: ProjectHoldings.Shortfall) -> FetchOffer {
        if let progress = progress[capture.id], progress.phase == .downloading { return .downloading(progress) }
        let key = model.originID(of: capture)
        // On PicPlace: pulled from it, or pushed there at least once (a
        // later push that failed leaves the earlier one in place). The
        // nearby channel serves only such projects too (N2).
        guard let record = records[key], record.revision > 0 || record.policy == "pull" else { return .unavailable }
        let fromPicPlace = picplaceOffer(for: capture, record: record, shortfall: shortfall)
        if let nearby = model.nearby.offer(for: capture, shortfall: shortfall) {
            return .nearby(nearby, alsoOnPicPlace: fromPicPlace == .download)
        }
        return fromPicPlace
    }

    /// What PicPlace alone can do about the shortfall.
    private func picplaceOffer(for capture: AppModel.CaptureProject, record: PicPlaceSyncRecord,
                               shortfall: ProjectHoldings.Shortfall) -> FetchOffer {
        let key = model.originID(of: capture)
        guard isSignedIn else { return .signIn }
        guard canSync else { return .connect }
        // PicPlace's own list, when the card has read it (`refreshProject`,
        // which the preview page asks for as it appears): every file short
        // must be there, confirmed. Until then the offer stands — a
        // download that finds nothing says so. No request from here: this
        // is read from view bodies.
        if let remote = serverHeavy[key] {
            let there = Set(remote.filter(\.isConfirmed).map(\.name))
            let wanted = shortfall.fileNames
            // A converted clip lists every encoding; one of them will do.
            let covered = shortfall.originals.allSatisfy { name in
                wanted.contains(name) ? (there.contains(name) || model.capture(id: capture.id).map {
                    model.encodings(for: $0, clip: name).contains { there.contains($0.fileName) }
                } ?? false) : true
            } && shortfall.blendIDs.allSatisfy { id in
                model.blends(for: capture).first { $0.id == id }.map { there.contains($0.outputFileName) } ?? false
            }
            if !covered {
                return .notUploaded(device: record.originalsHolder)
            }
        } else if record.serverHeavyFiles == 0 {
            // Its count from the last read: PicPlace holds none of this
            // project's heavy files, so nothing short can come down.
            return .notUploaded(device: record.originalsHolder)
        }
        return .download
    }

    /// Starts what fills `shortfall`: the import from a device nearby when
    /// one offers it (N12), else the download of the originals, the blends
    /// named, or both — a person's press, so on any network, as every
    /// download is. `fromPicPlace` skips the nearby device (the prompt's
    /// *Download from PicPlace*). Returns false when nothing could start (a
    /// sync or a removal of this project is running).
    @discardableResult
    func fetch(_ capture: AppModel.CaptureProject, shortfall: ProjectHoldings.Shortfall, fromPicPlace: Bool = false) -> Bool {
        guard canSync, syncTasks[capture.id] == nil, !removingProjects.contains(capture.id) else { return false }
        if !fromPicPlace, let offer = model.nearby.offer(for: capture, shortfall: shortfall) {
            importNearby(capture, shortfall: shortfall, from: offer)
            return syncTasks[capture.id] != nil
        }
        var kinds: Set<PicPlaceOriginalsCheck.Kind> = []
        if shortfall.needsOriginals { kinds.insert(.source) }
        if shortfall.needsBlends { kinds.insert(.blend) }
        // Blends alone come by name; the originals come as a kind, so a
        // clip's other encodings and any frame missed before come too.
        let only: Set<String>? = shortfall.needsOriginals ? nil
            : Set(model.blends(for: capture).filter { shortfall.blendIDs.contains($0.id) }.map(\.outputFileName))
        downloadOriginals(capture, kinds: kinds, only: only)
        return syncTasks[capture.id] != nil
    }
}

extension PicPlaceController {
    /// The import from a nearby device (docs/nearby-originals-plan.md §7):
    /// the same task slot, progress and Stop as a download, so the preview
    /// page, the drawer and *Continue When Ready* follow it unchanged, and
    /// the same ending — `noteOriginalsArrived`, the presence tier.
    func importNearby(_ capture: AppModel.CaptureProject, shortfall: ProjectHoldings.Shortfall, from offer: NearbyOffer) {
        guard syncTasks[capture.id] == nil else { return }
        let key = model.originID(of: capture)
        removalNotes[capture.id] = nil
        progress[capture.id] = PicPlaceSyncProgress(phase: .downloading, source: offer.deviceName)
        syncTasks[capture.id] = Task {
            // A person's press, like every download: iOS is asked to hold
            // the app while it runs. The other device has to stay open.
            let activity = PicPlaceBackgroundActivity(
                "Nearby import of \(capture.displayTitle)",
                continued: .init(title: "Importing “\(capture.displayTitle)”", subtitle: "From \(offer.deviceName)")
            ) {
                self.syncTasks[capture.id]?.cancel()
            }
            transferActivities[capture.id] = activity
            defer {
                activity.end()
                transferActivities[capture.id] = nil
            }
            do {
                _ = try await model.nearby.importFiles(capture: capture, shortfall: shortfall, from: offer) { snapshot in
                    self.progress[capture.id] = snapshot
                    self.transferActivities[capture.id]?.report(snapshot)
                }
                if var record = records[key] {
                    record.originalsMovedAt = Date()
                    records[key] = record
                }
                summaries[capture.id] = nil
                model.noteOriginalsArrived(for: capture.id)
                refreshHeavyListing(for: capture)
                // PicPlace's presence says what this device holds now — the
                // record other devices' "only on …" lines read.
                if let record = records[key] {
                    let tier = model.presenceTier(for: capture)
                    let _: [String: [PPPresence]]? = try? await client.post("projects/\(key.uuidString.lowercased())/presence",
                                                                             json: ["revision": record.revision, "tier": tier])
                }
            } catch {
                // Stopped or refused: what landed stays (and is recorded);
                // the service keeps the sentence for the page's line.
                model.noteOriginalsArrived(for: capture.id)
            }
            saveSyncState()
            progress[capture.id] = nil
            syncTasks[capture.id] = nil
        }
    }
}
