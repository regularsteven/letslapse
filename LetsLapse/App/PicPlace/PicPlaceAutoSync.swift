import Foundation
import Network
import LetsLapseKit
#if canImport(UIKit)
import UIKit
#endif

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

    /// The timer's pace while the app is not in front (2026-09-29): a Mac
    /// left open overnight ran 198 checks — each two reads of PicPlace and
    /// passes over every project — and learned nothing. Coming to the front
    /// checks at once, as ever. A test's shortened interval holds in the
    /// background too: a driver-launched instance is rarely the active app.
    private static var backgroundCheckInterval: TimeInterval {
        #if DEBUG
        if ProcessInfo.processInfo.environment["LL_PICPLACE_CHECK_INTERVAL"] != nil { return checkInterval }
        #endif
        return 15 * 60
    }

    // MARK: Arming

    func armAutoSync() {
        guard !isShutDown else { return }
        autoTimer?.invalidate()
        LLog("picplace: auto-sync switches for this device and library — changes \(autoSyncEnabled ? "on" : "off"), originals \(autoOriginalsEnabled ? "ON" : "off"), Wi-Fi only \(wifiOnly ? "on" : "off")")
        #if DEBUG
        // `LL_PICPLACE_RENAME=<uuid>:<name>[@<seconds>]` renames a project
        // through the real funnel five seconds after launch — or that many —
        // the auto-push's cue (a later one lands inside `LL_PICPLACE_OUTAGE`).
        if let raw = ProcessInfo.processInfo.environment["LL_PICPLACE_RENAME"] {
            var spec = Substring(raw)
            var delay = 5.0
            if let at = raw.lastIndex(of: "@"), let seconds = Double(raw[raw.index(after: at)...]) {
                delay = seconds
                spec = raw[..<at]
            }
            let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2, let id = UUID(uuidString: parts[0]) {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
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
                if !self.isAppActive, let last = self.lastCheckAt,
                   Date().timeIntervalSince(last) < Self.backgroundCheckInterval - 5 { return }
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
                // A network that changed may reach PicPlace where the last
                // one could not: the gate opens and one check looks.
                if up, self.unreachableUntil != nil { self.networkChangedWhileUnreachable() }
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
        /// A push of this run has begun (2026-09-29). Until one has, the
        /// drawer shows no sending block: a project queued that turns out to
        /// need nothing leaves the count without ever having flashed it.
        var started = false

        var left: Int { max(0, total - done) }

        /// Seconds to go at this run's own pace; nil until three are done.
        var secondsLeft: Double? {
            guard done >= 3, activeSeconds > 0 else { return nil }
            return activeSeconds / Double(done) * Double(left)
        }
    }

    /// Whether anything automatic may move right now: the switch, the
    /// session, the network rule, PicPlace answering, the battery.
    var autoAllowed: Bool {
        guard autoSyncEnabled, canSync else { return false }
        if wifiOnly, !isOnWiFi { return false }
        if isUnreachable { return false }
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
        if isUnreachable { return "waiting — \(sessionHost) can't be reached" }
        #if os(iOS)
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return "paused in Low Power Mode" }
        #endif
        return nil
    }

    // MARK: PicPlace not answering (2026-09-29)

    /// The gate is closed: PicPlace gave no answer and its backoff has not
    /// run out (`unreachableUntil`).
    var isUnreachable: Bool { (unreachableUntil ?? .distantPast) > Date() }

    /// The client's word (`PicPlaceClient.reachability`): no answer, or the
    /// first answer after none.
    func noteServerAnswered(_ answered: Bool) {
        if answered { noteServerReachable() } else { noteServerUnreachable() }
    }

    /// A request got no answer at all. The first closes the gate for a
    /// minute, and each failed look after it for twice as long, up to half
    /// an hour. Requests failing together while it is closed are one
    /// failure, not a streak.
    private func noteServerUnreachable() {
        guard !isShutDown else { return }
        let now = Date()
        if let until = unreachableUntil, until > now { return }
        unreachableStreak += 1
        let wait = min(30 * 60, 60 * pow(2, Double(unreachableStreak - 1)))
        unreachableUntil = now.addingTimeInterval(wait)
        LLog("picplace: \(sessionHost) can't be reached — nothing automatic asks it for \(Int((wait / 60).rounded())) min (no answer \(unreachableStreak) time\(unreachableStreak == 1 ? "" : "s") in a row)")
        reachabilityProbe?.cancel()
        reachabilityProbe = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard let self, !Task.isCancelled, !self.isShutDown else { return }
            self.reachabilityProbe = nil
            self.lookForServer(reason: "retry")
        }
    }

    /// PicPlace answered after a silence: the gate opens, and what it held
    /// goes — the pushes, a check to catch up, the uploads.
    private func noteServerReachable() {
        guard unreachableUntil != nil || unreachableStreak > 0 else { return }
        reachabilityProbe?.cancel()
        reachabilityProbe = nil
        unreachableUntil = nil
        unreachableStreak = 0
        LLog("picplace: \(sessionHost) answers again — automatic sync carries on")
        releaseHeldPushes()
        // The answer may be the look's own check; one already running is it.
        if checkTask == nil { lookForServer(reason: "reachable") }
        resumeUploadJobs(reason: "reachable")
    }

    /// The network changed while the gate was closed: it opens, and one
    /// look goes now. The streak stays — so the answer, if one comes, is
    /// PicPlace back (`noteServerReachable` releases what was held), and
    /// silence on this network too waits longer again.
    func networkChangedWhileUnreachable() {
        reachabilityProbe?.cancel()
        reachabilityProbe = nil
        unreachableUntil = nil
        LLog("picplace: the network changed — looking for \(sessionHost) again")
        lookForServer(reason: "network")
    }

    /// One look: the check, or the first connection still pending. Its
    /// answer opens the gate; its silence closes it again for longer.
    private func lookForServer(reason: String) {
        if binding?.initialSync.state == .pending {
            runInitialSyncIfPending()
        } else {
            checkForChanges(reason: reason)
        }
    }

    /// The drawer's run ends when PicPlace goes silent under it: what it
    /// had not sent is held (`heldPushes`) and the drawer's one line counts
    /// it, rather than a run that cannot move. A pause keeps its run — its
    /// Resume goes on counting.
    private func endSendRunForSilence() {
        guard isUnreachable, !sendsPaused else { return }
        sendRun = nil
        sendRunIDs.removeAll()
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
        // A switch or a condition moved — nothing the walks' key sees.
        scheduleOriginalsQueue(force: true)
        scheduleBlendsQueue(force: true)
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
        scheduleOriginalsQueue(force: true)
        scheduleBlendsQueue(force: true)
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
    ///
    /// Only an edit wakes it (2026-09-29): a write that left the project at
    /// its PicPlace base — a measured size, a pulled update, a status field,
    /// a stamp on the way to disk — has nothing to send, which the push used
    /// to find out twenty seconds later. The size sort wrote 750 documents
    /// in six minutes and each one flashed the drawer's sending block.
    func noteProjectChanged(_ id: UUID) {
        guard autoSyncEnabled, canSync, binding?.initialSync.state == .done else { return }
        guard let capture = model.capture(id: id), capture.deletedAt == nil, hasMovedPastBase(capture) else { return }
        // PicPlace isn't answering: held as it is, no timer — the answer
        // releases it, and the check after it would find it anyway.
        if isUnreachable {
            pendingPushes[id]?.cancel()
            pendingPushes[id] = nil
            holdForSilence(id, reason: .edited)
            return
        }
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
        // Silence holds an automatic push outside any run: the drawer's line
        // counts it, and the answer releases it (2026-09-29).
        if !manual, !pushQueueManual, isUnreachable {
            holdForSilence(id, reason: reason)
            return
        }
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
        // Queued now, so no longer waiting: the drawer's count stays true
        // when the check queues a project a hold was keeping.
        if heldPushes.contains(id) { heldPushes.remove(id) }
        if !pushQueue.contains(id) { pushQueue.append(id) }
        drainPushQueue()
    }

    /// Whether the project holds an edit PicPlace hasn't got: never agreed a
    /// revision with it, or moved past the one it agreed — `pushIfNeeded`'s
    /// test for an edit, asked when the write lands.
    func hasMovedPastBase(_ capture: AppModel.CaptureProject) -> Bool {
        guard let base = records[model.originID(of: capture)]?.revision else { return true }
        return revision(of: capture) != base
    }

    /// Held while PicPlace is silent — an id in a set, no timer, no request,
    /// no place in a run — with the stronger of its reasons.
    private func holdForSilence(_ id: UUID, reason: PushReason) {
        pushReasons[id] = max(pushReasons[id] ?? reason, reason)
        if !heldPushes.contains(id) { heldPushes.insert(id) }
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
                endSendRunForSilence()
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
                // timeout at a time helps nobody. What is left — this project
                // too — waits for PicPlace's answer (2026-09-29), which
                // releases it; the check after it pushes whatever still
                // differs anyway. The drawer's line counts them.
                // A check can have queued the project being sent again: count ids once.
                LLog("picplace: push queue — PicPlace can't be reached; \(Set(pushQueue + [id]).count) project(s) wait for it")
                holdForSilence(id, reason: reason)
                for left in pushQueue { holdForSilence(left, reason: pushReasons[left] ?? .edited) }
                pushQueue.removeAll()
                if !sendsPaused {
                    sendRun = nil
                    sendRunIDs.removeAll()
                }
                break
            }
        }
        if sent + failed > 0 {
            LLog("picplace: push queue — \(sent) sent, \(failed) failed\(pushQueue.isEmpty && heldPushes.isEmpty ? "" : ", \(pushQueue.count + heldPushes.count) held")\(sendsPaused ? " (paused)" : "")")
        }
        updateAutoError()
        if sent > 0 { scheduleOriginalsQueue(); scheduleBlendsQueue(); scheduleProxyQueue() }
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
            guard moved || (record?.posterToken == nil && !model.sourcesMissing(capture) && record?.posterFailedRecently != true) else { return .nothing }
        }
        if var run = sendRun { run.current = capture.displayTitle; run.started = true; sendRun = run }
        let run = sendRun
        autoStatus = (run?.total ?? 0) > 1
            ? "Syncing \((run?.done ?? 0) + 1) of \(run?.total ?? 0) · \(capture.displayTitle)…"
            : "Syncing \(capture.displayTitle)…"
        await syncAndWait(capture, policy: await wholePushPolicy(for: capture, record: record))
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

    /// A project PicPlace has never had from this device, whose originals are
    /// few and small, goes up whole in ONE cycle when originals may go at
    /// all (2026-10-01): records, poster and originals under one claim, one
    /// manifest PUT, one negotiate, one confirm. Until then every new
    /// project took two full cycles — the records, then the originals queue's
    /// own claim, manifest, negotiate, confirm, presence and release — about
    /// 14 API requests a photo, which at the server's pace is the clock of a
    /// large import. nil: the usual records-only push, and the originals
    /// queue sends the rest — always for a large set (a long shoot, a
    /// video), whose upload must stay pausable and resumable as a job and
    /// must not hold the edits queued behind it.
    static let wholePushMaxFiles = 4
    static let wholePushMaxBytes: Int64 = 100 * 1024 * 1024

    private func wholePushPolicy(for capture: AppModel.CaptureProject, record: PicPlaceSyncRecord?) async -> PicPlaceSyncPolicy? {
        guard originalsAllowed, uploadJobs[capture.id] == nil, !model.sourcesMissing(capture),
              record?.recordsReachedServer != true, record?.originalsMovedAt == nil, record?.policy != "pull" else { return nil }
        let folder = model.projectFolderURL(for: capture)
        let listing = await Task.detached(priority: .utility) { Self.heavyFiles(in: folder) }.value
        let bytes = listing.reduce(Int64(0)) { $0 + $1.bytes }
        guard !listing.isEmpty, listing.count <= Self.wholePushMaxFiles, bytes <= Self.wholePushMaxBytes else { return nil }
        return .everything
    }

    // MARK: The originals queue

    /// Every project whose originals are only here goes up, one at a time,
    /// oldest first, while the conditions hold. Re-armed after every check
    /// and every auto-push; a project already being synced waits its turn.
    ///
    /// Skipped when nothing has moved since the last whole walk (2026-09-29)
    /// — it would read every project to the same end; `force` for a change
    /// the key cannot see (a switch, Resume, a look PicPlace asked for).
    func scheduleOriginalsQueue(force: Bool = false) {
        guard originalsAllowed, originalsQueueTask == nil else { return }
        if !force, walkIsFresh(originalsWalkSeen) { return }
        let key = currentWalkKey
        originalsQueueTask = Task { [weak self] in
            guard let self else { return }
            if await runOriginalsQueue(manual: false) { originalsWalkSeen = (key, Date()) }
            originalsQueueTask = nil
        }
    }

    /// What a walk's answer depends on: the library's documents, its files
    /// and the sync facts. Taken as the walk starts, so a change made while
    /// it walked brings the next one.
    struct WalkKey: Equatable {
        var index: Int
        var files: Int
        var facts: Int
    }

    var currentWalkKey: WalkKey {
        WalkKey(index: model.indexRevision, files: model.filesRevision, facts: syncFactsRevision)
    }

    /// A walk that saw this key within half an hour: nothing to walk for.
    /// The half hour is PicPlace's side, which can move without the records
    /// saying so.
    func walkIsFresh(_ seen: (key: WalkKey, at: Date)?) -> Bool {
        guard let seen else { return false }
        return seen.key == currentWalkKey && Date().timeIntervalSince(seen.at) < 30 * 60
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
            if freeUp.estimate != nil { refreshFreeUpEstimate(force: true) }
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
    /// True when it walked every project — what `scheduleOriginalsQueue`
    /// remembers the walk by.
    @discardableResult
    private func runOriginalsQueue(manual: Bool) async -> Bool {
        guard let libraryIndex = model.libraryIndex else { return false }
        var query = LibraryIndex.ProjectQuery()
        query.limit = 100_000
        query.sort = .created
        query.ascending = true
        let rows = (try? libraryIndex.projects(query).rows) ?? []
        let now = Date()
        var visited = 0
        var walkedWhole = true
        // The "is it on PicPlace already?" read, a hundred projects at a
        // time (2026-10-01): when a row needs the read, the rows after it
        // that have never been verified are asked about in the same request.
        // Until then each row read its whole project (`GET /projects/{uuid}`,
        // manifest and all). A list older than five minutes is read again:
        // an upload in between can take that long.
        for (position, row) in rows.enumerated() {
            // Every row reads its document on the main actor and most are
            // passed over at once: a beat for the screen every few dozen
            // rows, so a walk of a thousand is not one stall (2026-09-27).
            visited += 1
            if visited % 32 == 0 { await Task.yield() }
            guard manual ? canSync : originalsAllowed, !Task.isCancelled else { walkedWhole = false; break }
            if manual, model.stage == .processing { walkedWhole = false; break }
            if manual, wifiOnly, !isOnWiFi {
                LLog("picplace: originals queue — waiting for Wi-Fi")
                manualOriginalsWaiting = true
                walkedWhole = false
                break
            }
            // The drawer's Pause holds a person's run too: the project being
            // sent finishes, the next one waits for Resume.
            if sendsPaused {
                LLog("picplace: originals queue — paused")
                walkedWhole = false
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
            let known = await heavyListReadAhead(for: origin, after: position, in: rows)
            switch await heavySetOnPicPlace(listing, origin: origin, folder: folder, assets: known) {
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
                walkedWhole = false
                break
            }
            if records[origin]?.lastError != nil {
                // One failure stops the walk; the next check re-arms the
                // queue and this project waits out its backoff.
                updateAutoError()
                walkedWhole = false
                break
            }
            updateAutoError()
        }
        if autoStatus?.hasPrefix("Uploading originals") == true { autoStatus = nil }
        return walkedWhole
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

    /// Skipped, as the originals walk is, when nothing has moved since the
    /// last whole walk; `force` for what the key cannot see.
    func scheduleBlendsQueue(force: Bool = false) {
        guard heavyChecksAllowed, blendsQueueTask == nil else { return }
        if !force, walkIsFresh(blendsWalkSeen) { return }
        let key = currentWalkKey
        blendsQueueTask = Task { [weak self] in
            guard let self else { return }
            if await runBlendsQueue() { blendsWalkSeen = (key, Date()) }
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
            scheduleBlendsQueue(force: true)
        }
    }

    /// Whether a working copy may be rendered on its own right now (picture
    /// tiers, stage 1): every rule an automatic send keeps, and on iOS the
    /// charger — a full-size render per project is GPU time and heat, and
    /// the sweep over an old library is hours of it. The Mac renders
    /// whenever the rules hold.
    var proxyRendersAllowed: Bool {
        guard heavyChecksAllowed else { return false }
        // A render per project back to back is heat; the sweep stands down
        // at `serious` and carries on when the device has cooled (the walk
        // resumes where the rules let it).
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: return false
        default: break
        }
        #if os(iOS)
        if proxySweepIgnoresCharger { return true }
        UIDevice.current.isBatteryMonitoringEnabled = true
        switch UIDevice.current.batteryState {
        case .charging, .full: return true
        default: return false
        }
        #else
        return true
        #endif
    }

    /// The working-copy sweep (docs/picture-tiers-plan.md stage 1): every
    /// project whose originals are here and whose working copy on PicPlace
    /// is missing or stale gets one rendered and pushed — newest first, one
    /// at a time, through the ordinary records push (the walk finds the new
    /// file beside the poster), while the rules hold. Skipped, as the blends
    /// walk is, when nothing moved since the last whole walk.
    func scheduleProxyQueue(force: Bool = false) {
        guard proxyRendersAllowed, proxyQueueTask == nil else { return }
        if !force, walkIsFresh(proxyWalkSeen) { return }
        let key = currentWalkKey
        proxyQueueTask = Task { [weak self] in
            guard let self else { return }
            if await runProxyQueue() { proxyWalkSeen = (key, Date()) }
            proxyQueueTask = nil
        }
    }

    /// True when it walked every project — what `scheduleProxyQueue`
    /// remembers the walk by. An exempt project (its own working copy, D6)
    /// is passed over; a stale copy of one on PicPlace is stage 3's to
    /// delete. A copy another device sent is read off the index row's
    /// pointer (push 1) and noted without a render.
    private func runProxyQueue() async -> Bool {
        guard let libraryIndex = model.libraryIndex else { return false }
        var query = LibraryIndex.ProjectQuery()
        query.limit = 100_000
        query.sort = .created
        query.ascending = false
        let rows = (try? libraryIndex.projects(query).rows) ?? []
        let now = Date()
        var visited = 0
        var sent = 0
        var walkedWhole = true
        // Push 2's batch path: render, then a hundred copies per negotiate
        // and confirm, no claim, under the race rule (stage 3). Before it,
        // one ordinary records push per project.
        let batched = serverHasRenditionBatches && serverRenditionKinds.contains(PicPlaceSyncInventory.proxyKind)
        var batch: [(item: PicPlaceRenditionItem, origin: UUID, token: String, title: String)] = []
        func flush() async {
            guard !batch.isEmpty else { return }
            // The files stay on disk whatever happens here: a batch not sent
            // (the rules moved while rendering) is found by name next time.
            guard heavyChecksAllowed else { batch.removeAll(); return }
            autoStatus = "Sending \(batch.count) working cop\(batch.count == 1 ? "y" : "ies") to PicPlace"
            let outcomes = await sendRenditions(batch.map(\.item))
            var sentNow = 0
            for entry in batch {
                switch outcomes[entry.item.key] ?? .failed("no answer") {
                case .held, .uploaded:
                    records[entry.origin]?.proxyToken = entry.token
                    sentNow += 1
                case .staleRevision(let current):
                    LLog("picplace: working copy of \(entry.title) — this device is behind PicPlace (revision \(current)); the next check pulls, then it is sent again")
                case .failed(let why):
                    LLog("picplace: working copy of \(entry.title) — \(why)")
                }
            }
            if sentNow > 0 { saveSyncState() }
            sent += sentNow
            batch.removeAll()
        }
        for row in rows {
            visited += 1
            if visited % 32 == 0 { await Task.yield() }
            guard proxyRendersAllowed, !Task.isCancelled else { walkedWhole = false; break }
            guard let capture = model.capture(id: row.id), capture.kind == .photos, !model.sourcesMissing(capture) else { continue }
            let origin = model.originID(of: capture)
            guard let record = records[origin], record.recordsReachedServer, record.elsewhereLibrary == nil,
                  record.revision == revision(of: capture) else { continue }
            if let due = record.retryDueAt, due > now { continue }
            guard syncTasks[capture.id] == nil, !removingProjects.contains(capture.id), uploadJobs[capture.id] == nil else { continue }
            guard let token = currentProxyToken(for: capture) else { continue }
            if record.proxyToken == token { continue }
            let name = ProjectFileRegistry.proxyPictureName(token: PicPlaceSyncRun.proxyNameToken(for: token))
            if serverHasRenditions, serverRenditions[origin]?.proxy?.name == name {
                records[origin]?.proxyToken = token
                saveSyncState()
                continue
            }
            autoStatus = "Rendering working copy · \(capture.displayTitle)"
            LLog("picplace: working-copy sweep — \(capture.displayTitle)")
            if batched {
                guard let source = model.thumbnailURL(for: capture) else { continue }
                let folder = model.projectFolderURL(for: capture)
                guard let url = await PicPlaceProxy.ensure(sourceURL: source, grade: model.photoGrade(for: capture),
                                                           nameToken: PicPlaceSyncRun.proxyNameToken(for: token), in: folder) else { continue }
                guard let hashes = try? await Task.detached(priority: .utility, operation: { try PicPlaceSyncRun.hashes(of: url) }).value,
                      let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil else { continue }
                // The copy PicPlace holds now, retired when this one confirms.
                let previous = serverRenditions[origin]?.proxy
                batch.append((PicPlaceRenditionItem(
                    origin: origin, kind: PicPlaceSyncInventory.proxyKind, name: url.lastPathComponent, url: url,
                    bytes: bytes, sha256: hashes.sha256, md5: serverHasMD5Uploads ? hashes.md5 : nil, contentType: "image/heic",
                    replaces: previous.flatMap { $0.name == url.lastPathComponent ? nil : $0.id }), origin, token, capture.displayTitle))
                if batch.count >= 100 { await flush() }
            } else {
                await syncAndWait(capture, policy: .minimal)
                sent += 1
            }
        }
        await flush()
        if autoStatus?.hasPrefix("Rendering working copy") == true || autoStatus?.hasPrefix("Sending ") == true { autoStatus = nil }
        if sent > 0 { LLog("picplace: working-copy sweep — \(sent) project(s) sent\(walkedWhole ? "" : "; stopped before the end")") }
        return walkedWhole
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
    /// True when it walked every project — what `scheduleBlendsQueue`
    /// remembers the walk by.
    private func runBlendsQueue() async -> Bool {
        guard let libraryIndex = model.libraryIndex else { return false }
        var query = LibraryIndex.ProjectQuery()
        query.limit = 100_000
        query.sort = .created
        query.ascending = false
        let rows = (try? libraryIndex.projects(query).rows) ?? []
        let now = Date()
        var visited = 0
        var walkedWhole = true
        for (position, row) in rows.enumerated() {
            // As in the originals queue: a beat for the screen every few
            // dozen rows read on the main actor (2026-09-27).
            visited += 1
            if visited % 32 == 0 { await Task.yield() }
            guard heavyChecksAllowed, !Task.isCancelled else { walkedWhole = false; break }
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
                let known = await heavyListReadAhead(for: origin, after: position, in: rows, sentSetsOnly: true)
                switch await heavySetOnPicPlace(listing, origin: origin, folder: folder, assets: known) {
                case .verified:
                    records[origin]?.heavyDigest = wholeDigest
                    records[origin]?.verifyPendingSince = nil
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
                walkedWhole = false
                break
            }
            if records[origin]?.lastError != nil {
                updateAutoError()
                walkedWhole = false
                break
            }
            // The set was whole before the blend: with the blend there it is
            // whole again — the green tick now, not at the next check. One
            // PicPlace is still reading back waits for `scheduleHeavyRecheck`.
            if wholeSet, case .verified = await heavySetOnPicPlace(listing, origin: origin, folder: folder) {
                records[origin]?.heavyDigest = wholeDigest
                records[origin]?.verifyPendingSince = nil
                saveSyncState()
            }
        }
        if autoStatus?.hasPrefix("Uploading blends") == true { autoStatus = nil }
        return walkedWhole
    }

    // MARK: The look right after an upload (2026-09-26)

    /// A heavy push left PicPlace reading files back: this project alone is
    /// looked at again every 10 s for two minutes, every 30 s to five, then
    /// every minute to thirty (a large upload takes PicPlace longer to read
    /// back) — whatever the automatic rules, since it is one read after the
    /// person's own upload — so the pill's *checking* turns to ✓ within
    /// seconds of PicPlace finishing (Steven: "it's just completed, but this
    /// takes a minute or two"; the iPad's first single photo: verified 63 s
    /// after its upload on a 5/15/30/60 s schedule, PicPlace done between
    /// the last two looks). The blends queue's look stays the backstop.
    func verifyAfterUpload(_ captureID: UUID) {
        // One look for every project waiting, not a loop per project
        // (2026-10-01): each used to read its own `GET /projects/{uuid}` up to
        // 43 times over the half hour — on Hetzner, where PicPlace reads
        // every upload back, a migration would have started one such loop per
        // project. The sweep asks for all of them at once, a hundred
        // projects per request (`POST /projects/assets`).
        verifyPending[captureID] = Date()
        guard verifySweep == nil else { return }
        verifySweep = Task { [weak self] in
            while let self, !Task.isCancelled, !self.verifyPending.isEmpty {
                // As often as the youngest wait asks: every 10 s for two
                // minutes, every 30 s to five, then every minute to thirty.
                let youngest = self.verifyPending.values.map { Date().timeIntervalSince($0) }.min() ?? 0
                let delay: Double = youngest < 120 ? 10 : youngest < 300 ? 30 : 60
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                await self.sweepVerifications()
            }
            self?.verifySweep = nil
        }
    }

    /// One pass over the projects whose upload PicPlace was still reading
    /// back: their heavy lists in one batched read, then each judged as
    /// before.
    private func sweepVerifications() async {
        guard canSync else { return }
        var waiting: [(captureID: UUID, origin: UUID, capture: AppModel.CaptureProject, since: Date)] = []
        for (captureID, since) in verifyPending {
            guard let capture = model.capture(id: captureID) else { verifyPending[captureID] = nil; continue }
            let origin = model.originID(of: capture)
            guard records[origin]?.verifyPendingSince != nil else { verifyPending[captureID] = nil; continue }
            if Date().timeIntervalSince(since) >= PicPlaceSyncRecord.verifyWindow {
                // Thirty minutes: the pill says what the markers say, and the
                // next walk looks again.
                records[origin]?.verifyPendingSince = nil
                saveSyncState()
                verifyPending[captureID] = nil
                LLog("picplace: \(capture.displayTitle) — PicPlace still checking the upload after thirty minutes; left to the next look")
                continue
            }
            waiting.append((captureID, origin, capture, since))
        }
        guard !waiting.isEmpty else { return }
        let lists = await heavyAssetLists(for: waiting.map(\.origin))
        for item in waiting {
            let folder = model.projectFolderURL(for: item.capture)
            let listing = await Task.detached(priority: .utility) { Self.heavyFiles(in: folder) }.value
            guard !listing.isEmpty else { verifyPending[item.captureID] = nil; continue }
            switch await heavySetOnPicPlace(listing, origin: item.origin, folder: folder, assets: lists[item.origin]) {
            case .verified:
                records[item.origin]?.heavyDigest = PicPlaceOriginalsCheck.digest(listing)
                let blends = listing.filter { $0.kind == .blend }
                if !blends.isEmpty { records[item.origin]?.blendsDigest = PicPlaceOriginalsCheck.digest(blends) }
                records[item.origin]?.verifyPendingSince = nil
                heavySetMissing[item.origin] = nil
                saveSyncState()
                LLog("picplace: \(item.capture.displayTitle) — PicPlace finished checking the upload: all \(listing.count) heavy file(s) verified \(Int(Date().timeIntervalSince(item.since))) s after it ended — backed up")
                verifyPending[item.captureID] = nil
            case .checking:
                continue
            case .missing:
                records[item.origin]?.verifyPendingSince = nil
                saveSyncState()
                LLog("picplace: \(item.capture.displayTitle) — after the upload PicPlace lacks some of it: needs uploading")
                verifyPending[item.captureID] = nil
            }
        }
    }

    /// A project's heavy list for a queue's walk, read with the lists of the
    /// rows after it that have never been verified — a hundred projects per
    /// request, shared by the originals and the blends queues, which walk
    /// the same library from opposite ends. nil when PicPlace did not answer
    /// for it: the caller reads the project on its own. A list is used once,
    /// and nothing older than five minutes is used at all (an upload in
    /// between can take that long).
    private func heavyListReadAhead(for origin: UUID, after position: Int, in rows: [LibraryIndex.ProjectRow],
                                    sentSetsOnly: Bool = false) async -> [PPAsset]? {
        if Date().timeIntervalSince(heavyAheadReadAt) > 300 { heavyAhead = [:] }
        if heavyAhead[origin] == nil {
            var asking = [origin]
            for later in rows[(position + 1)...] where asking.count < 100 {
                guard let other = model.capture(id: later.id) else { continue }
                let otherOrigin = model.originID(of: other)
                // Never a preview pulled from PicPlace whose originals were
                // never brought here: it has nothing heavy to verify, and on a
                // device that is mostly previews the read-ahead would fetch a
                // hundred lists to use one (the 16 Pro, 2026-10-01: 574 KB).
                guard heavyAhead[otherOrigin] == nil, let record = records[otherOrigin], record.recordsReachedServer,
                      record.elsewhereLibrary == nil, record.heavyDigest == nil,
                      !(record.policy == "pull" && record.originalsMovedAt == nil) else { continue }
                // The blends queue only ever looks at a set this device sent
                // or fetched, or one another device sent: with originals off
                // nothing else will be asked about, and reading ahead for it
                // fetched a hundred lists to use one (the 18 Pro, 780 KB).
                if sentSetsOnly, record.originalsMovedAt == nil, (record.serverHeavyFiles ?? 0) == 0 { continue }
                asking.append(otherOrigin)
            }
            let read = await heavyAssetLists(for: asking)
            if Date().timeIntervalSince(heavyAheadReadAt) > 300 { heavyAhead = [:] }
            heavyAhead.merge(read) { _, new in new }
            heavyAheadReadAt = Date()
        }
        return heavyAhead.removeValue(forKey: origin)
    }

    /// The confirmed heavy assets (sources and blends) of many projects, by
    /// origin, a hundred projects per request. A project PicPlace did not
    /// answer for is absent — the caller then reads it on its own, as
    /// before. Empty for a server without the batched read.
    func heavyAssetLists(for origins: [UUID]) async -> [UUID: [PPAsset]] {
        guard serverListsAssetsInBatches, !origins.isEmpty else { return [:] }
        var lists: [UUID: [PPAsset]] = [:]
        var pending = origins.map { $0.uuidString.lowercased() }
        while !pending.isEmpty {
            let chunk = Array(pending.prefix(100))
            guard let answer: PPAssetLists = try? await client.post("projects/assets", json: [
                "uuids": chunk,
                "kinds": [PicPlaceOriginalsCheck.Kind.source.rawValue, PicPlaceOriginalsCheck.Kind.blend.rawValue],
            ]) else { break }
            for entry in answer.projects where entry.error == nil {
                if let origin = UUID(uuidString: entry.uuid) { lists[origin] = entry.assets ?? [] }
            }
            // `next` is what the size cap left of this chunk; a cap that
            // answered nothing of it would ask forever — move on.
            let next = (answer.next ?? []).map { $0.lowercased() }
            pending = (next.count < chunk.count ? next : []) + Array(pending.dropFirst(chunk.count))
        }
        return lists
    }

    /// Looks the app was killed in the middle of (a relaunch within the
    /// window) go on — the check's end calls this.
    func resumePendingVerifications() {
        let now = Date()
        let pending = records.filter { $0.value.verifyPendingSince.map { now.timeIntervalSince($0) < PicPlaceSyncRecord.verifyWindow } == true }.map(\.key)
        guard !pending.isEmpty else { return }
        var rows: [LibraryIndex.ProjectRow]?
        for origin in pending {
            // A project made here has its origin id for its id; a copy is
            // found through the index.
            var captureID: UUID? = model.capture(id: origin) != nil ? origin : nil
            if captureID == nil, let libraryIndex = model.libraryIndex {
                if rows == nil {
                    var query = LibraryIndex.ProjectQuery()
                    query.limit = 100_000
                    rows = (try? libraryIndex.projects(query).rows) ?? []
                }
                captureID = rows?.first { $0.originID == origin }?.id
            }
            if let captureID, verifyPending[captureID] == nil { verifyAfterUpload(captureID) }
        }
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
    private func heavySetOnPicPlace(_ listing: [PicPlaceOriginalsCheck.LocalFile], origin: UUID, folder: URL,
                                    assets given: [PPAsset]? = nil) async -> HeavySetState {
        let assets: [PPAsset]?
        if let given {
            // Read a moment ago with other projects' (`heavyAssetLists`).
            assets = given
        } else {
            let detail: PPProjectDetail
            // A read that failed says nothing about PicPlace: not known yet.
            do { detail = try await client.get("projects/\(origin.uuidString.lowercased())") } catch { return .checking }
            assets = detail.assets
        }
        let remote = Self.remoteHeavy(assets)
        serverHeavy[origin] = remote
        guard PicPlaceOriginalsCheck.notCovered(listing, by: remote).isEmpty else { return .missing }
        guard let hashed = try? await Task.detached(priority: .utility, operation: { try Self.hashed(listing, in: folder) }).value else { return .missing }
        let verdict = PicPlaceOriginalsCheck.verify(hashed, against: remote)
        return verdict.passes ? .verified : verdict.awaitsVerification ? .checking : .missing
    }
}
