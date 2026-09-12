#if os(macOS)
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import LetsLapseKit

// The benchmark rig's own detectors, run on one picture from the Mac app —
// `tools/shapebench/shapebench.py detect-one` — so a candidate method can be
// looked at in the app before it is ported (the Python engines of
// `ShapeDetectionMode`, 2026-09-12). A developer's tool on this Mac, never a
// path that ships: it needs the repository checkout and its Python venv.

enum ExternalShapeDetector {
    /// Settings ▸ Advanced: the repository's `LetsLapse/tools` folder, which
    /// holds `.venv/` and `shapebench/`.
    static let rigFolderKey = "shapes.rigToolsFolder"

    struct Result: Sendable {
        var shapes: [DetectedShape]
        /// The whole call, Python start-up included.
        var durationMs: Int
        /// The detector alone, as the rig measured it.
        var detectorMs: Int?
        var candidates: Int?
        var detector: String
        var paramsHash: String
    }

    enum Failure: LocalizedError {
        case rigNotFound
        case failed(status: Int32, stderr: String)
        case badOutput

        var errorDescription: String? {
            switch self {
            case .rigNotFound: return "The shape benchmark rig was not found. Choose the repository's LetsLapse/tools folder in Settings ▸ Advanced."
            case .failed(let status, let stderr):
                let tail = stderr.split(separator: "\n").suffix(3).joined(separator: " · ")
                return "The Python detector exited with status \(status)" + (tail.isEmpty ? "" : ": \(tail)")
            case .badOutput: return "The Python detector's output could not be read."
            }
        }
    }

    /// The tools folder, if one is set or found: the stored path first, then
    /// the usual checkout under the home folder.
    static func toolsFolder() -> URL? {
        var candidates: [URL] = []
        if let stored = UserDefaults.standard.string(forKey: rigFolderKey), !stored.isEmpty {
            candidates.append(URL(fileURLWithPath: stored))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        candidates.append(home.appendingPathComponent("Documents/dev/letslapse/LetsLapse/tools"))
        return candidates.first(where: isRig)
    }

    static func isRig(_ tools: URL) -> Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: python(in: tools).path) && fm.fileExists(atPath: script(in: tools).path)
    }

    static func python(in tools: URL) -> URL { tools.appendingPathComponent(".venv/bin/python") }
    static func script(in tools: URL) -> URL { tools.appendingPathComponent("shapebench/shapebench.py") }

    static var isAvailable: Bool { toolsFolder() != nil }

    /// One line for Settings and the pickers.
    static var availability: (ok: Bool, detail: String) {
        if let tools = toolsFolder() { return (true, tools.path) }
        return (false, "Rig not found — choose the repository's LetsLapse/tools folder")
    }

    /// One picture through one rig detector. Blocks for the run (a second or
    /// three); call it off the main thread.
    static func run(detectorID: String, imageURL: URL) throws -> Result {
        guard let tools = toolsFolder() else { throw Failure.rigNotFound }
        let started = Date()
        let process = Process()
        process.executableURL = python(in: tools)
        process.arguments = [script(in: tools).path, "detect-one", "--detector", detectorID, "--image", imageURL.path]
        process.currentDirectoryURL = tools.deletingLastPathComponent()
        let output = Pipe()
        process.standardOutput = output
        // stderr to a file, not a pipe: reading two pipes to their ends
        // from one thread can deadlock when the second fills first.
        let errURL = FileManager.default.temporaryDirectory.appendingPathComponent("letslapse-shapes-\(UUID().uuidString).err")
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: errURL) }
        process.standardError = try FileHandle(forWritingTo: errURL)
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let stderr = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
            throw Failure.failed(status: process.terminationStatus, stderr: stderr)
        }
        struct Envelope: Decodable {
            var detector: String
            var paramsHash: String
            var width: Int
            var height: Int
            var durationMs: Int
            var candidates: Int?
            var detectorMs: Int?
            var shapes: [DetectedShape]
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { throw Failure.badOutput }
        return Result(shapes: envelope.shapes, durationMs: Int(Date().timeIntervalSince(started) * 1000),
                      detectorMs: envelope.detectorMs, candidates: envelope.candidates,
                      detector: envelope.detector, paramsHash: envelope.paramsHash)
    }

    /// A picture file for a representative: the file itself for a still (the
    /// rig reads JPEG, HEIC, PNG and DNG), a JPEG of the middle frame written
    /// to the temporary folder for a clip — the caller removes it.
    static func stillURL(for rep: ShapeRepresentative) -> (url: URL, temporary: Bool)? {
        switch rep.source {
        case .blendImage, .sourceFrame:
            return (rep.url, false)
        case .blendVideo:
            guard let image = RepresentativeLoader.image(rep, maxPixelSize: 8192) else { return nil }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("letslapse-shapes-\(UUID().uuidString).jpg")
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
            return CGImageDestinationFinalize(destination) ? (url, true) : nil
        }
    }
}
#endif
