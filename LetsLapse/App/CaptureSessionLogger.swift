import Foundation
#if os(iOS)
import UIKit
#endif

/// A crash-safe record of one capture session.
///
/// Every session opens `capture-<UUID>.log` in Application Support and appends
/// one JSON object per line (newline-delimited JSON): a crash can only ever
/// truncate the last line, never corrupt the ones already on disk. Each append
/// is a single small `write` at the end of the file, so there is no rewrite
/// window in which the file is invalid.
///
/// The file is DELETED when a session finishes normally — so a log that
/// survives to the next launch means the app died with the camera open. Those
/// leftovers are what Settings ▸ Incomplete Captures shows.
///
/// Every mutating entry point hops onto `queue`, so the logger is safe to call
/// from `sessionQueue`, the main queue, or a WatchConnectivity delegate queue.
/// The `@Published` orphan list is only ever written on the main queue.
final class CaptureSessionLogger: ObservableObject {
    static let shared = CaptureSessionLogger()

    /// A log file left behind by a crash or force-quit, summarised for the
    /// list screen. `text` is not held here — detail loads it on demand.
    struct OrphanedLog: Identifiable, Equatable {
        var url: URL
        var startedAt: Date?
        var lastEventAt: Date?
        var lastEvent: String
        var eventCount: Int
        var mode: String?
        var byteCount: Int

        var id: String { url.lastPathComponent }
        var fileName: String { url.lastPathComponent }

        /// How long the session ran before it stopped writing — last event
        /// minus first. Nil when the log holds fewer than two stamped events.
        var duration: TimeInterval? {
            guard let startedAt, let lastEventAt else { return nil }
            return max(0, lastEventAt.timeIntervalSince(startedAt))
        }
    }

    /// One parsed line of a log, for the detail screen.
    struct Event: Identifiable {
        var id: Int
        var timestamp: Date?
        var name: String
        /// The event's `data` object re-encoded compactly, or "" when empty.
        var detail: String
        /// The line exactly as written — what a line that failed to parse
        /// still shows, so nothing is silently dropped.
        var raw: String
        /// Seconds since the log's first event, filled in by `events(in:)`.
        var offset: TimeInterval?
    }

    /// The capture setup as it stood at one moment. Composed by the caller so
    /// the logger never reaches into AVFoundation itself.
    struct FormatSnapshot: Equatable {
        var width: Int
        var height: Int
        var fps: Int
        var codec: String
        var stabilization: String?
        var appleLog: Bool?
        var lens: String?
        var mode: String?

        var dictionary: [String: Any] {
            var data: [String: Any] = [
                "resolution": "\(width)x\(height)",
                "width": width,
                "height": height,
                "fps": fps,
                "codec": codec,
            ]
            if let stabilization { data["stabilization"] = stabilization }
            if let appleLog { data["appleLog"] = appleLog }
            if let lens { data["lens"] = lens }
            if let mode { data["mode"] = mode }
            return data
        }
    }

    /// Who asked a running capture to stop. `phone` and `watch` are the two
    /// the spec cares about; `scheduled` (a "stop at…" deadline firing) and
    /// `rig` (the test-card runner) are named rather than being mislabelled
    /// as a user press.
    enum StopSource: String {
        case phone
        case watch
        case scheduled
        case rig
    }

    /// Logs left behind by a previous run. Seeded by `scanForOrphanedLogs()`
    /// at launch and refreshed whenever the Settings screen acts on one.
    @Published private(set) var orphanedLogs: [OrphanedLog] = []

    private let queue = DispatchQueue(label: "com.letslapse.capture-session-log", qos: .utility)

    // queue-confined.
    private var handle: FileHandle?
    private var activeURL: URL?
    private var sessionStartedAt: Date?
    private var lastLoggedFormat: FormatSnapshot?

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private init() {}

    // MARK: - Location

