import Foundation
import LetsLapseKit

/// A person's Upload of one project's originals, kept as a job
/// (2026-09-24). Before it, an upload was one run that confirmed every file
/// with PicPlace at the very end: a phone leaving the Wi-Fi, a locked
/// screen, a Cancel at 90 % — and the next Upload sent all 11.55 GB again.
///
/// Now the run confirms files as they finish (`PicPlaceSyncRun`, eight at a
/// time) and stops between files when asked, so any stop costs only the
/// files in flight; the job is what remembers that the person wants the
/// rest sent. It waits for Wi-Fi when *Only on Wi-Fi* is on — a person's
/// Upload obeys it too, since that switch is how they say "don't use my
/// data" — unless they said *Use mobile data* for this job, which is never
/// a setting. Kept in the library's sync state, so a relaunch carries on.
struct PicPlaceUploadJob: Codable, Equatable {
    enum Hold: String, Codable {
        /// Pause — on the card, in Project Syncing, or Pause for all sending.
        case paused
        /// *Only on Wi-Fi* is on and this device is on mobile data.
        case waitingForWiFi
        /// The connection dropped, PicPlace was busy, or iOS was about to
        /// suspend the app: goes again on its own.
        case interrupted
        /// PicPlace refused something a retry would not fix; Resume tries again.
        case failed
    }

    /// Nil while it runs, or while it waits to (the session, the launch).
    var hold: Hold?
    /// *Use mobile data* for this job alone — *Only on Wi-Fi* holds it otherwise.
    var allowsMobileData = false
    /// Where the last run got to — the card's line while it waits.
    var filesDone = 0
    var filesTotal = 0
    var bytesDone: Int64 = 0
    var bytesTotal: Int64 = 0
    /// What stopped it, for `.interrupted` and `.failed`.
    var lastError: String?
    var startedAt = Date()

    /// "132 of 260 files · 5.8 GB of 11.55 GB"; nil before a run has counted.
    var counts: String? {
        guard filesTotal > 0 else { return nil }
        return "\(filesDone.formatted()) of \(filesTotal.formatted()) files · \(LLFormat.bytes(bytesDone)) of \(LLFormat.bytes(bytesTotal))"
    }

    var fraction: Double {
        guard bytesTotal > 0 else { return 0 }
        return min(1, Double(bytesDone) / Double(bytesTotal))
    }
}

extension PicPlaceController {

    /// How a job's run ended.
    enum UploadRunOutcome {
        case done
        /// Stopped between files on request — the hold says whose.
        case paused
        case interrupted(String?)
        case failed(String)
    }

    /// One row of the Project Syncing drawer's uploads.
    struct UploadJobRow: Identifiable {
        let id: UUID
        let title: String
        let job: PicPlaceUploadJob
        /// The run's live progress while it runs.
        let progress: PicPlaceSyncProgress?
        var isRunning: Bool { progress != nil }
    }

    var uploadJobRows: [UploadJobRow] {
        uploadJobs.compactMap { id, job in
            model.capture(id: id).map {
                UploadJobRow(id: id, title: $0.displayTitle, job: job, progress: syncTasks[id] != nil ? progress[id] : nil)
            }
        }
        .sorted { $0.job.startedAt < $1.job.startedAt }
    }

    func isUploading(_ id: UUID) -> Bool {
        uploadJobs[id] != nil && syncTasks[id] != nil
    }

    /// Whether *Only on Wi-Fi* holds a job right now.
    func networkHolds(_ job: PicPlaceUploadJob) -> Bool {
        wifiOnly && !isOnWiFi && !job.allowsMobileData
    }

    // MARK: A person's presses

    /// The card's Upload: a job for this project's originals and blends —
    /// or the one waiting, again. On mobile data with *Only on Wi-Fi* on it
    /// waits, and the card offers *Use mobile data*.
    func uploadOriginals(_ capture: AppModel.CaptureProject) {
        var job = uploadJobs[capture.id] ?? PicPlaceUploadJob()
        job.hold = nil
        job.lastError = nil
        setJob(job, for: capture.id)
        startUploadJob(capture.id, reason: "Upload")
    }

