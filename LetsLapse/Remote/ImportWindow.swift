#if os(macOS)
import SwiftUI

/// The Mac's home for `ProjectTransferImportView`.
///
/// Its own `Window` scene rather than a section in `RemoteWindow`: that window
/// is pinned to 208×248 pt because Watch layout parity is its entire reason for
/// existing, and a project list with sizes and a progress bar cannot live in a
/// Watch canvas without wrecking the thing it exists to protect.
///
/// The flow itself is shared with iOS and iPadOS, which present the same view
/// as a sheet from Create — a Mac has windows and a phone does not, and that is
/// the whole of the difference.
struct ImportWindow: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ProjectTransferImportView()
            .environmentObject(model)
    }
}

// MARK: - Menu

/// File ▸ Import from Device… (⌘⇧I), beside the archive importer it
/// complements: one brings in a `.lapse` file, the other brings in a project
/// that never became a file. Create's own "Import a LetsLapse project…" row
/// offers both, so this is the shortcut rather than the only door.
struct LibraryImportCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .importExport) {
            Button("Import from Device…") {
                openWindow(id: "import")
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
        }
    }
}
#endif
