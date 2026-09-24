#if os(macOS)
import AppKit
import LetsLapseKit
import UniformTypeIdentifiers

/// The macOS end of a single-asset export: where iOS hands a file to Photos,
/// the Mac asks where to put it. One save panel, then a plain file copy — the
/// grading (if any) has already happened in the temp copy the caller passes in.
@MainActor
enum MacExporter {
    /// Runs a save panel offering `suggestedName` and copies `source` to the
    /// chosen destination. Returns false when the user cancels — a cancel is
    /// not an error, and callers should quietly reset their UI on it.
    static func exportCopy(of source: URL, suggestedName: String) async throws -> Bool {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        if let type = UTType(filenameExtension: source.pathExtension) {
            panel.allowedContentTypes = [type]
        }
        guard await panel.begin() == .OK, let destination = panel.url else { return false }
        // The panel has already asked the user about replacing an existing
        // file, so an old one at the destination is cleared without another
        // prompt.
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
        // The project's quarter turns go with the copy, written the way its
        // format carries one (2026-09-24); the original stays as it is. A
        // format that can't carry a turn is saved as it is.
        let turns = ProjectOrientation.shared.turns(for: source)
        if turns != 0 {
            do {
                try await MediaRotator.rotate(at: destination, quarterTurns: turns)
            } catch {
                LLog("export: the turn could not be written into \(destination.lastPathComponent) (\(error.localizedDescription))")
            }
        }
        return true
    }
}
#endif