    /// Pause: the run stops between files; what reached PicPlace stays, and
    /// Resume sends the rest.
    func pauseUpload(_ id: UUID) {
        guard var job = uploadJobs[id] else { return }
        job.hold = .paused
        setJob(job, for: id)
        cancelUploadRetry(id)
        if let stop = uploadStops[id], syncTasks[id] != nil {
            stop.request()
            LLog("picplace: upload of \(title(of: id)) — pausing between files")
        }
    }

    func resumeUpload(_ id: UUID) {
        guard var job = uploadJobs[id] else { return }
        job.hold = nil
        job.lastError = nil
        setJob(job, for: id)
        startUploadJob(id, reason: "Resume")
    }

    /// *Use mobile data* — for this job alone, never the setting.
    func allowMobileData(forUpload id: UUID) {
        guard var job = uploadJobs[id] else { return }
        job.allowsMobileData = true
        job.hold = nil
        job.lastError = nil
        setJob(job, for: id)
        LLog("picplace: upload of \(title(of: id)) may use mobile data")
        startUploadJob(id, reason: "mobile data allowed")
    }

    /// Cancel: the job goes. What already reached PicPlace stays there — it
    /// was confirmed as it went — so an Upload later sends only the rest.
    func cancelUpload(_ id: UUID) {
        cancelUploadRetry(id)
        if let stop = uploadStops[id], syncTasks[id] != nil {
            cancelledUploads.insert(id)
            stop.request()
        } else {
            setJob(nil, for: id)
        }
        LLog("picplace: upload of \(title(of: id)) cancelled")
    }

    // MARK: Running

    /// Starts a job's run unless something holds it: already running, not
    /// signed in (the launch resumes it), or the Wi-Fi rule.
    func startUploadJob(_ id: UUID, reason: String) {
        guard var job = uploadJobs[id], syncTasks[id] == nil, !isShutDown else { return }
        guard let capture = model.capture(id: id) else {
            // The project is gone; so is the job.
            setJob(nil, for: id)
            return
        }
        guard canSync else { return }
        if networkHolds(job) {
            if job.hold != .waitingForWiFi {
                job.hold = .waitingForWiFi
                setJob(job, for: id)
                LLog("picplace: upload of \(capture.displayTitle) waits for Wi-Fi (\(reason))")
            }
            return
        }
        cancelUploadRetry(id)
        if job.hold != nil || job.lastError != nil {
            job.hold = nil
            job.lastError = nil
            setJob(job, for: id)
        }
        LLog("picplace: upload of \(capture.displayTitle) — \(reason)\(job.filesDone > 0 ? " (\(job.filesDone) of \(job.filesTotal) files sent before)" : "")")
        if !syncUploadJob(capture) {
            // Another transfer of this project (a removal) holds it: the
            // next launch, foreground or network change tries again.
            job.hold = .interrupted
            setJob(job, for: id)
        }
    }

    /// A job's run has ended (called before its progress is cleared): the
    /// job is dropped, or holds with where it got to.
    func noteUploadRunEnded(_ id: UUID, outcome: UploadRunOutcome) {
        guard var job = uploadJobs[id] else { cancelledUploads.remove(id); return }
        let before = job.filesDone
        if let progress = progress[id], progress.filesTotal > 0 {
            job.filesDone = progress.filesDone
            job.filesTotal = progress.filesTotal
            job.bytesDone = progress.bytesDone
            job.bytesTotal = progress.bytesTotal
        }
        if cancelledUploads.remove(id) != nil {
            setJob(nil, for: id)
            return
        }
        switch outcome {
        case .done:
            LLog("picplace: upload of \(title(of: id)) finished — \(job.filesTotal) files")
            uploadRetryCounts[id] = nil
            setJob(nil, for: id)
            return
        case .paused:
            // The hold is whoever asked: the person, the Wi-Fi rule, iOS.
            LLog("picplace: upload of \(title(of: id)) \(job.hold == .waitingForWiFi ? "waits for Wi-Fi" : job.hold == .interrupted ? "stopped for the background" : "paused") at \(job.counts ?? "the start")")
        case .interrupted(let message):
            if job.hold != .paused && job.hold != .waitingForWiFi {
                job.hold = .interrupted
                job.lastError = message
            }
            // Progress this run resets the backoff; a run that got nowhere lengthens it.
            if job.filesDone > before { uploadRetryCounts[id] = nil }
        case .failed(let message):
            if job.hold != .paused {
                job.hold = .failed
                job.lastError = message
            }
        }
        setJob(job, for: id)
    }

