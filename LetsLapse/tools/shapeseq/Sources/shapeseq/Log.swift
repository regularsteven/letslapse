import Foundation

/// Run log: every line goes to stdout and to `<out>/run-log.txt`.
/// Anomalies in the catalogue are log lines, never crashes.
final class RunLog: @unchecked Sendable {
    private let handle: FileHandle?
    private let lock = NSLock()
    private let started = Date()
    private(set) var counts: [String: Int] = [:]

    init(url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
        line("=== shapeseq run \(ISO8601DateFormatter().string(from: started)) ===")
    }

    func line(_ s: String) {
        let stamp = String(format: "%8.2fs", Date().timeIntervalSince(started))
        let text = "[\(stamp)] \(s)\n"
        lock.lock(); defer { lock.unlock() }
        FileHandle.standardOutput.write(text.data(using: .utf8)!)
        handle?.write(text.data(using: .utf8)!)
    }

    /// Tagged anomaly — counted so the report can summarise skips/failures.
    func note(_ tag: String, _ s: String) {
        lock.lock(); counts[tag, default: 0] += 1; lock.unlock()
        line("\(tag): \(s)")
    }

    func close() {
        line("=== end (\(String(format: "%.1f", Date().timeIntervalSince(started))) s) ===")
        try? handle?.close()
    }
}
