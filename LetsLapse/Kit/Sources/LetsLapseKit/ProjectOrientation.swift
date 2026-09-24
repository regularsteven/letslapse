import CoreGraphics
import Foundation
import ImageIO

/// The quarter turns a file inside a project folder is shown with
/// (2026-09-24): the project's own for its sources (`project.json` →
/// `capture.quarterTurns`), and for a blend rendered before a later turn,
/// the difference (`blends[].renderedQuarterTurns`). 0 for anything outside a
/// project folder — a temporary render, a scratch export, a staged corpus.
///
/// Why a lookup rather than a parameter: the turn has to reach every decoder
/// that reads a project's media — ImageIO through `OrientedDecode`, raw
/// through `LossyLinearDNG.rawFilter(for:)`, movies through their track
/// transform — and several of those sit deep in the Kit (the stacker, the
/// framing measurement, the time-slice renderer) with only a URL in hand.
/// The turn is the file's orientation *within its library*, the same kind of
/// fact as the EXIF tag ImageIO reads from the file itself; the lookup is
/// where it is read from.
///
/// Read lazily from the project document beside the file and cached per
/// folder; `forget(folder:)` drops a folder whose document was rewritten
/// (the app's document writer calls it on every write), `forgetAll()` goes
/// with a library switch. Thread-safe; lookups are string work plus, once
/// per folder, one small JSON read.
public final class ProjectOrientation: @unchecked Sendable {

    public static let shared = ProjectOrientation()

    private struct Entry {
        var turns: Int
        /// `blends/<file>` → the turns the blend was rendered at.
        var rendered: [String: Int]
        /// The same, by blend id — for `posters/<blend id>.jpg`, a removed
        /// blend's still, made from the blend as its file shows it.
        var renderedByID: [String: Int] = [:]
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    public init() {}

    /// The turns `url` is shown with: the project's for a file under
    /// `source/`; for a blend under `blends/` — and its still under
    /// `posters/` — the difference from the turn it was rendered at; 0 for
    /// everything else a project holds, `poster.jpg` above all (it is
    /// rendered from the turned picture, so the turn is in its pixels).
    public func turns(for url: URL) -> Int {
        guard let (folder, relative) = Self.projectFolder(of: url) else { return 0 }
        let isSource = relative.hasPrefix("source/")
        let isBlend = relative.hasPrefix("blends/")
        let isBlendStill = relative.hasPrefix(ProjectFileRegistry.blendPostersFolder + "/")
        guard isSource || isBlend || isBlendStill else { return 0 }
        let entry = self.entry(folder: folder)
        guard entry.turns != 0 || !entry.rendered.isEmpty else { return 0 }
        if isBlend {
            return QuarterTurns.normalized(entry.turns - (entry.rendered[relative] ?? 0))
        }
        if isBlendStill {
            let id = ((relative as NSString).lastPathComponent as NSString).deletingPathExtension.uppercased()
            return QuarterTurns.normalized(entry.turns - (entry.renderedByID[id] ?? 0))
        }
        return QuarterTurns.normalized(entry.turns)
    }

    /// The EXIF orientation to decode `url` with: the file's own, turned.
    public func orientation(for url: URL, fileOrientation: CGImagePropertyOrientation) -> CGImagePropertyOrientation {
        QuarterTurns.orientation(fileOrientation, turnedBy: turns(for: url))
    }

    /// A movie track's display transform for `url`: its own, turned.
    public func transform(for url: URL, preferred: CGAffineTransform, naturalSize: CGSize) -> CGAffineTransform {
        QuarterTurns.transform(preferred, naturalSize: naturalSize, turnedBy: turns(for: url))
    }

    /// What a cache key for `url` adds so a turned picture is a different
    /// entry: empty with no turn — no existing key moves — else `|q<turns>`.
    public func keySuffix(for url: URL) -> String {
        let turns = turns(for: url)
        return turns == 0 ? "" : "|q\(turns)"
    }

    /// Drops what is known about one project folder — its document changed.
    public func forget(folder: URL) {
        lock.lock()
        entries[folder.standardizedFileURL.path] = nil
        lock.unlock()
    }

    /// Drops everything — a library switch.
    public func forgetAll() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }

    // MARK: Folder

    /// The project folder a file sits in — `…/Projects/<uuid>/` — and the
    /// file's path within it. nil for a file outside any project folder.
    static func projectFolder(of url: URL) -> (folder: String, relative: String)? {
        let components = url.standardizedFileURL.pathComponents
        guard let index = components.lastIndex(of: "Projects"), index + 2 < components.count,
              UUID(uuidString: components[index + 1]) != nil else { return nil }
        let folder = NSString.path(withComponents: Array(components[...(index + 1)]))
        let relative = components[(index + 2)...].joined(separator: "/")
        return (folder, relative)
    }

    private func entry(folder: String) -> Entry {
        lock.lock()
        if let known = entries[folder] {
            lock.unlock()
            return known
        }
        lock.unlock()
        let read = Self.read(folder: folder)
        lock.lock()
        entries[folder] = read
        lock.unlock()
        return read
    }

    /// `project.json`'s turns — tolerant: a missing or unreadable document
    /// is a project with no turn.
    private static func read(folder: String) -> Entry {
        let url = URL(fileURLWithPath: folder).appendingPathComponent(ProjectFileRegistry.projectDocumentName)
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Entry(turns: 0, rendered: [:])
        }
        let capture = object["capture"] as? [String: Any]
        let turns = (capture?["quarterTurns"] as? NSNumber)?.intValue ?? 0
        var rendered: [String: Int] = [:]
        var byID: [String: Int] = [:]
        for blend in object["blends"] as? [[String: Any]] ?? [] {
            guard let value = (blend["renderedQuarterTurns"] as? NSNumber)?.intValue, value != 0 else { continue }
            if let name = blend["outputFileName"] as? String { rendered[name] = value }
            if let id = blend["id"] as? String { byID[id.uppercased()] = value }
        }
        return Entry(turns: turns, rendered: rendered, renderedByID: byID)
    }
}
