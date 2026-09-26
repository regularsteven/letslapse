import LetsLapseKit
import SwiftUI

// MARK: - A collection's clips on a device that may not hold them (2026-09-25)
//
// docs/connected-asset-states-plan.md, rule 4: a collection is made of blends
// — authored and rendered from their files, never the originals — on any
// device that holds them. A device that pulled the projects holds their
// blends' records and stills, and their files only once they come down. The
// builder keeps every member in place, shows its still, and asks before the
// work that needs the file: a play, a trim, an export (which failed whole on
// the first missing clip, late and generic).

extension AppModel {
    /// The members of `collection` whose clip file is not on this device.
    func missingBlends(in collection: LapseCollection) -> [BlendProject] {
        collection.entries.compactMap { blend(id: $0.blendID) }.filter { blendFileMissing($0) }
    }

    /// What bringing `blends` down weighs: the sizes `assets.ndjson`
    /// recorded when they were made (0 for one never recorded).
    func recordedBytes(of blends: [BlendProject]) -> Int64 {
        blends.reduce(0) { total, blend in
            guard let capture = capture(for: blend) else { return total }
            return total + (holdings(for: capture).blend(blend.id)?.bytes ?? 0)
        }
    }

    /// The picture that stands for a blend: its file's first frame when it
    /// is here, else its still (`posters/<id>.jpg`, made when it was pushed
    /// or removed), else nothing — and the kind to decode it as.
    func blendPicture(_ blend: BlendProject) -> (url: URL?, kind: MediaKind) {
        if !blendFileMissing(blend) { return (mediaURL(for: blend), mediaKind(for: blend)) }
        let still = blendPosterURL(for: blend)
        return (FileManager.default.fileExists(atPath: still.path) ? still : nil, .image)
    }
}

extension PicPlaceController {
    /// What PicPlace can do about `blends`: the first project's answer that
    /// is not a download, else a download.
    func fetchOffer(forBlends blends: [AppModel.BlendProject]) -> FetchOffer {
        for (captureID, group) in Dictionary(grouping: blends, by: \.captureID) {
            guard let capture = model.capture(id: captureID) else { return .unavailable }
            let holdings = model.holdings(for: capture)
            guard let shortfall = holdings.shortfall(for: .blends(Set(group.map(\.id)))) else { continue }
            let offer = fetchOffer(for: capture, shortfall: shortfall)
            if offer != .download { return offer }
        }
        return .download
    }

    /// Brings `blends` down — one download per project, each blend by name.
    /// Returns how many downloads started.
    @discardableResult
    func fetchBlends(_ blends: [AppModel.BlendProject]) -> Int {
        var started = 0
        for (captureID, group) in Dictionary(grouping: blends, by: \.captureID) {
            guard let capture = model.capture(id: captureID), canSync, syncTasks[captureID] == nil,
                  !removingProjects.contains(captureID) else { continue }
            downloadOriginals(capture, kinds: [.blend], only: Set(group.map(\.outputFileName)))
            if syncTasks[captureID] != nil { started += 1 }
        }
        return started
    }

    /// What bringing `blends` down weighs: the size `assets.ndjson` recorded
    /// for each, else the size PicPlace's own list gives (once a card or the
    /// banner has read it) — so a blend made before its size was recorded
    /// still has one.
    func bytes(of blends: [AppModel.BlendProject]) -> Int64 {
        blends.reduce(0) { total, blend in
            let recorded = model.recordedBytes(of: [blend])
            if recorded > 0 { return total + recorded }
            guard let capture = model.capture(for: blend) else { return total }
            let remote = serverHeavy[model.originID(of: capture)]?.first { $0.name == blend.outputFileName }
            return total + (remote?.bytes ?? 0)
        }
    }

    /// True while any of `blends`' projects is downloading.
    func isDownloading(_ blends: [AppModel.BlendProject]) -> Bool {
        Set(blends.map(\.captureID)).contains { progress[$0]?.phase == .downloading }
    }
}

/// The builder's question about clips that are on PicPlace, not here.
struct ClipsPrompt: Identifiable {
    let id = UUID()
    /// What asked — "Exporting", "Playing the clip", "Trimming the clip".
    var subject: String
    var blendIDs: [UUID]
    var bytes: Int64
    var offer: PicPlaceController.FetchOffer
    /// Export once they are here.
    var thenExport: Bool

    private var count: Int { blendIDs.count }
    private var clips: String { count == 1 ? "this clip" : "\(count) clips" }

    var title: String {
        switch offer {
        case .download: return "Download \(clips)?"
        case .downloading: return "Downloading \(clips)"
        case .signIn: return "Sign in to PicPlace?"
        case .connect: return "This library isn't connected"
        case .notUploaded, .unavailable: return count == 1 ? "This clip isn't here" : "\(count) clips aren't here"
        }
    }

    @MainActor var message: String {
        let size = bytes > 0 ? " · \(LLFormat.bytes(bytes))" : ""
        let needs = "\(subject) needs \(count == 1 ? "the clip" : "every clip")"
        switch offer {
        case .download:
            return "\(needs) — \(count == 1 ? "it's" : "\(count) are") on PicPlace\(size). You can keep working while \(count == 1 ? "it downloads" : "they download")."
        case .downloading:
            return "\(needs); \(count == 1 ? "it's" : "they're") on the way."
        case .signIn:
            return "\(needs), and \(count == 1 ? "it's" : "they're") on PicPlace — sign in to download \(count == 1 ? "it" : "them")."
        case .connect:
            return "\(needs), on PicPlace. Connect this library to your PicPlace account in Settings to download \(count == 1 ? "it" : "them")."
        case .notUploaded(let device):
            return "\(needs). \(count == 1 ? "It's" : "They're") only on \(device ?? "the device that made \(count == 1 ? "it" : "them")") so far — once uploaded from there, \(count == 1 ? "it" : "they") can come down here."
        case .unavailable:
            return "\(needs), and \(count == 1 ? "it isn't" : "they aren't") on \(PicPlaceController.deviceWord) or on PicPlace."
        }
    }
}
