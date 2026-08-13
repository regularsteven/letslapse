import SwiftUI

/// A `.lapse` archive on its way into the library, and the sheet that shows it.
///
/// Import is the one long job that can start without the human being in the app
/// — a double-click in Finder launches or fronts LetsLapse and hands it a file —
/// so it announces itself over whatever screen happens to be showing rather
/// than as a row somewhere in Create.

// MARK: - State

struct ArchiveImport: Identifiable, Equatable {
    enum Phase: Equatable {
        /// Sizing the file and checking there is room for it.
        case checking
        /// Unpacking. The only phase with a byte count worth showing.
        case extracting
        /// Renaming the unpacked tree into the library and writing library.json.
        case installing
        /// Unpacked, and it turns out to be an archive already in the library —
        /// waiting on the human to say whether they want a second copy. Carries
        /// the existing project's name, which is the thing worth showing them.
        case duplicate(existingName: String)
        case failed(String)
    }

    let id = UUID()
    let url: URL
    /// The archive's filename without its extension. The project's real name
    /// isn't known until its manifest is unpacked, and a title that changed
    /// mid-progress would read as a different file arriving.
    var name: String
    /// The compressed file's own size, which is the honest denominator here:
    /// lzfse barely shrinks video and stills, and the true unpacked total isn't
    /// known until the last entry lands.
    var archiveBytes: Int64
    var extractedBytes: Int64 = 0
    var phase: Phase = .checking

    /// Nil while there is nothing truthful to draw — the bar stays
    /// indeterminate rather than inventing a position.
    var fraction: Double? {
        switch phase {
        case .extracting:
            guard archiveBytes > 0 else { return nil }
            return min(1, Double(extractedBytes) / Double(archiveBytes))
        case .installing:
            return 1
        case .checking, .duplicate, .failed:
            return nil
        }
    }

    var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    var isDuplicate: Bool {
        if case .duplicate = phase { return true }
        return false
    }
}

/// Set on the main actor, read from the archiver's worker threads.
final class ArchiveImportCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

/// The mirror image: written from the worker threads, sampled on the main actor.
final class ArchiveImportMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 0

    func record(_ bytes: Int64) {
        lock.lock()
        value = bytes
        lock.unlock()
    }

    var bytes: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

// MARK: - Staging

/// Where an archive is unpacked before it becomes a project.
///
/// A finished import deletes its own tree, and so does a cancelled or failed
/// one. A *killed* one cannot — force-quit, a crash, or a power cut leaves the
/// whole partially-unpacked project sitting in the temporary directory, and for
/// this app that is gigabytes, not kilobytes. macOS clears `/var/folders`
/// eventually; "eventually" is not a good enough answer at this size, so the
/// leftovers are swept at launch, the same way `CaptureSessionLogger` handles
/// logs that outlived the process that wrote them.
enum ImportStaging {
    private static let prefix = "lapse-import-"

    static func makeURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)\(UUID().uuidString)", isDirectory: true)
    }

    /// Off the main thread — deleting several gigabytes is not instant, and
    /// nothing at launch is waiting on the answer.
    static func sweepOrphans() {
        DispatchQueue.global(qos: .utility).async {
            let fileManager = FileManager.default
            let temporary = fileManager.temporaryDirectory
            guard let entries = try? fileManager.contentsOfDirectory(
                at: temporary,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey])
            else { return }

            for entry in entries where entry.lastPathComponent.hasPrefix(prefix) {
                let values = try? entry.resourceValues(
                    forKeys: [.contentModificationDateKey, .isDirectoryKey])
                guard values?.isDirectory == true else { continue }
                // A second copy of LetsLapse can be running — a Debug build
                // beside a Release one, which is the normal state of this
                // project — and its live extraction writes into a tree that
                // looks exactly like an abandoned one. An extraction touches
                // its tree constantly, so anything untouched for a quarter of
                // an hour is nobody's.
                let modified = values?.contentModificationDate ?? .distantPast
                guard Date().timeIntervalSince(modified) > 15 * 60 else { continue }
                try? fileManager.removeItem(at: entry)
            }
        }
    }
}

// MARK: - Sheet

