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
        /// A download of this project is already under way.
        case downloading(PicPlaceSyncProgress)
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

    /// Whether PicPlace can supply `shortfall` for `capture`.
    func fetchOffer(for capture: AppModel.CaptureProject, shortfall: ProjectHoldings.Shortfall) -> FetchOffer {
        if let progress = progress[capture.id], progress.phase == .downloading { return .downloading(progress) }
        let key = model.originID(of: capture)
        // On PicPlace: pulled from it, or pushed there at least once (a
        // later push that failed leaves the earlier one in place).
        guard let record = records[key], record.revision > 0 || record.policy == "pull" else { return .unavailable }
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
                return .notUploaded(device: record.alsoOn.first)
            }
        } else if record.serverHeavyFiles == 0 {
            // Its count from the last read: PicPlace holds none of this
            // project's heavy files, so nothing short can come down.
            return .notUploaded(device: record.alsoOn.first)
        }
        return .download
    }

    /// Starts the download that fills `shortfall`: the originals, the
    /// blends named, or both — a person's press, so on any network, as every
    /// download is. Returns false when one could not start (a sync or a
    /// removal of this project is running).
    @discardableResult
    func fetch(_ capture: AppModel.CaptureProject, shortfall: ProjectHoldings.Shortfall) -> Bool {
        guard canSync, syncTasks[capture.id] == nil, !removingProjects.contains(capture.id) else { return false }
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
