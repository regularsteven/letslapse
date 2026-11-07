import Foundation
import LetsLapseKit

// MARK: - Approved assets on PicPlace (2026-11-05, docs/approved-assets.md)
//
// An approval needs nothing new from the server to travel:
//
// - the approval itself is fields of `project.json` — `capture.approvedAt` /
//   `approvedFile`, `blends[].approvedAt` — and `project.json` is the
//   manifest every records push PUTs. The approval is an edit, so the push
//   queue sends it like any other;
// - the file it stands on is a `source/` or a `blends/` file, which the
//   existing uploads carry by hash under the existing kinds.
//
// What an approval adds is the wish to have that file there: an approved
// output goes up whatever *Upload blends automatically* says (the blends
// queue, `runBlendsQueue`), and an approved source — a stock clip, an
// untouched photo — goes up as the project's own Upload would send it, a
// job that waits for Wi-Fi and survives a relaunch (this file).
//
// Removing an approved file from this device is the card's Remove, as for
// any blend or original: PicPlace keeps its copy. Deleting an approved clip
// tombstones it in the manifest; its file on PicPlace is not deleted.

extension PicPlaceController {

    /// A person approved something of `id`, or an approved picture's file
    /// was made again. The records go by the push queue; this asks for the
    /// file.
    func noteApprovalChanged(_ id: UUID) {
        guard canSync else { return }
        // The blends queue is not fresh: an approval moved the index.
        scheduleBlendsQueue(force: true)
        queueApprovedSourceUploads()
    }

    /// Every project whose approved file is one of its originals, and whose
    /// originals PicPlace does not hold as this device has them, gets an
    /// upload job — the card's Upload, started by the app. Skipped until
    /// the project's records are there and in step (the push goes first),
    /// while a transfer of it is running, and when its job is already
    /// waiting. Called after a check and after pushes are sent; cheap when
    /// nothing is approved (one indexed read).
    func queueApprovedSourceUploads() {
        guard heavyChecksAllowed, !isShutDown, let index = model.libraryIndex else { return }
        var query = LibraryIndex.ProjectQuery()
        query.approved = true
        query.limit = 100_000
        var queued: [String] = []
        for row in (try? index.projects(query).rows) ?? [] {
            guard let capture = model.capture(id: row.id), capture.deletedAt == nil, capture.approvedAt != nil,
                  let file = capture.approvedFile, file.hasPrefix("source/") else { continue }
            let origin = model.originID(of: capture)
            guard let record = records[origin], record.recordsReachedServer, record.elsewhereLibrary == nil,
                  record.revision == revision(of: capture) else { continue }
            guard uploadJobs[capture.id] == nil, syncTasks[capture.id] == nil,
                  !removingProjects.contains(capture.id) else { continue }
            // Nothing here to send: a preview, or originals already removed
            // from this device (which only happens once PicPlace has them).
            guard !model.sourcesMissing(capture) else { continue }
            guard !AppModel.isBackedUp(record, holdings: model.holdings(for: capture)) else { continue }
            var job = PicPlaceUploadJob()
            job.startedAt = Date().addingTimeInterval(Double(queued.count) * 0.001)
            uploadJobs[capture.id] = job
            queued.append(capture.displayTitle)
        }
        guard !queued.isEmpty else { return }
        saveUploadJobs()
        LLog("picplace: approved — queued the originals of \(queued.count) project(s) whose source is approved: \(queued.joined(separator: ", "))")
        // Not a person's press: no continued task is asked of iOS.
        startNextUploadJob()
    }
}
