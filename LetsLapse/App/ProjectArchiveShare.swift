import SwiftUI

/// The `.lapse` file a "Share project" pass produced, and the sheet that hands
/// it on.
///
/// Shared by the two screens that can archive a project — a shoot's
/// `ProjectDetailView` and a scan's `ScanDetailView` — because the operation is
/// the same one on both: the whole capture folder, manifest included, in a
/// single file any LetsLapse can import. Whatever the project *is* (a video
/// ramp, a photo, forty rectified pages) it archives identically, so the sheet
/// that presents the result has no business being written twice.
struct ExportedArchive: Identifiable {
    let url: URL
    var id: String { url.path }
}

extension View {
    /// Presents the produced archive: what it's called, how big it came out,
    /// and the system share sheet to send it somewhere.
    func exportedArchiveSheet(_ archive: Binding<ExportedArchive?>) -> some View {
        modifier(ExportedArchiveSheetModifier(archive: archive))
    }
}

/// Wraps the sheet so the `.lapse` file can be deleted when it closes.
///
/// `exportProject` builds the archive in `tmp/` — a byte-for-byte second copy
/// of the whole project, which nothing removed: export a 4 GB shoot three times
/// and the app was sitting on 12 GB the user could neither see nor clear. It is
/// deleted on dismissal rather than after the `ShareLink`, because the share is
/// the *reason* the file exists and the sheet can share more than once; closing
/// the sheet is the moment the file stops being needed.
///
/// The URL is remembered separately because `sheet(item:onDismiss:)` fires its
/// dismissal closure after the binding has already gone nil.
private struct ExportedArchiveSheetModifier: ViewModifier {
    @Binding var archive: ExportedArchive?
    @State private var presentedURL: URL?

    func body(content: Content) -> some View {
        content.sheet(item: $archive, onDismiss: discardArchive) { produced in
            ExportedArchiveSheet(archive: produced) { archive = nil }
                .onAppear { presentedURL = produced.url }
        }
    }

    private func discardArchive() {
        guard let url = presentedURL else { return }
        presentedURL = nil
        try? FileManager.default.removeItem(at: url)
    }
}

private struct ExportedArchiveSheet: View {
    let archive: ExportedArchive
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "shippingbox")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(archive.url.lastPathComponent)
                .font(.headline)
                .multilineTextAlignment(.center)
            if let size = sizeLabel {
                Text(size)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ShareLink(item: archive.url) {
                Label("Share archive", systemImage: "square.and.arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .background(LL.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Button("Done", action: onDone)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        #if os(macOS)
        .frame(minWidth: 340)
        #endif
    }

    private var sizeLabel: String? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: archive.url.path)
        guard let bytes = (attributes?[.size] as? NSNumber)?.int64Value else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
