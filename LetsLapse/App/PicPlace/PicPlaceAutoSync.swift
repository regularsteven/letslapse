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
        if let raw = ProcessInfo.processInfo.environment["LL_PICPLACE_NETWORK"], raw.hasPrefix("cellular") {
            forcedNetwork = true
            isOnWiFi = false
            if let seconds = raw.split(separator: ":").dropFirst().first.flatMap({ Double($0) }) {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
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
            Task { @MainActor in
                guard let self else { return }
                let was = self.isOnWiFi
                self.isOnWiFi = unmetered
                if was != unmetered {
                    LLog("picplace: network is \(unmetered ? "Wi-Fi/Ethernet" : "mobile or metered") — auto-sync \(self.autoAllowed ? "may run" : "waits")")
                    self.autoSyncSettingChanged()
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "picplace.path"))
        pathMonitorBox = monitor
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
        if !autoSyncEnabled {
            for task in pendingPushes.values { task.cancel() }
            pendingPushes.removeAll()
            heldPushes.removeAll()
            pushQueue.removeAll()
            pushQueueTask?.cancel()
            pushQueueTask = nil
            pushQueueDone = 0
            pushQueueTotal = 0
            if autoStatus?.hasPrefix("Syncing") == true { autoStatus = nil }
        }
        if !originalsAllowed {
            originalsQueueTask?.cancel()
            originalsQueueTask = nil
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
        let held = heldPushes
        heldPushes.removeAll()
        for id in held { enqueuePush(id) }
        scheduleOriginalsQueue()
    }

    /// Whether the originals may move right now.
    var originalsAllowed: Bool {
        autoAllowed && autoOriginalsEnabled && model.stage != .processing
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
    /// the worker starts if it is not running. Held, not dropped, while
    /// the network rule holds.
    func enqueuePush(_ id: UUID) {
        guard autoSyncEnabled, canSync else { return }
        guard autoAllowed else { heldPushes.insert(id); return }
        if !pushQueue.contains(id) {
            pushQueue.append(id)
            pushQueueTotal += 1
        }
        drainPushQueue()
    }

    private func drainPushQueue() {
        guard pushQueueTask == nil, !pushQueue.isEmpty else { return }
        pushQueueTask = Task { [weak self] in
            guard let self else { return }
            await runPushQueue()
            pushQueueTask = nil
            pushQueueDone = 0
            pushQueueTotal = 0
            if autoStatus?.hasPrefix("Syncing") == true { autoStatus = nil }
        }
    }

    private func runPushQueue() async {
        var sent = 0
        var failed = 0
        while !pushQueue.isEmpty, !Task.isCancelled {
            // The rule moved under the queue: keep what is left for the release.
            guard autoAllowed else {
                heldPushes.formUnion(pushQueue)
                pushQueue.removeAll()
                break
            }
            // A check or the first connection walks the whole library and
            // may push these very projects: let it finish, then look again.
            if let running = checkTask { await running.value; continue }
            if let running = initialSyncTask { await running.value; continue }
            // A shoot being written: its project must not be pushed mid-write.
            // The queue stops here; the check after the shoot pushes what moved.
            if model.stage == .processing { pushQueue.removeAll(); break }
            let id = pushQueue.removeFirst()
            let outcome = await pushIfMoved(id)
            pushQueueDone += 1
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
                LLog("picplace: auto-sync queue — PicPlace can't be reached; \(pushQueue.count) project(s) left to the next check")
                pushQueue.removeAll()
                break
            }
        }
        if sent + failed > 0 {
            LLog("picplace: auto-sync queue — \(sent) sent, \(failed) failed\(pushQueue.isEmpty ? "" : ", \(pushQueue.count) held")")
        }
        updateAutoError()
        if sent > 0 { scheduleOriginalsQueue() }
    }

    private enum PushOutcome { case sent, failed, nothing }

    @discardableResult
    private func pushIfMoved(_ id: UUID) async -> PushOutcome {
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
        let base = records[origin]?.revision
        guard base == nil || revision(of: capture) != base else { return .nothing }
        // A project pushed by the check moments ago with the same stamp is in step.
        autoStatus = pushQueueTotal > 1
            ? "Syncing \(pushQueueDone + 1) of \(pushQueueTotal) · \(capture.displayTitle)…"
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
            await runOriginalsQueue()
            originalsQueueTask = nil
        }
    }

    private func runOriginalsQueue() async {
        guard let libraryIndex = model.libraryIndex else { return }
        var query = LibraryIndex.ProjectQuery()
        query.limit = 100_000
        query.sort = .created
        query.ascending = true
        let rows = (try? libraryIndex.projects(query).rows) ?? []
        let now = Date()
        for row in rows {
            guard originalsAllowed, !Task.isCancelled else { break }
            guard let capture = model.capture(id: row.id), let record = records[model.originID(of: capture)] else { continue }
            // The records go first: a project whose bundle and poster never
            // reached the server is the check's to retry, not this queue's.
            guard record.recordsReachedServer, record.elsewhereLibrary == nil else { continue }
            // A failed upload waits for its backoff, like a failed push.
            if let due = record.retryDueAt, due > now { continue }
            guard !model.sourcesMissing(capture), syncTasks[capture.id] == nil else { continue }
            let folder = model.projectFolderURL(for: capture)
            let summary = await Task.detached(priority: .utility) { () -> PicPlaceSyncInventory.Summary in
                let entries = (try? PicPlaceSyncRun.listFiles(in: folder)) ?? []
                return PicPlaceSyncInventory.summary(of: PicPlaceSyncInventory.classify(entries), policy: .minimal)
            }.value
            guard summary.heavyFiles > 0 else { continue }
            let origin = model.originID(of: capture)
            if let record = records[origin] {
                if record.originalsMovedAt != nil { continue }
                if let onServer = record.serverHeavyFiles, onServer >= summary.heavyFiles { continue }
            }
            autoStatus = "Uploading originals · \(capture.displayTitle) · \(summary.heavyFiles.formatted()) files · \(LLFormat.bytes(summary.heavyBytes))"
            await syncAndWait(capture, policy: .originals)
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
}