/// Deliberately blocking. The extraction owns the disk for minutes, and letting
/// a shoot or a render start on top of it invites both to fail for reasons
/// neither can explain. Cancel is always reachable, so it is never a trap.
struct ProjectImportSheet: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let progress = model.archiveImport {
            content(progress)
        }
    }

    private func content(_ progress: ArchiveImport) -> some View {
        VStack(spacing: 0) {
            Image(systemName: icon(progress))
                .font(.system(size: 30))
                .foregroundStyle(progress.isFailed ? Color.red : LL.accent)
                .padding(.top, 30)

            Text(title(progress))
                .font(.system(size: 19, weight: .semibold))
                .padding(.top, 14)

            Text(progress.name)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.top, 3)
                .padding(.horizontal, 24)

            switch progress.phase {
            case .failed(let reason):
                prose(reason)
            case .duplicate(let existingName):
                prose("You already have this project as “\(existingName)”. Importing it again makes a second, separate copy — the one you have is not touched.")
            case .checking, .extracting, .installing:
                bar(progress)
                    .padding(.top, 22)
                    .padding(.horizontal, 24)

                Text(caption(progress))
                    .font(.system(size: 12.5).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }

            Spacer(minLength: 20)

            switch progress.phase {
            case .failed:
                Button("Close") { model.dismissArchiveImport() }
                    .buttonStyle(LLPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            case .duplicate:
                // Both answers open a project, so neither is a dead end and
                // neither is destructive — which is why the default action is
                // the safe one rather than the one that spends the disk.
                VStack(spacing: 10) {
                    Button("Open the one I have") {
                        model.resolveDuplicateImport(importAgain: false)
                    }
                    .buttonStyle(LLPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)

                    Button("Import again as a new project") {
                        model.resolveDuplicateImport(importAgain: true)
                    }
                    .buttonStyle(LLSecondaryButtonStyle())
                }
            case .checking, .extracting, .installing:
                Button("Cancel") { model.cancelArchiveImport() }
                    .buttonStyle(LLSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .frame(width: 380)
        .frame(minHeight: 300)
        .background(LL.screenBackground)
        // Nothing here is dismissable by swipe or by clicking away: the only
        // exits are Cancel and Close, both of which tidy up after themselves.
        .interactiveDismissDisabled()
    }

    private func icon(_ progress: ArchiveImport) -> String {
        switch progress.phase {
        case .failed: return "exclamationmark.triangle.fill"
        case .duplicate: return "square.on.square"
        case .checking, .extracting, .installing: return "shippingbox.fill"
        }
    }

    private func title(_ progress: ArchiveImport) -> String {
        switch progress.phase {
        case .failed: return "Couldn't import"
        case .duplicate: return "Already imported"
        case .checking, .extracting, .installing: return "Importing project"
        }
    }

    private func prose(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 16)
            .padding(.horizontal, 24)
    }

    /// Drawn rather than a `ProgressView(value:)`: the system linear bar renders
    /// its fill in the control grey on macOS whatever the tint says, and a
    /// progress bar in a sheet the accent otherwise owns has to be the accent.
    /// The indeterminate case keeps the system control — it animates, and no
    /// hand-drawn version of that earns its keep for a phase measured in
    /// milliseconds.
    @ViewBuilder
    private func bar(_ progress: ArchiveImport) -> some View {
        if let fraction = progress.fraction {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.12))
                    Capsule()
                        .fill(LL.accent)
                        .frame(width: max(0, geometry.size.width * fraction))
                }
            }
            .frame(height: 6)
            .animation(.easeOut(duration: 0.25), value: fraction)
        } else {
            ProgressView()
                .progressViewStyle(.linear)
                .tint(LL.accent)
        }
    }

    private func caption(_ progress: ArchiveImport) -> String {
        switch progress.phase {
        case .checking:
            return "Checking the file…"
        case .extracting:
            guard progress.archiveBytes > 0 else {
                return LLFormat.bytes(progress.extractedBytes) + " unpacked"
            }
            // "about", because the denominator is the compressed size — the
            // unpacked total isn't known until the last entry lands.
            return "\(LLFormat.bytes(progress.extractedBytes)) of about \(LLFormat.bytes(progress.archiveBytes))"
        case .installing:
            return "Adding it to your library…"
        case .duplicate, .failed:
            return ""
        }
    }
}