    /// After the run's task has cleared: a job resumed while it was
    /// stopping starts again; an interrupted one tries again after a while.
    func followUpUploadJob(_ id: UUID) {
        guard let job = uploadJobs[id], syncTasks[id] == nil else { return }
        switch job.hold {
        case nil:
            startUploadJob(id, reason: "Resume")
        case .interrupted?:
            scheduleUploadRetry(id)
        default:
            break
        }
    }

    /// Jobs that may go again on their own — at launch, in front again,
    /// when the network changes. A paused or refused job waits for its
    /// person; Pause for all sending holds every one.
    func resumeUploadJobs(reason: String) {
        guard !isShutDown, canSync, !sendsPaused else { return }
        for (id, job) in uploadJobs where syncTasks[id] == nil {
            switch job.hold {
            case nil, .interrupted?, .waitingForWiFi?:
                startUploadJob(id, reason: reason)
            case .paused?, .failed?:
                continue
            }
        }
    }

    /// The network or a switch changed. A running upload that may no longer
    /// use this network stops between files — a job waits for Wi-Fi, the
    /// originals queue stops and is walked again later — and whatever may
    /// now run goes.
    func uploadConditionsChanged() {
        let mobileHeld = wifiOnly && !isOnWiFi
        if mobileHeld {
            for (id, stop) in uploadStops where syncTasks[id] != nil {
                if var job = uploadJobs[id] {
                    guard !job.allowsMobileData, job.hold == nil else { continue }
                    job.hold = .waitingForWiFi
                    setJob(job, for: id)
                    stop.request()
                    LLog("picplace: upload of \(title(of: id)) — on mobile data with Only on Wi-Fi on: pausing until Wi-Fi")
                } else {
                    stop.request()
                    LLog("picplace: originals queue — on mobile data with Only on Wi-Fi on: stopping between files")
                }
            }
            if originalsQueueManual, originalsQueueTask != nil { manualOriginalsWaiting = true }
        } else if manualOriginalsWaiting, originalsQueueTask == nil, canSync {
            manualOriginalsWaiting = false
            LLog("picplace: originals queue — Wi-Fi again, carrying on")
            runOriginalsQueueManually()
        }
        resumeUploadJobs(reason: "network")
    }

    /// Pause for all sending (Project Syncing): every upload stops between
    /// files and waits for Resume.
    func pauseUploadJobs() {
        for id in uploadJobs.keys where uploadJobs[id]?.hold != .failed {
            uploadJobs[id]?.hold = .paused
            cancelUploadRetry(id)
        }
        saveUploadJobs()
        for stop in uploadStops.values { stop.request() }
    }

    /// Resume for all sending: every paused job, as a person's press.
    func resumePausedUploadJobs() {
        for (id, job) in uploadJobs where job.hold == .paused { resumeUpload(id) }
    }

    /// The originals queue's run in flight, if any, stops between files.
    func stopOriginalsQueueRun() {
        for (id, stop) in uploadStops where uploadJobs[id] == nil { stop.request() }
    }

    // MARK: Retry

