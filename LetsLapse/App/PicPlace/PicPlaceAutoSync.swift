import Foundation
import Network
import LetsLapseKit

/// Auto-sync (v2 plan §4.7): the Lightroom experience — an edit reaches
/// PicPlace shortly after it settles, other devices' changes arrive on their
/// own, and, when switched on, the originals follow one project at a time.
///
/// Three switches, per install (a phone and a Mac want different answers):
/// **Sync changes automatically** (on by default once a library is
/// connected) pushes settled edits and new projects and runs a check every
/// few minutes; **Upload originals automatically** (off by default — a
/// 431 GB library must not start uploading the moment it connects) queues
/// every project whose originals are only here; **Only on Wi-Fi** (on by
/// default, both platforms) holds EVERY automatic transfer — pushes,
/// checks, the first connection, the originals — until the path is Wi-Fi
/// or Ethernet and not expensive (a personal hotspot is mobile data). A
/// person's own press — Sync, Download originals, Check now — works on any
/// connection: that is their call. A shoot being written pauses all of it;
/// downloads of originals stay per project.
///
/// Pushes go through **one queue, one project at a time**. An import of
/// 117 photos wrote 117 documents in two seconds; each armed its own
/// twenty-second timer and all 117 pushes fired together — some 900
/// requests inside a second against a server that allows 300 a minute, so
/// 96 of them were refused (2026-09-15). The debounce still decides WHEN a
/// project is due; the queue decides the order and the pace (the client
/// paces every request under the server's limit besides). A push that
/// fails is retried by the check with a backoff (`PicPlaceSyncRecord.retryDueAt`).
extension PicPlaceController {

    private static let pushDebounce: TimeInterval = 20
    private static var checkInterval: TimeInterval {
        #if DEBUG
        // `LL_PICPLACE_CHECK_INTERVAL=<seconds>` shortens the timer for a test.
        if let forced = ProcessInfo.processInfo.environment["LL_PICPLACE_CHECK_INTERVAL"].flatMap(Double.init), forced >= 5 { return forced }
        #endif
        return 3 * 60
    }

    // MARK: Arming