    /// `Application Support/LetsLapse/CaptureLogs`. Alongside the Live Blend
    /// experiment logs, and deliberately NOT in `tmp` — the whole point is to
    /// still be there after the crash that ended the session.
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("LetsLapse", isDirectory: true)
            .appendingPathComponent("CaptureLogs", isDirectory: true)
    }

    // MARK: - Writing

    /// Opens a fresh log and writes `session_start`. A session already open
    /// (the capture screen restarting the camera) is closed and deleted first:
    /// it ended without a crash, so it is not an orphan.
    func beginSession(mode: String, format: FormatSnapshot) {
        let deviceData = Self.deviceData()
        queue.async {
            if self.handle != nil {
                self.closeSessionOnQueue(reason: "restarted", frameCount: nil, delete: true)
            }
            let directory = Self.directory
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                LLog("capture log: couldn't create \(directory.path) — \(error.localizedDescription)")
                return
            }
            let url = directory.appendingPathComponent("capture-\(UUID().uuidString).log")
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                LLog("capture log: couldn't create \(url.lastPathComponent)")
                return
            }
            guard let handle = try? FileHandle(forWritingTo: url) else {
                LLog("capture log: couldn't open \(url.lastPathComponent) for writing")
                return
            }
            let now = Date()
            self.handle = handle
            self.activeURL = url
            self.sessionStartedAt = now
            self.lastLoggedFormat = format

            var data = deviceData
            data["mode"] = mode
            data["format"] = format.dictionary
            self.appendOnQueue(event: "session_start", data: data, at: now)
        }
    }

    /// Appends one event. A no-op when no session is open, so hooks can call
    /// it unconditionally (the Watch receiver runs with the camera closed).
    func log(_ event: String, _ data: [String: Any] = [:]) {
        let now = Date()
        queue.async {
            guard self.handle != nil else { return }
            self.appendOnQueue(event: event, data: data, at: now)
        }
    }

    /// `format_change`, deduplicated: the camera re-publishes its format after
    /// every reconfiguration — including each segment switch inside a burst —
    /// and a log full of identical lines hides the changes that mattered.
    func logFormatChange(_ snapshot: FormatSnapshot) {
        let now = Date()
        queue.async {
            guard self.handle != nil, self.lastLoggedFormat != snapshot else { return }
            self.lastLoggedFormat = snapshot
            self.appendOnQueue(event: "format_change", data: snapshot.dictionary, at: now)
        }
    }

    /// Writes `session_end` and deletes the log — the session finished, so
    /// there is nothing to recover. `frameCount` is whatever the run can
    /// honestly report (recorded segments, stills, blended outputs); omit it
    /// rather than guessing.
    func endSession(reason: String = "normal", frameCount: Int? = nil) {
        queue.async {
            guard self.handle != nil else { return }
            self.closeSessionOnQueue(reason: reason, frameCount: frameCount, delete: true)
        }
    }

    /// queue-confined. `session_end`, close, and (normally) remove the file.
    private func closeSessionOnQueue(reason: String, frameCount: Int?, delete: Bool) {
        var data: [String: Any] = ["reason": reason]
        if let sessionStartedAt {
            data["elapsedSeconds"] = Date().timeIntervalSince(sessionStartedAt)
        }
        if let frameCount { data["frameCount"] = frameCount }
        appendOnQueue(event: "session_end", data: data, at: Date())

        try? handle?.close()
        if delete, let activeURL {
            try? FileManager.default.removeItem(at: activeURL)
        }
        handle = nil
        activeURL = nil
        sessionStartedAt = nil
        lastLoggedFormat = nil
    }

    /// queue-confined. One line, appended at the end of the file.
    private func appendOnQueue(event: String, data: [String: Any], at date: Date) {
        guard let handle else { return }
        var object: [String: Any] = [
            "t": Self.timestampFormatter.string(from: date),
            "event": event,
        ]
        if !data.isEmpty { object["data"] = Self.jsonSafe(data) }
        // Offsets make a log readable without doing date arithmetic by hand.
        if let sessionStartedAt, event != "session_start" {
            object["offset"] = Self.jsonSafe(date.timeIntervalSince(sessionStartedAt))
        }
        guard var line = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return
        }
        line.append(0x0A)
        // seekToEnd + write: one syscall per event, appended to what is
        // already durable. Nothing earlier in the file is ever rewritten.
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            LLog("capture log: write failed — \(error.localizedDescription)")
        }
    }

    /// JSONSerialization throws on anything it can't encode — a non-finite
    /// Double (an unmetered shutter speed reads as infinity), an enum, a URL.
    /// Coerce rather than lose the event.
    ///
    /// Doubles go through a decimal on the way out: JSONSerialization prints a
    /// rounded binary Double at full precision (`9.017` becomes
    /// `9.0169999999999995`), and this log is read by people.
    private static func jsonSafe(_ value: Any) -> Any {
        switch value {
        case let dictionary as [String: Any]:
            return dictionary.mapValues { jsonSafe($0) }
        case let array as [Any]:
            return array.map { jsonSafe($0) }
        case let double as Double:
            guard double.isFinite else { return String(describing: double) }
            if double == double.rounded(), abs(double) < 1e15 { return Int(double) }
            // 6 dp: enough for a 1/8000 shutter, and trailing zeros normalize
            // away so a plain offset still reads as "9.017".
            return NSDecimalNumber(string: String(format: "%.6f", double))
        case let float as Float:
            return jsonSafe(Double(float))
        case is Int, is Bool, is String:
            return value
        case let number as NSNumber:
            return number
        default:
            return String(describing: value)
        }
    }

    private static func deviceData() -> [String: Any] {
        let bundle = Bundle.main.infoDictionary
        var data: [String: Any] = [
            "device": hardwareIdentifier(),
            "app": [
                "version": bundle?["CFBundleShortVersionString"] as? String ?? "?",
                "build": bundle?["CFBundleVersion"] as? String ?? "?",
            ],
        ]
        #if os(iOS)
        data["system"] = "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        #else
        data["system"] = "macOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)."
            + "\(ProcessInfo.processInfo.operatingSystemVersion.minorVersion)."
            + "\(ProcessInfo.processInfo.operatingSystemVersion.patchVersion)"
        #endif
        return data
    }

    /// "iPhone17,1" / "Mac16,6" rather than the marketing name: it is what a
    /// crash report carries, so the two line up. The Mac keeps its model in
    /// `hw.model` — `uname` there only ever says "arm64".
    private static func hardwareIdentifier() -> String {
        #if targetEnvironment(simulator)
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return "\(simulated) (simulator)"
        }
        #endif
        #if os(macOS)
        if let model = sysctlString("hw.model") { return model }
        #endif
        var systemInfo = utsname()
        uname(&systemInfo)
        let identifier = withUnsafeBytes(of: &systemInfo.machine) { raw -> String in
            guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return "" }
            return String(cString: base)
        }
        return identifier.isEmpty ? "unknown" : identifier
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(cString: buffer)
        return value.isEmpty ? nil : value
    }

    // MARK: - Reading orphans

    /// Every `.log` in the directory that isn't the session currently being
    /// written. Call at launch — anything found then outlived its process.
    @discardableResult
    func scanForOrphanedLogs() -> [OrphanedLog] {
        let active = queue.sync { activeURL }
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: Self.directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles])) ?? []

        let logs = urls
            .filter { $0.pathExtension == "log" && $0 != active }
            .compactMap { Self.summarize($0) }
            .sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }

        publish(logs)
        return logs
    }

    private func publish(_ logs: [OrphanedLog]) {
        if Thread.isMainThread {
            orphanedLogs = logs
        } else {
            DispatchQueue.main.async { self.orphanedLogs = logs }
        }
    }

    /// Reads a log start-to-end for its summary. These files are a few KB at
    /// most — one event per user action, not per frame.
    private static func summarize(_ url: URL) -> OrphanedLog? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty else { return nil }

        var startedAt: Date?
        var lastEventAt: Date?
        var lastEvent = "—"
        var mode: String?
        var count = 0

        for line in lines {
            count += 1
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if let stamp = (object["t"] as? String).flatMap({ timestampFormatter.date(from: $0) }) {
                if startedAt == nil { startedAt = stamp }
                lastEventAt = stamp
            }
            if let event = object["event"] as? String { lastEvent = event }
            if mode == nil, let payload = object["data"] as? [String: Any] {
                mode = payload["mode"] as? String
            }
        }

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? text.utf8.count
        return OrphanedLog(
            url: url,
            startedAt: startedAt,
            lastEventAt: lastEventAt,
            lastEvent: lastEvent,
            eventCount: count,
            mode: mode,
            byteCount: size)
    }

    /// The log exactly as written — what "Copy All" puts on the clipboard.
    func rawText(of url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// Parsed lines for the detail list. Unparseable lines survive as their
    /// raw text rather than disappearing.
    func events(in url: URL) -> [Event] {
        let lines = rawText(of: url).split(separator: "\n", omittingEmptySubsequences: true)
        var events: [Event] = []
        var first: Date?

        for (index, line) in lines.enumerated() {
            let raw = String(line)
            guard let data = raw.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = object["event"] as? String
            else {
                events.append(Event(id: index, timestamp: nil, name: "unparsed", detail: "", raw: raw, offset: nil))
                continue
            }
            let stamp = (object["t"] as? String).flatMap { Self.timestampFormatter.date(from: $0) }
            if first == nil { first = stamp }

            var detail = ""
            if let payload = object["data"] as? [String: Any], !payload.isEmpty,
               let encoded = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
               let string = String(data: encoded, encoding: .utf8) {
                detail = string
            }
            events.append(Event(
                id: index,
                timestamp: stamp,
                name: name,
                detail: detail,
                raw: raw,
                offset: (stamp != nil && first != nil) ? stamp!.timeIntervalSince(first!) : nil))
        }
        return events
    }

    // MARK: - Deleting orphans

    func delete(_ log: OrphanedLog) {
        try? FileManager.default.removeItem(at: log.url)
        scanForOrphanedLogs()
    }

    func deleteAllOrphanedLogs() {
        for log in orphanedLogs {
            try? FileManager.default.removeItem(at: log.url)
        }
        scanForOrphanedLogs()
    }
}