    private func scheduleUploadRetry(_ id: UUID) {
        cancelUploadRetry(id)
        // Nothing to try on no network at all: the path coming up resumes it.
        guard isNetworkUp else { return }
        let count = (uploadRetryCounts[id] ?? 0) + 1
        uploadRetryCounts[id] = count
        let delays: [Double] = [10, 30, 120, 600]
        let delay = delays[min(count - 1, delays.count - 1)]
        LLog("picplace: upload of \(title(of: id)) interrupted — trying again in \(Int(delay)) s")
        uploadRetryTasks[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.uploadRetryTasks[id] = nil
            guard self.uploadJobs[id]?.hold == .interrupted, !self.sendsPaused else { return }
            self.startUploadJob(id, reason: "retry \(count)")
        }
    }

    func cancelUploadRetry(_ id: UUID) {
        uploadRetryTasks[id]?.cancel()
        uploadRetryTasks[id] = nil
    }

    /// Whether an error stopped the run from outside — the network, a busy
    /// server — rather than PicPlace refusing it: the job goes again on its own.
    static func isUploadInterruption(_ error: Error) -> Bool {
        if error is PicPlaceOfflineError { return true }
        if let failed = error as? PicPlaceSyncRun.Failed { return failed.interrupted }
        if let api = error as? PicPlaceAPIError { return api.isTransient }
        return PicPlaceTransfer.isTransient(error)
    }

    // MARK: Storage

    private func setJob(_ job: PicPlaceUploadJob?, for id: UUID) {
        uploadJobs[id] = job
        saveUploadJobs()
    }

    func saveUploadJobs() {
        syncMeta.uploadJobs = uploadJobs.isEmpty ? nil
            : Dictionary(uniqueKeysWithValues: uploadJobs.map { ($0.key.uuidString.lowercased(), $0.value) })
        saveSyncState()
    }

    static func loadUploadJobs(_ meta: PicPlaceSyncState.Meta) -> [UUID: PicPlaceUploadJob] {
        Dictionary(uniqueKeysWithValues: (meta.uploadJobs ?? [:]).compactMap { key, job in UUID(uuidString: key).map { ($0, job) } })
    }

    private func title(of id: UUID) -> String {
        model.capture(id: id)?.displayTitle ?? id.uuidString.prefix(8).description
    }

    #if DEBUG
    /// `LL_PICPLACE_UPLOAD=<uuid>` presses the card's Upload once per
    /// process, at launch — before the launch check, which mobile data holds.
    func runUploadHookOnce() {
        guard !Self.uploadHookRan, let raw = ProcessInfo.processInfo.environment["LL_PICPLACE_UPLOAD"],
              let id = UUID(uuidString: raw), let capture = model.capture(id: id) else { return }
        Self.uploadHookRan = true
        LLog("picplace hook: Upload the originals of \(capture.displayTitle)")
        uploadOriginals(capture)
        runUploadJobHooks(for: id)
    }

    /// The bench's presses on the upload `LL_PICPLACE_UPLOAD` started:
    /// `LL_PICPLACE_UPLOAD_PAUSE=<s>[:<s>]` pauses it that many seconds
    /// after it started and resumes it that many after the pause;
    /// `LL_PICPLACE_UPLOAD_MOBILE=<s>` presses *Use mobile data* then.
    func runUploadJobHooks(for id: UUID) {
        let environment = ProcessInfo.processInfo.environment
        if let raw = environment["LL_PICPLACE_UPLOAD_PAUSE"] {
            let parts = raw.split(separator: ":").compactMap { Double($0) }
            if let pauseAfter = parts.first {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(pauseAfter * 1_000_000_000))
                    guard let self else { return }
                    LLog("picplace hook: Pause the upload of \(self.title(of: id))")
                    self.pauseUpload(id)
                    guard parts.count > 1 else { return }
                    try? await Task.sleep(nanoseconds: UInt64(parts[1] * 1_000_000_000))
                    LLog("picplace hook: Resume the upload of \(self.title(of: id))")
                    self.resumeUpload(id)
                }
            }
        }
        if let after = environment["LL_PICPLACE_UPLOAD_MOBILE"].flatMap(Double.init) {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(after * 1_000_000_000))
                guard let self else { return }
                LLog("picplace hook: Use mobile data for the upload of \(self.title(of: id))")
                self.allowMobileData(forUpload: id)
            }
        }
    }
    #endif
}
