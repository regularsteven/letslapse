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
/// every project whose originals are only here; **Wi-Fi only** (iOS,
/// on by default) gates the originals. A shoot being written pauses all of
/// it; downloads of originals stay per project.
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
        #if os(iOS)
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let wifi = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
            Task { @MainActor in
                guard let self else { return }
                let was = self.isOnWiFi
                self.isOnWiFi = wifi && !path.isExpensive
                if was != self.isOnWiFi { self.autoSyncSettingChanged() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "picplace.path"))
        pathMonitorBox = monitor
        #endif
    }

    /// A switch or a condition moved: stop what is no longer allowed, start
    /// what now is.
    func autoSyncSettingChanged() {
        if !autoSyncEnabled {
            for task in pendingPushes.values { task.cancel() }
            pendingPushes.removeAll()
        }
        if !originalsAllowed {
            originalsQueueTask?.cancel()
            originalsQueueTask = nil
            if autoStatus?.hasPrefix("Uploading originals") == true { autoStatus = nil }
        } else {
            scheduleOriginalsQueue()
        }
    }

    /// Whether the originals may move right now.
    var originalsAllowed: Bool {
        guard autoSyncEnabled, autoOriginalsEnabled, canSync, model.stage != .processing else { return false }
        #if os(iOS)
        if wifiOnly, !isOnWiFi { return false }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return false }
        #endif
        return true
    }

    /// Why the originals are not moving, for the status line.
    var originalsHold: String? {
        guard autoSyncEnabled, autoOriginalsEnabled else { return nil }
        if !canSync { return "not connected" }
        if model.stage == .processing { return "paused while a shoot runs" }
        #if os(iOS)
        if wifiOnly, !isOnWiFi { return "waiting for Wi-Fi" }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return "paused in Low Power Mode" }
        #endif
        return nil
    }

    // MARK: Edits

    /// A project's document changed on disk. Twenty seconds after the last
    /// change, the project goes up — if it actually moved past the base
    /// (a pull writes the document too, and must not bounce back).
    func noteProjectChanged(_ id: UUID) {
        guard autoSyncEnabled, canSync, binding?.initialSync.state == .done else { return }
        pendingPushes[id]?.cancel()
        pendingPushes[id] = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(Self.pushDebounce * 1_000_000_000)) } catch { return }
            guard let self else { return }
            self.pendingPushes[id] = nil
            await self.pushIfMoved(id)
        }
    }

    private func pushIfMoved(_ id: UUID) async {
        guard canSync, model.stage != .processing, syncTasks[id] == nil, checkTask == nil, initialSyncTask == nil,
              let capture = model.capture(id: id) else { return }
        let origin = model.originID(of: capture)
        if conflicts.contains(where: { $0.originID == origin }) { return }
        let base = records[origin]?.revision
        guard base == nil || revision(of: capture) != base else { return }
        // A project pushed by the check moments ago with the same stamp is in step.
        autoStatus = "Syncing \(capture.displayTitle)…"
        await syncAndWait(capture)
        if let error = records[origin]?.lastError {
            autoStatus = "\(capture.displayTitle): \(error)"
        } else {
            autoStatus = nil
            scheduleOriginalsQueue()
        }
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
        for row in rows {
            guard originalsAllowed, !Task.isCancelled else { break }
            guard let capture = model.capture(id: row.id), records[model.originID(of: capture)] != nil else { continue }
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
            if let error = records[origin]?.lastError {
                autoStatus = "\(capture.displayTitle): \(error)"
                break
            }
        }
        if autoStatus?.hasPrefix("Uploading originals") == true { autoStatus = nil }
    }
}