    func armAutoSync() {
        guard !isShutDown else { return }
        autoTimer?.invalidate()
        LLog("picplace: auto-sync switches for this device and library — changes \(autoSyncEnabled ? "on" : "off"), originals \(autoOriginalsEnabled ? "ON" : "off"), Wi-Fi only \(wifiOnly ? "on" : "off")")
        #if DEBUG
        // `LL_PICPLACE_RENAME=<uuid>:<name>` renames a project through the
        // real funnel five seconds after launch — the auto-push's cue.
        if let raw = ProcessInfo.processInfo.environment["LL_PICPLACE_RENAME"] {
            let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2, let id = UUID(uuidString: parts[0]) {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    guard let self, self.model.capture(id: id) != nil else { return }
                    self.model.updateCapture(id) { $0.name = parts[1] }
                    LLog("picplace hook: renamed \(id.uuidString.prefix(8)) to \(parts[1])")
                }
            }
        }
        #endif
        autoTimer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.autoSyncEnabled else { return }
                self.checkForChanges(reason: "timer")
            }
        }
        #if DEBUG
        // `LL_PICPLACE_NETWORK=cellular[:seconds]` pretends the path is mobile
        // data — for the given seconds, then Wi-Fi again — so the holds and
        // their release are exercised on a Mac that has no cellular.
        // `cellular@<start>[:seconds]` starts on Wi-Fi and leaves it `start`
        // seconds after launch: a phone walking out of the house mid-upload.
        if let raw = ProcessInfo.processInfo.environment["LL_PICPLACE_NETWORK"], raw.hasPrefix("cellular") {
            forcedNetwork = true
            let spec = raw.dropFirst("cellular".count)
            let start = spec.hasPrefix("@") ? Double(spec.dropFirst().split(separator: ":").first ?? "") ?? 0 : 0
            let seconds = spec.split(separator: ":").dropFirst().first.flatMap { Double($0) }
            if start > 0 {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(start * 1_000_000_000))
                    guard let self else { return }
                    self.isOnWiFi = false
                    LLog("picplace hook: network is mobile data")
                    self.autoSyncSettingChanged()
                }
            } else {
                isOnWiFi = false
            }
            if let seconds {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64((start + seconds) * 1_000_000_000))
                    guard let self else { return }
                    self.isOnWiFi = true
                    LLog("picplace hook: network back to Wi-Fi")
                    self.autoSyncSettingChanged()
                }
            }
            return
        }
        #endif
        // Both platforms: a Mac on a phone's hotspot is on mobile data too.
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let unmetered = (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
                && !path.isExpensive && !path.isConstrained && path.status == .satisfied
            let up = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                let was = self.isOnWiFi
                let wasUp = self.isNetworkUp
                self.isOnWiFi = unmetered
                self.isNetworkUp = up
                if was != unmetered {
                    LLog("picplace: network is \(unmetered ? "Wi-Fi/Ethernet" : "mobile or metered") — auto-sync \(self.autoAllowed ? "may run" : "waits")")
                    self.autoSyncSettingChanged()
                } else if up, !wasUp {
                    // Mobile data back after none: an interrupted upload
                    // allowed on it goes again.
                    self.resumeUploadJobs(reason: "network")
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "picplace.path"))
        pathMonitorBox = monitor
    }

    /// Why a project is in the push queue; `pushIfNeeded` reads it before
    /// sending, since the project may have moved on while it waited. The
    /// stronger reason wins when one project is queued twice.
    enum PushReason: Int, Comparable {
        /// A settled edit (auto-sync), or one the check found: sent when the
        /// project moved past its base.
        case edited
        /// Here and never on PicPlace.
        case new
        /// A push that failed, due again.
        case retry
        /// In step, but PicPlace holds no poster for it (the check asked).
        case poster

        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    /// One run of the push queue, from the first project queued to the queue
    /// running dry, for the Project Syncing drawer — kept through a pause,
    /// so *312 of 877* carries on where it stopped.
    struct SendRun: Equatable {
        var total = 0
        var done = 0
        var failed = 0
        /// How many of `total` are poster catch-ups — the drawer's title.
        var posters = 0
        /// The project being sent, while one is.
        var current: String?
        /// Seconds spent sending — not paused, not held — the pace the
        /// estimate is made from.
        var activeSeconds: Double = 0

        var left: Int { max(0, total - done) }

        /// Seconds to go at this run's own pace; nil until three are done.
        var secondsLeft: Double? {
            guard done >= 3, activeSeconds > 0 else { return nil }
            return activeSeconds / Double(done) * Double(left)
        }
    }

    /// Whether anything automatic may move right now: the switch, the
    /// session, the network rule, the battery.
    var autoAllowed: Bool {
        guard autoSyncEnabled, canSync else { return false }
        if wifiOnly, !isOnWiFi { return false }
        #if os(iOS)
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return false }
        #endif
        return true
    }

    /// Why nothing automatic is moving, for the status line.
    var autoHold: String? {
        guard autoSyncEnabled else { return nil }
        if !canSync { return "not connected" }
        if sendsPaused { return "paused — resume it in Project Syncing" }
        if wifiOnly, !isOnWiFi { return "waiting for Wi-Fi" }
        #if os(iOS)
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return "paused in Low Power Mode" }
        #endif
        return nil
    }

    /// A switch or a condition moved: stop what is no longer allowed, start
    /// what now is — the pushes that were held, the check that was held,
    /// the first connection, the originals.
    func autoSyncSettingChanged() {
        // A person's uploads first: the Wi-Fi rule applies to them whatever
        // auto-sync says (2026-09-24).
        uploadConditionsChanged()
        if !autoSyncEnabled {
            for task in pendingPushes.values { task.cancel() }
            pendingPushes.removeAll()
            heldPushes.removeAll()
            pushQueue.removeAll()
            pushQueueTask?.cancel()
            pushQueueTask = nil
            pushReasons.removeAll()
            pushQueueManual = false
            sendRun = nil
            sendRunIDs.removeAll()
            if autoStatus?.hasPrefix("Syncing") == true { autoStatus = nil }
        }
        // The automatic queue stops — its project mid-upload too, between
        // files. A person's walk from Settings answers only to the Wi-Fi
        // rule and the pause (`uploadConditionsChanged`, `pauseSends`).
        if !originalsAllowed, !originalsQueueManual {
            originalsQueueTask?.cancel()
            originalsQueueTask = nil
            stopOriginalsQueueRun()
            if autoStatus?.hasPrefix("Uploading originals") == true { autoStatus = nil }
        }
        guard autoAllowed else { return }
        if binding?.initialSync.state == .pending {
            runInitialSyncIfPending()
            return
        }
        if heldCheck {
            heldCheck = false
            checkForChanges(reason: "network")
        }
        releaseHeldPushes()
        scheduleOriginalsQueue()
        scheduleBlendsQueue()
    }

    /// The pushes a hold kept, back into the queue with the reasons they
    /// were queued for — unless a pause still holds them.
    private func releaseHeldPushes(manual: Bool = false) {
        guard !sendsPaused else { return }
        let held = heldPushes
        heldPushes.removeAll()
        for id in held { enqueuePush(id, reason: pushReasons[id] ?? .edited, manual: manual) }
    }

    // MARK: Pause

    /// The Project Syncing drawer's **Pause**: what is being sent finishes —
    /// never half a project — then nothing more goes to PicPlace until
    /// Resume: the queued pushes, the check's catch-ups, the originals
    /// queue. Kept in the library's sync state, so it outlives a relaunch;
    /// checks still run and pull.
    func pauseSends() {
        guard !sendsPaused else { return }
        sendsPaused = true
        syncMeta.sendsPaused = true
        saveSyncState()
        LLog("picplace: sending paused\(sendRun.map { " — \($0.left) left of \($0.total)" } ?? "")")
        // Uploads of originals stop between files (2026-09-24) — a project
        // of 11 GB is not "what is being sent finishes first".
        pauseUploadJobs()
    }

    /// **Resume**: a person's press, so it runs on any network, as their own
    /// check would. What the pause held goes back into the queue; after a
    /// relaunch nothing is held in memory, so a check finds the work again.
    func resumeSends() {
        guard sendsPaused else { return }
        sendsPaused = false
        syncMeta.sendsPaused = nil
        saveSyncState()
        LLog("picplace: sending resumed\(heldPushes.isEmpty ? "" : " — \(heldPushes.count) project(s) held")")
        let wasHolding = !heldPushes.isEmpty
        releaseHeldPushes(manual: true)
        resumePausedUploadJobs()
        scheduleOriginalsQueue()
        scheduleBlendsQueue()
        if !wasHolding { checkForChanges(reason: "manual") }
    }

    /// Whether the originals may move right now.
    var originalsAllowed: Bool {
        autoAllowed && autoOriginalsEnabled && model.stage != .processing && !sendsPaused
    }

    /// Why the originals are not moving, for the status line.
    var originalsHold: String? {
        guard autoSyncEnabled, autoOriginalsEnabled else { return nil }
        if let hold = autoHold { return hold }
        if model.stage == .processing { return "paused while a shoot runs" }
        return nil
    }

    // MARK: Edits

    /// A project's document changed on disk. Twenty seconds after the last
    /// change, the project joins the queue — and goes up if it actually
    /// moved past the base (a pull writes the document too, and must not
    /// bounce back).
    func noteProjectChanged(_ id: UUID) {
        guard autoSyncEnabled, canSync, binding?.initialSync.state == .done else { return }
        pendingPushes[id]?.cancel()
        pendingPushes[id] = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(Self.pushDebounce * 1_000_000_000)) } catch { return }
            guard let self else { return }
            self.pendingPushes[id] = nil
            self.enqueuePush(id)
        }
    }

    /// A project due for a push takes its place in the queue (once), and
    /// the worker starts if it is not running. Held, not dropped, while the
    /// network rule or a pause holds. `reason` is why it is due — a poster
    /// or a retry is sent even where an edit check would find nothing new —
    /// and `manual` is a person's press (their check, Resume): it runs on
    /// mobile data and with auto-sync off, as the check did when it pushed
    /// inline (it no longer does: a check that queued an hour of posters
    /// kept *Checking PicPlace…* greyed out for that hour, 2026-09-24).
    func enqueuePush(_ id: UUID, reason: PushReason = .edited, manual: Bool = false) {
        guard canSync, autoSyncEnabled || manual else { return }
        if manual { pushQueueManual = true }
        pushReasons[id] = max(pushReasons[id] ?? reason, reason)
        if !sendRunIDs.contains(id) {
            sendRunIDs.insert(id)
            var run = sendRun ?? SendRun()
            run.total += 1
            if reason == .poster { run.posters += 1 }
            sendRun = run
        }
        guard !sendsPaused, autoAllowed || pushQueueManual else {
            heldPushes.insert(id)
            return
        }
        if !pushQueue.contains(id) { pushQueue.append(id) }
        drainPushQueue()
    }

    private func drainPushQueue() {
        guard pushQueueTask == nil, !pushQueue.isEmpty, !sendsPaused else { return }
        pushQueueTask = Task { [weak self] in
            guard let self else { return }
            await runPushQueue()
            pushQueueTask = nil
            if autoStatus?.hasPrefix("Syncing") == true { autoStatus = nil }
            finishSendRunIfDone()
        }
    }

    /// The run ends when nothing is queued, held or paused: its line leaves
    /// the drawer, and the next project queued starts a new count.
    private func finishSendRunIfDone() {
        guard pushQueue.isEmpty, heldPushes.isEmpty, !sendsPaused, pushQueueTask == nil else { return }
        if let run = sendRun, run.done > 0 {
            LLog("picplace: sending done — \(run.done - run.failed) of \(run.total) sent\(run.failed > 0 ? ", \(run.failed) failed" : "")\(run.posters > 0 ? " (\(run.posters) poster catch-up(s))" : "")")
        }
        sendRun = nil
        sendRunIDs.removeAll()
        pushReasons = pushReasons.filter { heldPushes.contains($0.key) }
        pushQueueManual = false
    }

    /// Projects leaving the run without being sent — a shoot began, the
    /// server went out of reach — so its count stays true; the check
    /// queues them again.
    private func dropFromSendRun(_ ids: [UUID]) {
        guard var run = sendRun else { return }
        for id in ids where sendRunIDs.contains(id) {
            sendRunIDs.remove(id)
            run.total = max(run.done, run.total - 1)
            if pushReasons[id] == .poster { run.posters = max(0, run.posters - 1) }
            pushReasons[id] = nil
        }
        sendRun = run
    }

    private func runPushQueue() async {
        var sent = 0
        var failed = 0
        while !pushQueue.isEmpty, !Task.isCancelled {
            // Paused, or the rule moved under the queue: keep what is left
            // for the release.
            guard !sendsPaused, autoAllowed || pushQueueManual else {
                heldPushes.formUnion(pushQueue)
                pushQueue.removeAll()
                break
            }
            // A check or the first connection walks the whole library and
            // may queue these very projects: let it finish, then look again.
            if let running = checkTask { await running.value; continue }
            if let running = initialSyncTask { await running.value; continue }
            // A shoot being written: its project must not be pushed mid-write.
            // The queue stops here; the check after the shoot pushes what moved.
            if model.stage == .processing {
                dropFromSendRun(pushQueue)
                pushQueue.removeAll()
                break
            }
            let id = pushQueue.removeFirst()
            let reason = pushReasons[id] ?? .edited
            let started = Date()
            let outcome = await pushIfNeeded(id, reason: reason)
            if var run = sendRun {
                run.current = nil
                if outcome == .nothing {
                    // Needed nothing after all (sent by an earlier run, pulled,
                    // a person's own Sync): not work, so not in the count.
                    if sendRunIDs.remove(id) != nil {
                        run.total = max(run.done, run.total - 1)
                        if reason == .poster { run.posters = max(0, run.posters - 1) }
                    }
                } else {
                    run.done += 1
                    run.activeSeconds += Date().timeIntervalSince(started)
                    if outcome == .failed { run.failed += 1 }
                }
                sendRun = run
            }
            pushReasons[id] = nil
            switch outcome {
            case .sent: sent += 1
            case .failed: failed += 1
            case .nothing: break
            }
            if outcome == .failed, lastSyncFailedOffline {
                // The server cannot be reached: failing through the rest one
                // timeout at a time helps nobody. The check — which runs
                // again on the timer and when the network changes — pushes
                // whatever still differs, this project included.
                LLog("picplace: push queue — PicPlace can't be reached; \(pushQueue.count) project(s) left to the next check")
                dropFromSendRun(pushQueue)
                pushQueue.removeAll()
                break
            }
        }
        if sent + failed > 0 {
            LLog("picplace: push queue — \(sent) sent, \(failed) failed\(pushQueue.isEmpty && heldPushes.isEmpty ? "" : ", \(pushQueue.count + heldPushes.count) held")\(sendsPaused ? " (paused)" : "")")
        }
        updateAutoError()
        if sent > 0 { scheduleOriginalsQueue(); scheduleBlendsQueue() }
    }

    private enum PushOutcome { case sent, failed, nothing }

    /// Sends one queued project if it still needs it — it may have moved on
    /// while it waited: pulled meanwhile, sent by a person's own Sync,
    /// deleted, in a conflict, filed elsewhere.
    @discardableResult
    private func pushIfNeeded(_ id: UUID, reason: PushReason) async -> PushOutcome {
        guard let capture = model.capture(id: id) else { return .nothing }
        // A delete is written through the same funnel (the tombstone), and
        // its folder is in the trash: the check pushes deletes, not this.
        guard capture.deletedAt == nil else { return .nothing }
        let origin = model.originID(of: capture)
        if conflicts.contains(where: { $0.originID == origin }) { return .nothing }
        // Filed in another library on PicPlace (stage C): not this library's to push.
        if records[origin]?.elsewhereLibrary != nil { return .nothing }
        // A person's own Sync of it is under way: that push is this push.
        if let running = syncTasks[id] { await running.value; return .nothing }
        let record = records[origin]
        let base = record?.revision
        let moved = base == nil || revision(of: capture) != base
        switch reason {
        case .edited:
            // A pull writes the document too, and must not bounce back.
            guard moved else { return .nothing }
        case .new:
            guard moved || record?.recordsReachedServer != true else { return .nothing }
        case .retry:
            guard moved || record?.lastError != nil else { return .nothing }
        case .poster:
            guard moved || (record?.posterToken == nil && !model.sourcesMissing(capture)) else { return .nothing }
        }
        if var run = sendRun { run.current = capture.displayTitle; sendRun = run }
        let run = sendRun
        autoStatus = (run?.total ?? 0) > 1
            ? "Syncing \((run?.done ?? 0) + 1) of \(run?.total ?? 0) · \(capture.displayTitle)…"
            : "Syncing \(capture.displayTitle)…"
        await syncAndWait(capture)
        return records[origin]?.lastError == nil ? .sent : .failed
    }

    /// The "Auto-sync problem" line: how many pushes stand failed, the
    /// last reason, and when the next try is due.
    func updateAutoError() {
        let failed = failedPushes
        guard !failed.isEmpty else { autoError = nil; return }
        let latest = failed.max { ($0.record.failedAt ?? .distantPast) < ($1.record.failedAt ?? .distantPast) }!
        let due = failed.compactMap(\.record.retryDueAt).min()
        var line = failed.count == 1
            ? "\(model.capture(id: latest.localID)?.displayTitle ?? "1 project") couldn't be synced"
            : "\(failed.count) projects couldn't be synced"
        if let reason = latest.record.lastError { line += " — \(reason)" }
        if let due {
            line += due <= Date() ? " · retrying at the next check" : " · next try \(due.formatted(date: .omitted, time: .shortened))"
        }
        autoError = line
    }

    // MARK: The originals queue

    /// Every project whose originals are only here goes up, one at a time,
    /// oldest first, while the conditions hold. Re-armed after every check
    /// and every auto-push; a project already being synced waits its turn.
    func scheduleOriginalsQueue() {
        guard originalsAllowed, originalsQueueTask == nil else { return }
        originalsQueueTask = Task { [weak self] in
            guard let self else { return }
            await runOriginalsQueue(manual: false)
            originalsQueueTask = nil
        }
    }

    /// A person's *Upload now* (Settings, beside free up space): the same
    /// walk once, whatever the automatic switch says. *Only on Wi-Fi* holds
    /// it (2026-09-24 — that switch is how a person says "not on my data";
    /// a project's own Upload can be let onto mobile data, this walk not):
    /// on mobile data it waits, and carries on when Wi-Fi is back. A shoot
    /// being written still pauses it.
    func runOriginalsQueueManually() {
        guard canSync, originalsQueueTask == nil else { return }
        manualOriginalsWaiting = false
        originalsQueueManual = true
        originalsQueueTask = Task { [weak self] in
            guard let self else { return }
            await runOriginalsQueue(manual: true)
            originalsQueueTask = nil
            originalsQueueManual = false
            if freeUp.estimate != nil { refreshFreeUpEstimate() }
        }
    }

    /// The walk. A project is skipped when its heavy set — every source
    /// file and blend here, by path and size — is the one this device last
    /// saw PicPlace hold (`heavyDigest`). Anything else — a blend rendered
    /// after the upload, frames added, a push from before the marker — gets
    /// one read of PicPlace's list first: if every file is there by path,
    /// size and hash, the marker is written and nothing moves; otherwise the
    /// originals go up (negotiated by hash, so only what is missing is sent).
    /// Until 2026-09-23 "uploaded once" (`originalsMovedAt`) skipped a
    /// project for good, so a later blend never went up.
    private func runOriginalsQueue(manual: Bool) async {
        guard let libraryIndex = model.libraryIndex else { return }
        var query = LibraryIndex.ProjectQuery()
        query.limit = 100_000
        query.sort = .created
        query.ascending = true
        let rows = (try? libraryIndex.projects(query).rows) ?? []
        let now = Date()
        for row in rows {
            guard manual ? canSync : originalsAllowed, !Task.isCancelled else { break }
            if manual, model.stage == .processing { break }
            if manual, wifiOnly, !isOnWiFi {
                LLog("picplace: originals queue — waiting for Wi-Fi")
                manualOriginalsWaiting = true
                break
            }
            // The drawer's Pause holds a person's run too: the project being
            // sent finishes, the next one waits for Resume.
            if sendsPaused {
                LLog("picplace: originals queue — paused")
                break
            }
            guard let capture = model.capture(id: row.id), let record = records[model.originID(of: capture)] else { continue }
            // The records go first: a project whose bundle and poster never
            // reached the server is the check's to retry, not this queue's.
            guard record.recordsReachedServer, record.elsewhereLibrary == nil else { continue }
            // A failed upload waits for its backoff, like a failed push —
            // unless a person asked.
            if !manual, let due = record.retryDueAt, due > now { continue }
            // Not "sources missing → skip": a project whose originals were
            // removed to free space can still hold a blend PicPlace lacks.
            // What is here decides — a pulled preview has nothing heavy.
            guard syncTasks[capture.id] == nil, !removingProjects.contains(capture.id) else { continue }
            // A person's upload job owns its project — paused means paused.
            guard uploadJobs[capture.id] == nil else { continue }
            let folder = model.projectFolderURL(for: capture)
            let listing = await Task.detached(priority: .utility) { Self.heavyFiles(in: folder) }.value
            heavyListings[capture.id] = listing
            guard !listing.isEmpty else { continue }
            let origin = model.originID(of: capture)
            let digest = PicPlaceOriginalsCheck.digest(listing)
            if records[origin]?.heavyDigest == digest { continue }
            switch await heavySetOnPicPlace(listing, origin: origin, folder: folder) {
            case .verified:
                records[origin]?.heavyDigest = digest
                saveSyncState()
                continue
            case .checking:
                // All there; PicPlace has yet to read some back. Nothing to
                // upload — the marker waits for a later pass.
                continue
            case .missing:
                break
            }
            let bytes = listing.reduce(Int64(0)) { $0 + $1.bytes }
            autoStatus = "Uploading originals · \(capture.displayTitle) · \(listing.count.formatted()) files · \(LLFormat.bytes(bytes))"
            originalsRunPaused = false
            await syncAndWait(capture, policy: .originals)
            if originalsRunPaused {
                // Stopped between files: what reached PicPlace stays, and the
                // next walk sends the rest. Not the next project now.
                originalsRunPaused = false
                LLog("picplace: originals queue — stopped with \(capture.displayTitle) part-way; the next walk carries on")
                break
            }
            if records[origin]?.lastError != nil {
                // One failure stops the walk; the next check re-arms the
                // queue and this project waits out its backoff.
                updateAutoError()
                break
            }
            updateAutoError()
        }
        if autoStatus?.hasPrefix("Uploading originals") == true { autoStatus = nil }
    }

    // MARK: The blends queue (D1, 2026-09-25)

    /// Whether blends may go up on their own right now: every rule an
    /// automatic send keeps — auto-sync, the session, *Only on Wi-Fi*, Low
    /// Power Mode, a shoot being written, the drawer's Pause — and the
    /// library's *Upload blends automatically*.
    var blendsAllowed: Bool {
        heavyChecksAllowed && autoBlendsEnabled
    }

    /// Whether the queue may walk at all — its reads of PicPlace's lists,
    /// which keep the holdings pill's green tick true, run under every rule
    /// but *Upload blends automatically*, which only holds the uploads.
    var heavyChecksAllowed: Bool {
        autoAllowed && model.stage != .processing && !sendsPaused
    }

    func scheduleBlendsQueue() {
        guard heavyChecksAllowed, blendsQueueTask == nil else { return }
        blendsQueueTask = Task { [weak self] in
            guard let self else { return }
            await runBlendsQueue()
            blendsQueueTask = nil
        }
    }

    /// A walk once PicPlace has had time to read back what an upload left
    /// it checking ("within a minute or two") — so the pill turns green
    /// then, not at the next check.
    func scheduleHeavyRecheck() {
        heavyRecheckTask?.cancel()
        heavyRecheckTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(90))
            guard !Task.isCancelled, let self else { return }
            heavyRecheckTask = nil
            scheduleBlendsQueue()
        }
    }

    /// Every project holding a blend PicPlace lacks sends its blends —
    /// newest project first (the blend just rendered is the one somebody is
    /// waiting for on another device), one project at a time, while the
    /// rules hold (docs/connected-asset-states-plan.md D1). A project is
    /// skipped when its whole heavy set is verified there (`heavyDigest`, an
    /// originals upload) or its blends were seen there last time
    /// (`blendsDigest`); otherwise one read of PicPlace's list decides, and
    /// only what is missing goes (negotiated by hash). The records go first:
    /// a project that moved since its last push is the push queue's, and
    /// its blends follow the push. A Photo capture's stack is its picture —
    /// it travels with the originals (plan T3), never on its own.
    ///
    /// A project whose originals went up (or were seen there) is checked
    /// WHOLE: its `heavyDigest` is what the holdings pill's green tick
    /// reads (plan §4.3), so a set that only gained a blend — sent here —
    /// or that PicPlace was still reading back when its upload ended is
    /// marked backed up again once PicPlace holds all of it, whether or not
    /// the originals queue is on. So is a set another device sent, once
    /// PicPlace's count of its heavy files covers what is here. A set found
    /// incomplete for want of something this queue does not send is not
    /// read again until it changes (`heavySetMissing`).
    private func runBlendsQueue() async {
        guard let libraryIndex = model.libraryIndex else { return }
        var query = LibraryIndex.ProjectQuery()
        query.limit = 100_000
        query.sort = .created
        query.ascending = false
        let rows = (try? libraryIndex.projects(query).rows) ?? []
        let now = Date()
        for row in rows {
            guard heavyChecksAllowed, !Task.isCancelled else { break }
            guard let capture = model.capture(id: row.id) else { continue }
            let origin = model.originID(of: capture)
            guard let record = records[origin], record.recordsReachedServer, record.elsewhereLibrary == nil,
                  record.revision == revision(of: capture) else { continue }
            // A set this device sent or fetched is checked whole. So is one
            // another device sent — the iPad's upload of a project that is
            // here too: PicPlace holds at least as many heavy files of it as
            // this device had at its last push, and one read settles the
            // rest (2026-09-25: the 16 Pro called three projects the iPad had
            // backed up "not backed up" and listed them under Needs
            // uploading). Fewer there means something here is missing: no read.
            let ownSet = record.heavyDigest != nil || record.originalsMovedAt != nil
            let serverHeavyFiles = record.serverHeavyFiles ?? 0
            let sentElsewhere = !ownSet && serverHeavyFiles > 0 && serverHeavyFiles >= (record.heavyFiles ?? 0)
            let sendsBlends = !capture.isPhotoCapture && autoBlendsEnabled
            guard ownSet || sentElsewhere
                    || (sendsBlends && model.blends(for: capture).contains(where: { !model.blendFileMissing($0) })) else { continue }
            if let due = record.retryDueAt, due > now { continue }
            guard syncTasks[capture.id] == nil, !removingProjects.contains(capture.id), uploadJobs[capture.id] == nil else { continue }
            let folder = model.projectFolderURL(for: capture)
            let listing = await Task.detached(priority: .utility) { Self.heavyFiles(in: folder) }.value
            guard !listing.isEmpty else { continue }
            let wholeDigest = PicPlaceOriginalsCheck.digest(listing)
            if record.heavyDigest == wholeDigest { continue }
            // Another device's set, counted against what is here now.
            let wholeSet = ownSet || (sentElsewhere && serverHeavyFiles >= listing.count)
            let blendListing = sendsBlends ? listing.filter { $0.kind == .blend } : []
            let digest = PicPlaceOriginalsCheck.digest(blendListing)
            let blendsThere = blendListing.isEmpty || record.blendsDigest == digest
            if wholeSet {
                if blendsThere, heavySetMissing[origin] == wholeDigest { continue }
                switch await heavySetOnPicPlace(listing, origin: origin, folder: folder) {
                case .verified:
                    records[origin]?.heavyDigest = wholeDigest
                    if !blendListing.isEmpty { records[origin]?.blendsDigest = digest }
                    heavySetMissing[origin] = nil
                    saveSyncState()
                    LLog("picplace: \(capture.displayTitle) — all \(listing.count) heavy file(s) here verified on PicPlace\(ownSet ? "" : " (sent from another device)"): backed up")
                    continue
                case .checking:
                    continue
                case .missing:
                    // Not for want of a blend: the originals queue's, or a
                    // person's Upload — not read again until the set moves.
                    if blendsThere {
                        heavySetMissing[origin] = wholeDigest
                        continue
                    }
                }
            } else {
                guard !blendsThere else { continue }
                switch await heavySetOnPicPlace(blendListing, origin: origin, folder: folder) {
                case .verified:
                    records[origin]?.blendsDigest = digest
                    saveSyncState()
                    continue
                case .checking:
                    continue
                case .missing:
                    break
                }
            }
            guard blendsAllowed else { continue }
            let bytes = blendListing.reduce(Int64(0)) { $0 + $1.bytes }
            autoStatus = "Uploading blends · \(capture.displayTitle) · \(blendListing.count.formatted()) · \(LLFormat.bytes(bytes))"
            LLog("picplace: blends queue — \(capture.displayTitle): \(blendListing.count) blend(s), \(bytes) bytes")
            originalsRunPaused = false
            await syncAndWait(capture, policy: .blends)
            if originalsRunPaused {
                originalsRunPaused = false
                LLog("picplace: blends queue — stopped with \(capture.displayTitle) part-way; the next walk carries on")
                break
            }
            if records[origin]?.lastError != nil {
                updateAutoError()
                break
            }
            // The set was whole before the blend: with the blend there it is
            // whole again — the green tick now, not at the next check. One
            // PicPlace is still reading back waits for `scheduleHeavyRecheck`.
            if wholeSet, case .verified = await heavySetOnPicPlace(listing, origin: origin, folder: folder) {
                records[origin]?.heavyDigest = wholeDigest
                saveSyncState()
            }
        }
        if autoStatus?.hasPrefix("Uploading blends") == true { autoStatus = nil }
    }

    /// Where PicPlace stands with a project's heavy files.
    private enum HeavySetState {
        /// Every file, byte for byte, read back by PicPlace.
        case verified
        /// Every file there by PicPlace's account, some not yet read back.
        case checking
        /// Something missing or different — an upload decides what.
        case missing
    }

    /// Whether PicPlace holds every file of `listing` — one fresh read of
    /// the project's list, by path and size, then by hash (the capture-time
    /// ones where a file is as hashed, computed otherwise), then whether
    /// PicPlace has read its copies back. Missing on a failed read: the
    /// upload then decides, by hash, what is missing.
    private func heavySetOnPicPlace(_ listing: [PicPlaceOriginalsCheck.LocalFile], origin: UUID, folder: URL) async -> HeavySetState {
        let detail: PPProjectDetail
        do { detail = try await client.get("projects/\(origin.uuidString.lowercased())") } catch { return .missing }
        let remote = Self.remoteHeavy(detail.assets)
        serverHeavy[origin] = remote
        guard PicPlaceOriginalsCheck.notCovered(listing, by: remote).isEmpty else { return .missing }
        guard let hashed = try? await Task.detached(priority: .utility, operation: { try Self.hashed(listing, in: folder) }).value else { return .missing }
        let verdict = PicPlaceOriginalsCheck.verify(hashed, against: remote)
        return verdict.passes ? .verified : verdict.awaitsVerification ? .checking : .missing
    }
}
