import Foundation
import CoreTransferable
import UniformTypeIdentifiers

/// Receives a picked video as a file copied into our temp directory, so the
/// blend engine can read it without holding photo-library access.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("picked-\(UUID().uuidString).mov")
            try FileManager.default.copyItem(at: received.file, to: destination)
            return PickedMovie(url: destination)
        }
    }
}

/// Receives a picked photo as a file, **under the name the picker gave it**.
///
/// The picker passes the library's own file name along with the bytes — one
/// half of a RAW+JPEG pair arrives as `IDG_20261012_181542_485.jpeg` (iOS 27,
/// measured 2026-10-13) — so the copy keeps that name, in a folder of its own,
/// rather than a `picked-<uuid>` one: an imported frame's name is its identity
/// everywhere after the import, Bad Frames included.
struct PickedStill: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("picked-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent(received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return PickedStill(url: destination)
        }
    }
}
