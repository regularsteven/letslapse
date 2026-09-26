import SwiftUI
import LetsLapseKit

// MARK: - Status card (components/picplace-status.<state>.<width>.svg)

/// A project's copy on PicPlace and the one action its state offers. `.phone`
/// is the iOS project-detail card (the section header and the white card are
/// drawn here); `.narrow` is the flat group in the Mac Gallery inspector.
struct PicPlaceStatusCard: View {
    enum Style { case phone, narrow }

    @EnvironmentObject private var model: AppModel
    @ObservedObject var picplace: PicPlaceController
    let captureID: UUID
    var style: Style = .phone
    /// The Remove the card is asking about (free up space, 2026-09-23).
    @State private var pendingRemoval: PicPlaceController.RemovalScope?
    /// The Replace the card is asking about: copies here that differ from
    /// PicPlace's, which holds them as recorded at capture.
    @State private var pendingReplace: PendingReplace?

    private struct PendingReplace: Identifiable {
        var kind: PicPlaceOriginalsCheck.Kind
        var names: [String]
        var id: String { kind.rawValue }
    }

    private var capture: AppModel.CaptureProject? { model.capture(id: captureID) }

    var body: some View {
        if let capture {
            let state = picplace.state(for: capture)
            Group {
                switch style {
                case .phone:
                    VStack(alignment: .leading, spacing: 8) {
                        LLSectionHeader("PicPlace")
                        phoneCard(for: capture, state: state)
                            .llCard()
                    }
                case .narrow:
                    narrowGroup(for: capture, state: state)
                }
            }
            // The server's view — Also on, and the per-file truth the
            // Originals and Blends lines read — once the session is up: on a
            // cold launch the card appears before the sign-in lands.
            .task(id: picplace.canSync) { picplace.refreshProject(captureID) }
            .onAppear {
                if case .notSynced = state { _ = picplace.summary(for: capture) }
                #if DEBUG
                // `LL_PICPLACE_ASK_REMOVE=originals|blends` opens the card's
                // Remove confirm once its lines are in — the dialog's
                // screenshot without a finger (free up space, 2026-09-23).
                if let raw = ProcessInfo.processInfo.environment["LL_PICPLACE_ASK_REMOVE"],
                   let scope = PicPlaceController.RemovalScope(rawValue: raw) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { pendingRemoval = scope }
                }
                #endif
            }
            .picplaceConnectAlert(picplace)
            .picplaceConflictsSheet(picplace)
            .confirmationDialog(removalTitle, isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                                titleVisibility: .visible, presenting: pendingRemoval) { scope in
                Button(scope == .originals ? "Remove Originals" : "Remove Blends", role: .destructive) {
                    picplace.removeFromDevice(capture, scope: scope)
                }
                Button("Cancel", role: .cancel) {}
            } message: { scope in
                Text(removalMessage(scope, capture: capture))
            }
            .confirmationDialog("Replace with PicPlace's copies?", isPresented: Binding(get: { pendingReplace != nil }, set: { if !$0 { pendingReplace = nil } }),
                                titleVisibility: .visible, presenting: pendingReplace) { replace in
                Button("Replace \(replace.names.count) File\(replace.names.count == 1 ? "" : "s")", role: .destructive) {
                    picplace.downloadOriginals(capture, kinds: [replace.kind], replacing: Set(replace.names))
                }
                Button("Cancel", role: .cancel) {}
            } message: { replace in
                Text("\(replace.names.count == 1 ? "This file has" : "These \(replace.names.count) files have") changed on \(PicPlaceController.deviceWord) since \(replace.names.count == 1 ? "it was" : "they were") recorded. PicPlace's \(replace.names.count == 1 ? "copy matches" : "copies match") what was captured; \(replace.names.count == 1 ? "it replaces" : "they replace") the ones here.")
            }
        }
    }

    // MARK: Free up space (2026-09-23)

    private var removalTitle: String {
        "Remove the \(pendingRemoval?.noun ?? "originals") from \(PicPlaceController.deviceWord)?"
    }

    private func removalMessage(_ scope: PicPlaceController.RemovalScope, capture: AppModel.CaptureProject) -> String {
        let part = picplace.originalsStatus(for: capture)?.row(scope).here ?? .init()
        let size = "\(part.files.formatted()) \(scope == .originals ? "file" : "blend")\(part.files == 1 ? "" : "s") · \(LLFormat.bytes(part.bytes))."
        switch scope {
        case .originals:
            return "\(size) Every file is checked with PicPlace first; they stay there — download them again whenever you need them. Until then the project shows its preview, and editing and new blends wait for the download."
        case .blends:
            return "\(size) Every file is checked with PicPlace first; they stay there — download them again whenever you need them. Until then each blend shows a still. Blends a collection uses stay on \(PicPlaceController.deviceWord)."
        }
    }

    /// One line per kind: Originals (the source media), Blends. What is here,
    /// what PicPlace lacks, what only PicPlace has — and the one action that
    /// fits: Upload, Remove…, Download. A preview-only project's Originals
    /// line is the card's own main button; a photo's blend is the photo.
    private struct HeavyLine: Identifiable {
        enum Action {
            case upload, remove(PicPlaceController.RemovalScope), download(PicPlaceOriginalsCheck.Kind)
            case replace(PicPlaceOriginalsCheck.Kind, [String])
            /// An upload job waiting (2026-09-24): Resume / Try again, *Use
            /// mobile data* for this job alone, and Cancel beside either.
            case resumeUpload(String), useMobileData, cancelUpload
        }
        var id: String { title }
        var title: String
        var detail: String
        var action: Action?
        /// A second, quieter button after the first (an upload job's Cancel).
        var secondary: Action?
        /// Copies here differ from PicPlace's and PicPlace's are not the
        /// recorded originals: nothing to offer, a sentence to say.
        var keptAsIs = false
    }

    private func heavyLines(for capture: AppModel.CaptureProject, state: PicPlaceController.ProjectState) -> [HeavyLine] {
        // An upload job speaks for the originals and blends it is sending:
        // its run's progress and Pause are the card's header; waiting, it is
        // the one line, with what it needs.
        if let job = picplace.uploadJobs[capture.id] {
            if case .syncing = state { return [] }
            return [uploadJobLine(job)]
        }
        guard let status = picplace.originalsStatus(for: capture) else { return [] }
        var lines: [HeavyLine] = []
        func line(_ scope: PicPlaceController.RemovalScope, _ row: PicPlaceController.OriginalsStatus.Row) -> HeavyLine? {
            let noun = scope == .originals ? "file" : "blend"
            func count(_ part: PicPlaceController.OriginalsStatus.Part) -> String {
                "\(part.files.formatted()) \(noun)\(part.files == 1 ? "" : "s") · \(LLFormat.bytes(part.bytes))"
            }
            let title = scope == .originals ? "Originals" : "Blends"
            // Copies that differ from PicPlace's come first: an Upload there
            // would be refused (PicPlace keeps its confirmed originals).
            if !row.divergent.isEmpty {
                let detail = "\(count(row.divergent)) here differ\(row.divergent.files == 1 ? "s" : "") from PicPlace's"
                return HeavyLine(title: title, detail: detail,
                                 action: row.replaceable.isEmpty ? nil : .replace(scope.kind, row.replaceable),
                                 keptAsIs: row.replaceable.isEmpty)
            }
            if !row.here.isEmpty {
                if row.notUp.isEmpty {
                    return HeavyLine(title: title, detail: "Here and on PicPlace · \(count(row.here))", action: .remove(scope))
                }
                let detail = row.notUp == row.here
                    ? "\(count(row.here)) · only on this device"
                    : "\(count(row.notUp)) of \(row.here.files.formatted()) not on PicPlace yet"
                return HeavyLine(title: title, detail: detail, action: .upload)
            }
            if !row.onlyThere.isEmpty {
                return HeavyLine(title: title, detail: "On PicPlace · \(count(row.onlyThere))", action: .download(scope.kind))
            }
            return nil
        }
        if !isPreviewOnly(state), let originals = line(.originals, status.originals) { lines.append(originals) }
        if !capture.isPhotoCapture, let blends = line(.blends, status.blends) { lines.append(blends) }
        return lines
    }

    /// A waiting upload job's line: why it waits, where it got to, and the
    /// button that moves it on.
    private func uploadJobLine(_ job: PicPlaceUploadJob) -> HeavyLine {
        let counts = job.counts
        switch job.hold {
        case .paused?:
            return HeavyLine(title: "Upload paused", detail: counts ?? "Nothing sent yet",
                             action: .resumeUpload("Resume"), secondary: .cancelUpload)
        case .waitingForWiFi?:
            return HeavyLine(title: "Waiting for Wi-Fi", detail: [counts, "Only on Wi-Fi is on"].compactMap { $0 }.joined(separator: " · "),
                             action: .useMobileData, secondary: .cancelUpload)
        case .interrupted?:
            return HeavyLine(title: "Upload interrupted", detail: [counts, "goes again on its own"].compactMap { $0 }.joined(separator: " · "),
                             action: .resumeUpload("Resume"), secondary: .cancelUpload)
        case .failed?:
            return HeavyLine(title: "Upload stopped", detail: [job.lastError ?? "Something went wrong", counts].compactMap { $0 }.joined(separator: " · "),
                             action: .resumeUpload("Try again"), secondary: .cancelUpload)
        case nil:
            return HeavyLine(title: "Upload waiting", detail: counts ?? "Starts once PicPlace is connected",
                             action: .resumeUpload("Resume"), secondary: .cancelUpload)
        }
    }

    /// An upload job's line — two buttons: beside the text where the detail
    /// fits on one line (the Mac, a wide card — the design as signed off),
    /// on a line of their own under it where it would not. On a phone,
    /// *Use mobile data* broke over two lines beside a detail wrapped
    /// mid-number (2026-09-24, found drawing the mirrors).
    private func jobLineRow<Texts: View>(_ line: HeavyLine, capture: AppModel.CaptureProject, actionSize: CGFloat,
                                         @ViewBuilder texts: @escaping (Int) -> Texts) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 8) {
                texts(1)
                Spacer(minLength: 8)
                heavyAction(line, capture: capture, size: actionSize)
            }
            VStack(alignment: .leading, spacing: 8) {
                texts(3)
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    heavyAction(line, capture: capture, size: actionSize)
                }
            }
        }
    }

    private func heavyAction(_ line: HeavyLine, capture: AppModel.CaptureProject, size: CGFloat) -> some View {
        HStack(spacing: size * 0.9) {
            if let secondary = line.secondary {
                heavyButton(secondary, capture: capture)
                    .foregroundStyle(.secondary)
            }
            heavyButton(line.action, capture: capture)
                .foregroundStyle(LL.accent)
        }
        .buttonStyle(.plain)
        .font(.system(size: size * 0.8, weight: .semibold))
    }

    @ViewBuilder
    private func heavyButton(_ action: HeavyLine.Action?, capture: AppModel.CaptureProject) -> some View {
        switch action {
        case .upload:
            Button("Upload") { picplace.uploadOriginals(capture) }
        case .remove(let scope):
            Button("Remove…") { pendingRemoval = scope }
                .disabled(picplace.freeUp.run != nil)
        case .download(let kind):
            Button("Download") { picplace.downloadOriginals(capture, kinds: [kind]) }
        case .replace(let kind, let names):
            Button("Replace…") { pendingReplace = PendingReplace(kind: kind, names: names) }
        case .resumeUpload(let label):
            Button(label) { picplace.resumeUpload(capture.id) }
        case .useMobileData:
            Button("Use mobile data") { picplace.allowMobileData(forUpload: capture.id) }
        case .cancelUpload:
            Button("Cancel") { picplace.cancelUpload(capture.id) }
        case nil:
            EmptyView()
        }
    }

    private func offersRemove(_ lines: [HeavyLine]) -> Bool {
        lines.contains { if case .remove = $0.action { return true } else { return false } }
    }

    private static let removeNote = "You can download the originals and blends again whenever you need them."

    /// The card's small print under the lines: what the last removal did,
    /// else the reassurance beside a Remove, plus what the last originals
    /// push found — files changed since they were recorded (they went up as
    /// they are now), copies PicPlace kept its own of.
    private func notes(for capture: AppModel.CaptureProject, lines: [HeavyLine]) -> [String] {
        var notes: [String] = []
        if let note = picplace.removalNotes[capture.id] {
            notes.append(note)
        } else if offersRemove(lines) {
            notes.append(Self.removeNote)
        }
        let record = picplace.records[model.originID(of: capture)]
        if let changed = record?.changedFiles, !changed.isEmpty {
            notes.append("\(changed.count) file\(changed.count == 1 ? "" : "s") had changed since \(changed.count == 1 ? "it was" : "they were") recorded — PicPlace has \(changed.count == 1 ? "it" : "them") as \(changed.count == 1 ? "it is" : "they are") now.")
        }
        if lines.contains(where: \.keptAsIs) {
            notes.append("PicPlace kept its own copies of these; nothing here is replaced.")
        }
        return notes
    }

    // MARK: Phone

    private func phoneCard(for capture: AppModel.CaptureProject, state: PicPlaceController.ProjectState) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    glyph(for: state, size: 20)
                        .frame(width: 20, height: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title(for: state))
                            .font(.system(size: 16))
                            .foregroundStyle(.primary)
                        if case .syncing = state {
                            EmptyView()
                        } else {
                            Text(caption(for: capture, state: state))
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 8)
                    if showsAction(for: state) { actionButton(for: capture, state: state, size: 12.5) }
                }
                if case .syncing(let progress) = state {
                    progressBar(progress, height: 4)
                        .padding(.leading, 28)
                    Text(caption(for: capture, state: state))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 28)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            let lines = heavyLines(for: capture, state: state)
            ForEach(lines) { line in
                Divider().padding(.leading, 16)
                Group {
                    if line.secondary != nil {
                        jobLineRow(line, capture: capture, actionSize: 16) { limit in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(line.title).font(.system(size: 16))
                                Text(line.detail)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(limit)
                            }
                        }
                    } else {
                        HStack(alignment: .center, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(line.title).font(.system(size: 16))
                                Text(line.detail)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 8)
                            heavyAction(line, capture: capture, size: 16)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            let notes = notes(for: capture, lines: lines)
            if !notes.isEmpty {
                Text(notes.joined(separator: "\n"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .padding(.top, lines.isEmpty ? 12 : 0)
            }
            if case .synced(let record) = state {
                Divider().padding(.leading, 16)
                HStack {
                    Text("Also on")
                        .font(.system(size: 16))
                    Spacer()
                    Text(alsoOnText(record))
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }

    // MARK: Narrow

    private func narrowGroup(for capture: AppModel.CaptureProject, state: PicPlaceController.ProjectState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                glyph(for: state, size: 16)
                    .frame(width: 16, height: 16)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                Text(title(for: state))
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 8)
                if showsAction(for: state) { actionButton(for: capture, state: state, size: 11) }
            }
            if case .syncing(let progress) = state {
                progressBar(progress, height: 3)
                    .padding(.leading, 24)
                    .padding(.top, 8)
            }
            Text(caption(for: capture, state: state))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .padding(.leading, 24)
            let lines = heavyLines(for: capture, state: state)
            ForEach(lines) { line in
                Group {
                    if line.secondary != nil {
                        jobLineRow(line, capture: capture, actionSize: 13) { limit in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(line.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                                Text(line.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(limit)
                            }
                        }
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(line.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                                Text(line.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer(minLength: 8)
                            heavyAction(line, capture: capture, size: 13)
                        }
                    }
                }
                .padding(.leading, 24)
                .padding(.top, 6)
            }
            let notes = notes(for: capture, lines: lines)
            if !notes.isEmpty {
                Text(notes.joined(separator: "\n"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 24)
                    .padding(.top, 4)
            }
            if case .synced(let record) = state {
                HStack(alignment: .top, spacing: 10) {
                    Text("Also on")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 72, alignment: .leading)
                    Text(alsoOnText(record))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 24)
                .padding(.top, 6)
            }
        }
        .padding(.vertical, 6)
    }

    /// With auto-sync on, a project in step needs no button — the next edit
    /// goes up on its own. The other states keep theirs (a nudge, a retry).
    private func showsAction(for state: PicPlaceController.ProjectState) -> Bool {
        if case .synced = state { return !picplace.autoSyncEnabled }
        return true
    }

    private func isPreviewOnly(_ state: PicPlaceController.ProjectState) -> Bool {
        if case .previewOnly = state { return true }
        return false
    }

    // MARK: Pieces

    @ViewBuilder
    private func glyph(for state: PicPlaceController.ProjectState, size: CGFloat) -> some View {
        switch state {
        case .conflict:
            Image(systemName: "exclamationmark.icloud.fill").font(.system(size: size * 0.85)).foregroundStyle(LL.amber)
        case .previewOnly:
            Image(systemName: "icloud.and.arrow.down").font(.system(size: size * 0.85)).foregroundStyle(.secondary)
        case .elsewhere:
            Image(systemName: "folder.badge.questionmark").font(.system(size: size * 0.85)).foregroundStyle(.secondary)
        case .signedOut, .notSynced:
            Image(systemName: "icloud").font(.system(size: size * 0.85)).foregroundStyle(.secondary)
        case .notConnected:
            Image(systemName: "icloud.slash").font(.system(size: size * 0.85)).foregroundStyle(.secondary)
        case .changes, .syncing:
            Image(systemName: "icloud.and.arrow.up").font(.system(size: size * 0.85)).foregroundStyle(LL.accent)
        case .synced:
            Image(systemName: "checkmark.icloud.fill").font(.system(size: size * 0.85)).foregroundStyle(Color.green)
        case .failed:
            Image(systemName: "exclamationmark.icloud.fill").font(.system(size: size * 0.85)).foregroundStyle(LL.levelOff)
        }
    }

    private func title(for state: PicPlaceController.ProjectState) -> String {
        switch state {
        case .conflict(let kind):
            switch kind {
            case .deletedOnServer: return "Deleted on PicPlace"
            case .deletedHereEditedThere: return "Deleted here, changed on PicPlace"
            default: return "Needs your decision"
            }
        // A blend still here says so, as the holdings pill's layers do.
        case .previewOnly: return model.shownHoldings(for: captureID)?.tier == .blends ? "Blends here" : "Preview only"
        case .elsewhere(let name): return name.map { "In “\($0)” on PicPlace" } ?? "In another library on PicPlace"
        case .signedOut: return "Keep a copy on PicPlace"
        case .notConnected: return "Library not connected"
        case .notSynced: return "Not on PicPlace"
        case .changes: return "Changes to sync"
        case .syncing(let progress):
            switch progress.phase {
            case .downloading: return "Downloading from PicPlace"
            case .verifying, .removing: return "Freeing up space"
            default: return "Syncing to PicPlace"
            }
        case .synced: return "On PicPlace"
        case .failed: return "Sync failed"
        }
    }

    private func caption(for capture: AppModel.CaptureProject, state: PicPlaceController.ProjectState) -> String {
        switch state {
        case .conflict(let kind):
            switch kind {
            case .bothEdited: return "Edited here and on PicPlace since they last agreed"
            case .unrelated: return "This device and PicPlace hold different versions that never agreed"
            case .deletedOnServer: return "Another device deleted it on PicPlace; this copy is still here"
            case .deletedHereEditedThere: return "Deleted here, but PicPlace changed it since"
            }
        case .previewOnly(let record):
            if let error = record?.lastError { return error }
            if picplace.binding == nil {
                // Kept through a disconnect (L23); nothing can fetch it until
                // the library connects again.
                return "Connect this library again to download the originals"
            }
            // The source media alone once the server's list is read (the
            // blends have their own line); the record's count until then.
            let part = picplace.originalsStatus(for: capture)?.originals.onlyThere
            let files = part.map(\.files) ?? record?.serverHeavyFiles ?? record?.heavyFiles ?? 0
            let bytes = part.map(\.bytes) ?? record?.serverHeavyBytes ?? record?.heavyBytes ?? 0
            if files > 0 {
                return "The originals are on PicPlace · \(files.formatted()) file\(files == 1 ? "" : "s") · \(LLFormat.bytes(bytes))"
            }
            return "The originals are on PicPlace, not on \(PicPlaceController.deviceWord)"
        case .elsewhere:
            return "PicPlace files this project under another of your libraries, so this library leaves it alone — it is neither pushed nor pulled from here"
        case .signedOut:
            return "Sign in with PicPlace to sync this project"
        case .notConnected:
            switch picplace.libraryLink {
            case .mismatch:
                return "This library belongs to @\(picplace.binding?.user.displayHandle ?? "someone else") on \(picplace.binding?.server.host ?? "PicPlace")"
            case .needsLibrary:
                return "PicPlace now keeps libraries apart — say which library this is to sync its projects"
            default:
                return "Connect this library to \(picplace.sessionHost) to sync its projects"
            }
        case .notSynced:
            if let summary = picplace.summary(for: capture) {
                return Self.objectsLine(files: summary.files, bytes: summary.bytes, heavyFiles: summary.heavyFiles, heavyBytes: summary.heavyBytes)
            }
            return "Reading the project…"
        case .changes(let record):
            return "Edited \(model.lastEdited(capture).formatted(.relative(presentation: .named))) · last synced \(record.syncedAt.formatted(.relative(presentation: .named)))"
        case .syncing(let progress):
            switch progress.phase {
            case .claiming: return "Claiming the project…"
            case .preparing: return progress.filesTotal > 0 ? "Checking \(progress.filesTotal) files…" : "Reading the project…"
            case .manifest: return "Sending the manifest…"
            case .negotiating: return "Comparing \(progress.filesTotal) files with the server…"
            case .uploading, .confirming:
                return "\(progress.filesDone) of \(progress.filesTotal) files · \(LLFormat.bytes(progress.bytesDone)) of \(LLFormat.bytes(progress.bytesTotal))"
            case .downloading:
                return progress.filesTotal == 0 ? "Listing the originals…"
                    : "Downloading \(progress.filesDone) of \(progress.filesTotal) files · \(LLFormat.bytes(progress.bytesDone)) of \(LLFormat.bytes(progress.bytesTotal))"
            case .finishing: return "Finishing…"
            case .verifying: return "Checking every file with PicPlace…"
            case .removing:
                return "Removing \(progress.filesDone.formatted()) of \(progress.filesTotal.formatted()) files · \(LLFormat.bytes(progress.bytesDone)) of \(LLFormat.bytes(progress.bytesTotal))"
            }
        case .synced(let record):
            // With the Originals and Blends lines under it (free up space),
            // the header speaks for the records alone — "N originals stay
            // here" beside "Here and on PicPlace" read as a contradiction.
            let objects = picplace.originalsStatus(for: capture) != nil
                ? "records and preview · \(LLFormat.bytes(record.bytes))"
                : Self.objectsLine(files: record.files, bytes: record.bytes, heavyFiles: record.heavyFiles ?? 0, heavyBytes: record.heavyBytes ?? 0)
            return "Synced \(record.syncedAt.formatted(.relative(presentation: .named))) · " + objects
                + (record.uploaded == 0 ? " · nothing needed uploading" : " · \(record.uploaded) uploaded")
        case .failed(let record):
            var line = record.lastError ?? "Something went wrong"
            if picplace.autoSyncEnabled, let due = record.retryDueAt {
                line += due <= Date() ? " · tries again at the next check" : " · tries again at \(due.formatted(date: .omitted, time: .shortened))"
            }
            return line
        }
    }

    /// "Records + preview · 118 KB · 1,481 originals stay here (86 MB)" under
    /// the minimal policy; "6 files · 1.9 MB" when everything went.
    private static func objectsLine(files: Int, bytes: Int64, heavyFiles: Int, heavyBytes: Int64) -> String {
        var line = heavyFiles > 0
            ? "Records + preview · \(LLFormat.bytes(bytes))"
            : "\(files) file\(files == 1 ? "" : "s") · \(LLFormat.bytes(bytes))"
        if heavyFiles > 0 {
            line += " · \(heavyFiles.formatted()) original\(heavyFiles == 1 ? "" : "s") stay\(heavyFiles == 1 ? "s" : "") here (\(LLFormat.bytes(heavyBytes)))"
        }
        return line
    }

    private func alsoOnText(_ record: PicPlaceSyncRecord) -> String {
        record.alsoOn.isEmpty ? "Only this device" : record.alsoOn.joined(separator: ", ")
    }

    private func actionButton(for capture: AppModel.CaptureProject, state: PicPlaceController.ProjectState, size: CGFloat) -> some View {
        let (label, isCancel): (String, Bool) = {
            switch state {
            case .conflict: return ("Review…", false)
            case .previewOnly: return (picplace.hasOriginalsToDownload(capture) ? "Download originals" : "Preview only", false)
            case .elsewhere: return ("Elsewhere", false)
            case .signedOut: return (picplace.isSigningIn ? "Signing in…" : "Sign in", false)
            case .notConnected: return (picplace.libraryLink == .mismatch ? "Settings" : "Connect…", false)
            case .notSynced: return ("Sync to PicPlace", false)
            case .changes: return ("Sync now", false)
            case .syncing: return (picplace.uploadJobs[capture.id] != nil ? "Pause" : "Cancel", true)
            case .synced: return ("Sync again", false)
            case .failed: return ("Try again", false)
            }
        }()
        return Button {
            switch state {
            case .conflict: picplace.isReviewingConflicts = true
            case .previewOnly: picplace.downloadOriginals(capture, kinds: picplace.originalsDownloadKinds(for: capture))
            case .signedOut: picplace.signIn()
            case .notConnected: if picplace.libraryLink == .unbound || picplace.libraryLink == .needsLibrary { picplace.offerConnect() } else { model.requestedTab = .settings }
            case .syncing:
                // An upload job pauses — what reached PicPlace stays, Resume
                // sends the rest; any other sync cancels.
                if picplace.uploadJobs[capture.id] != nil { picplace.pauseUpload(capture.id) } else { picplace.cancelSync(capture.id) }
            default: picplace.sync(capture)
            }
        } label: {
            Text(label)
                .font(.system(size: size, weight: style == .phone ? .semibold : .medium))
                .foregroundStyle(LL.accent)
        }
        .buttonStyle(.plain)
        .disabled((picplace.isSigningIn && !isCancel)
                  || { if case .previewOnly = state { return !picplace.hasOriginalsToDownload(capture) } else { return false } }()
                  || { if case .elsewhere = state { return true } else { return false } }())
    }

    private func progressBar(_ progress: PicPlaceSyncProgress, height: CGFloat) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(LL.controlFill)
                Capsule().fill(LL.amber)
                    .frame(width: max(height, proxy.size.width * progress.fraction))
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.25), value: progress.fraction)
    }
}

// MARK: - Settings card (components/picplace-account.<state>.phone.svg)

/// The PICPLACE card in Settings: sign in and the server while signed out;
/// the account, this device, what is on the server and sign out once in —
/// and, since v2 stage 1, the LIBRARY: connect it to the account, or see
/// whose it is and disconnect it. Copy-only changes for now (v2 plan D12:
/// code first, the mirrors follow once the flows hold).
struct PicPlaceSettingsCard: View {
    @ObservedObject var picplace: PicPlaceController
    @State private var isEditingServer = false
    @State private var serverDraft = ""
    @State private var isConfirmingSignOut = false
    @State private var isConfirmingDisconnect = false
    @State private var serverRejected = false
    @State private var isConfirmingFreeUp = false
    var body: some View {
        VStack(spacing: 0) {
            if let profile = picplace.profile {
                LLRow(title: "Account") {
                    Text("@\(profile.username)")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                LLRow(title: "This device") {
                    Text(profile.deviceName)
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                // The library's numbers on PicPlace — a bound library's;
                // after a disconnect the last ones would mislead.
                if picplace.binding != nil {
                    LLRow(title: "On PicPlace", subtitle: usageSubtitle) {
                        Text(usageText)
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                    }
                }
                libraryRow
                initialSyncRow
                autoSyncRows
                freeUpRows
                checkRow
                if PicPlaceConfiguration.showsServerSetting {
                    LLRow(title: "Server") {
                        Text(profile.host)
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                    }
                }
                #if os(iOS)
                if picplace.binding != nil { disconnectRow }
                #endif
                Button {
                    isConfirmingSignOut = true
                } label: {
                    LLRow(title: "Sign Out…", titleColor: .red, showsDivider: false) {
                        EmptyView()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                // One door (libraries plan L13): the Mac is signed in to a
                // server or it is not. A bound library names the account
                // it needs.
                Button {
                    if picplace.isSigningIn { picplace.cancelSignIn() } else { picplace.signIn() }
                } label: {
                    LLRow(
                        title: picplace.isSigningIn ? "Signing in…" : signInTitle,
                        subtitle: picplace.isSigningIn
                            ? "Finish in your browser, or tap to cancel"
                            : (picplace.lastSignInError ?? signInSubtitle),
                        titleColor: LL.accent,
                        showsDivider: picplace.binding != nil || PicPlaceConfiguration.showsServerSetting
                    ) {
                        EmptyView()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if let binding = picplace.binding {
                    if PicPlaceConfiguration.showsServerSetting {
                        LLRow(title: "Server") {
                            Text(binding.server.host)
                                .font(.system(size: 15))
                                .foregroundStyle(.secondary)
                        }
                    }
                    #if os(iOS)
                    disconnectRow
                    #endif
                } else if PicPlaceConfiguration.showsServerSetting {
                    Button {
                        serverDraft = picplace.serverString
                        serverRejected = false
                        isEditingServer = true
                    } label: {
                        LLRow(title: "Server", showsDivider: false) {
                            HStack(spacing: 6) {
                                Text(PicPlaceConfiguration.serverHost)
                                    .font(.system(size: 15))
                                    .foregroundStyle(.secondary)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .llCard()
        .onAppear { picplace.refreshUsage() }
        // Free up space's estimate, once the session is up (a cold launch
        // draws the card before the sign-in lands) and again on each return.
        .task(id: picplace.canSync) { picplace.refreshFreeUpEstimate() }
        .confirmationDialog(freeUpConfirmTitle, isPresented: $isConfirmingFreeUp, titleVisibility: .visible) {
            Button("Remove Originals", role: .destructive) { picplace.freeUpSpace() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("About \(LLFormat.bytes(picplace.freeUp.estimate?.bytes ?? 0)). Each project is checked with PicPlace file by file first — one that isn't fully there keeps its originals. They stay on PicPlace: download a project's originals again whenever you need them. Blends stay on \(PicPlaceController.deviceWord).")
        }
        .picplaceConnectAlert(picplace)
        .picplaceConflictsSheet(picplace)
        .alert("PicPlace server", isPresented: $isEditingServer) {
            TextField("https://picplace.co", text: $serverDraft)
                #if os(iOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
            Button("Save") {
                if !picplace.setServer(serverDraft) { serverRejected = true }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The PicPlace this app talks to. Leave empty for the default (\(PicPlaceConfiguration.defaultServer)).")
        }
        .alert("That isn't a server address", isPresented: $serverRejected) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Enter a host like picplace.co or https://picplace.test.")
        }
        .confirmationDialog("Sign out of PicPlace on this device?", isPresented: $isConfirmingSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { picplace.signOut() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(picplace.binding == nil
                 ? "Your projects stay on PicPlace and on this device; this device just stops syncing until you sign in again."
                 : "Your projects stay on PicPlace and on this device. The library stays @\(picplace.binding?.user.displayHandle ?? "")'s; sign in again to keep syncing it.")
        }
        .confirmationDialog("Disconnect this library from PicPlace?", isPresented: $isConfirmingDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { picplace.disconnectLibrary() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(picplace.disconnectMessage())
        }
    }

    private var signInTitle: String {
        if let binding = picplace.binding { return "Sign In as @\(binding.user.displayHandle)" }
        return "Sign In"
    }

    private var signInSubtitle: String {
        if let binding = picplace.binding { return "This library syncs with @\(binding.user.displayHandle) on \(binding.server.host)" }
        return "PicPlace on \(PicPlaceConfiguration.serverHost) — keep a copy of a library's projects there"
    }

    @ViewBuilder
    private var libraryRow: some View {
        switch picplace.libraryLink {
        case .unbound:
            Button {
                picplace.offerConnect()
            } label: {
                LLRow(
                    title: picplace.isConnecting ? "Connecting…" : Self.unboundTitle,
                    subtitle: picplace.lastConnectError
                        ?? "Keeps this library's projects on \(picplace.sessionHost) as @\(picplace.profile?.username ?? ""). The library stays in its folder.",
                    titleColor: LL.accent
                ) {
                    EmptyView()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(picplace.isConnecting)
        case .needsLibrary:
            Button {
                picplace.offerConnect()
            } label: {
                LLRow(
                    title: picplace.isConnecting ? "Connecting…" : "Which library is this? — Choose…",
                    subtitle: picplace.lastConnectError
                        ?? "Connected before \(picplace.sessionHost) kept libraries apart. Nothing syncs until you say whether this is a new library there, one to link to, or the unfiled projects taken over.",
                    titleColor: LL.accent
                ) {
                    EmptyView()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(picplace.isConnecting)
        case .bound:
            LLRow(title: picplace.binding?.library.map { "Library “\($0.name)”" } ?? "Library",
                  subtitle: picplace.binding.map { "Connected on \($0.boundAt.formatted(date: .abbreviated, time: .shortened))" }) {
                Text("@\(picplace.binding?.user.displayHandle ?? "") on \(picplace.binding?.server.host ?? "")")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        case .mismatch:
            LLRow(title: "Library",
                  subtitle: "This library belongs to @\(picplace.binding?.user.displayHandle ?? "") on \(picplace.binding?.server.host ?? ""). Sign in as them to sync it, or disconnect it.",
                  titleColor: LL.levelOff) {
                EmptyView()
            }
        }
    }

    /// "Bringing the library in step" — the first connection's cases and
    /// counts (v2 plan §4.1), shown while it runs and once it has run.
    @ViewBuilder
    private var initialSyncRow: some View {
        if let progress = picplace.initialSyncProgress {
            // What still stands failed once the run is done — the run's own
            // list goes stale the moment a retry lands.
            let standing = progress.phase == .done ? picplace.failedPushes : []
            let canRetry = !standing.isEmpty || isRunFailed(progress)
            LLRow(title: initialSyncTitle(progress, standing: standing.count),
                  subtitle: initialSyncSubtitle(progress, standing: standing)) {
                if progress.phase == .pulling || progress.phase == .pushing || progress.phase == .deciding {
                    ProgressView().controlSize(.small)
                } else if canRetry {
                    Button {
                        picplace.retryFirstConnection()
                    } label: {
                        Text(picplace.isChecking ? "Trying…" : "Try again")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(LL.accent)
                    }
                    .buttonStyle(.plain)
                    .disabled(picplace.isChecking)
                }
            }
        } else if let binding = picplace.binding, binding.initialSync.state == .pending, picplace.isSignedIn {
            LLRow(title: "First connection pending", subtitle: "Runs once the library has loaded") {
                EmptyView()
            }
        }
    }

    /// Auto-sync (§4.7): the switches and what it is doing.
    @ViewBuilder
    private var autoSyncRows: some View {
        if picplace.binding?.initialSync.state == .done {
            LLRow(title: "Sync changes automatically",
                  subtitle: "Edits and new projects go to PicPlace as you make them; other devices' changes arrive every few minutes") {
                Toggle("", isOn: $picplace.autoSyncEnabled).labelsHidden()
            }
            LLRow(title: "Only on Wi-Fi",
                  subtitle: "Auto-sync and uploads of originals wait for Wi-Fi or Ethernet — a personal hotspot counts as mobile data. An upload can use mobile data if you say so on its card, for that upload only. Syncing a project's changes yourself works on any connection.") {
                Toggle("", isOn: $picplace.wifiOnly).labelsHidden()
            }
            LLRow(title: "Upload blends automatically",
                  subtitle: "Every blended clip and image goes to PicPlace as it is made, so your other devices can play it and use it in collections without the originals.") {
                Toggle("", isOn: $picplace.autoBlendsEnabled).labelsHidden().disabled(!picplace.autoSyncEnabled)
            }
            LLRow(title: "Upload originals automatically",
                  subtitle: "Source photos, videos and blends of every project, one project at a time. Nothing is ever removed from this device on its own.") {
                Toggle("", isOn: $picplace.autoOriginalsEnabled).labelsHidden().disabled(!picplace.autoSyncEnabled)
            }
            if let status = picplace.autoStatus ?? picplace.autoHold ?? picplace.originalsHold.map { "Originals: \($0)" } {
                LLRow(title: "Auto-sync", subtitle: status) {
                    if picplace.autoStatus != nil { ProgressView().controlSize(.small) }
                }
            }
            if let error = picplace.autoError {
                LLRow(title: "Auto-sync problem", subtitle: error, titleColor: LL.levelOff) {
                    EmptyView()
                }
            }
        }
    }

    /// Free up space (2026-09-23): *Remove originals already on PicPlace* —
    /// a button pressed now and then, never a switch — with how much space
    /// it frees; the run's progress with Stop; what the last run did; and the
    /// originals not on PicPlace yet, with Upload.
    @ViewBuilder
    private var freeUpRows: some View {
        if picplace.binding?.initialSync.state == .done, picplace.canSync {
            let state = picplace.freeUp
            if let run = state.run {
                LLRow(title: "Removing originals already on PicPlace…",
                      subtitle: "\(run.done) of \(run.total) project\(run.total == 1 ? "" : "s") checked · \(LLFormat.bytes(run.freedBytes)) freed\(run.current.map { " · \($0)" } ?? "")") {
                    Button {
                        picplace.stopFreeUp()
                    } label: {
                        Text("Stop")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(LL.accent)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                if let result = state.result {
                    LLRow(title: result.projects == 0 ? "Nothing was removed" : "Freed \(LLFormat.bytes(result.freedBytes))",
                          subtitle: freeUpResultText(result)) {
                        EmptyView()
                    }
                }
                if let estimate = state.estimate, estimate.projects > 0 {
                    Button {
                        isConfirmingFreeUp = true
                    } label: {
                        LLRow(title: "Remove originals already on PicPlace",
                              subtitle: "The originals of \(estimate.projects) project\(estimate.projects == 1 ? " are" : "s are") safely on PicPlace — every file is checked before anything goes. Removing them from \(PicPlaceController.deviceWord) frees about \(LLFormat.bytes(estimate.bytes)) for more shoots.",
                              titleColor: LL.accent) {
                            EmptyView()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else if state.isEstimating, state.estimate == nil {
                    LLRow(title: "Remove originals already on PicPlace", subtitle: "Working out how much space it frees…") {
                        ProgressView().controlSize(.small)
                    }
                }
                if let estimate = state.estimate, estimate.notUpProjects > 0 {
                    LLRow(title: "\(estimate.notUpProjects) project\(estimate.notUpProjects == 1 ? "'s" : "s'") originals aren't on PicPlace yet",
                          subtitle: "\(LLFormat.bytes(estimate.notUpBytes)) · upload them, and they can be removed here too"
                            + (picplace.manualOriginalsWaiting ? " · waiting for Wi-Fi" : "")) {
                        Button {
                            picplace.uploadRemainingOriginals()
                        } label: {
                            Text(picplace.autoStatus?.hasPrefix("Uploading originals") == true ? "Uploading…"
                                 : picplace.manualOriginalsWaiting ? "Waiting…" : "Upload")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(LL.accent)
                        }
                        .buttonStyle(.plain)
                        .disabled(picplace.autoStatus?.hasPrefix("Uploading originals") == true || picplace.manualOriginalsWaiting)
                    }
                }
            }
        }
    }

    private var freeUpConfirmTitle: String {
        let n = picplace.freeUp.estimate?.projects ?? 0
        return "Remove the originals of \(n) project\(n == 1 ? "" : "s") from \(PicPlaceController.deviceWord)?"
    }

    private func freeUpResultText(_ result: PicPlaceController.FreeUpState.Result) -> String {
        var parts: [String] = []
        if result.projects > 0 { parts.append("originals of \(result.projects) project\(result.projects == 1 ? "" : "s") removed") }
        if result.kept > 0 { parts.append("\(result.kept) kept \(result.kept == 1 ? "its" : "their") originals — \(result.reasons.joined(separator: "; "))") }
        if let stopped = result.stopped { parts.append(stopped.lowercased() == "stopped" ? "stopped" : "stopped: \(stopped)") }
        return parts.isEmpty ? "Every project here was checked" : parts.joined(separator: " · ")
    }

    /// Stage 4: a check on demand, what the last one did, and the review
    /// row when rows need a person.
    @ViewBuilder
    private var checkRow: some View {
        if picplace.binding?.initialSync.state == .done {
            if !picplace.conflicts.isEmpty {
                Button {
                    picplace.isReviewingConflicts = true
                } label: {
                    LLRow(title: "\(picplace.conflicts.count) project\(picplace.conflicts.count == 1 ? "" : "s") need\(picplace.conflicts.count == 1 ? "s" : "") your decision",
                          subtitle: "Edited on both sides, or deleted on one — choose which version stands",
                          titleColor: LL.amber) {
                        Text("Review")
                            .font(.system(size: 15))
                            .foregroundStyle(LL.accent)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Button {
                picplace.checkForChanges(reason: "manual")
            } label: {
                LLRow(title: picplace.isChecking ? "Checking PicPlace…" : "Check PicPlace now", subtitle: lastCheckText, titleColor: LL.accent) {
                    if picplace.isChecking { ProgressView().controlSize(.small) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(picplace.isChecking)
        }
    }

    private var lastCheckText: String? { picplace.checkSummary }

    private func isRunFailed(_ progress: PicPlaceController.InitialSyncProgress) -> Bool {
        if case .failed = progress.phase { return true }
        return false
    }

    private func initialSyncTitle(_ progress: PicPlaceController.InitialSyncProgress, standing: Int) -> String {
        switch progress.phase {
        case .waiting(let why): return "First connection — \(why.lowercased())"
        case .deciding: return "Comparing with PicPlace…"
        case .pulling: return "Bringing projects here…"
        case .pushing: return "Sending projects…"
        case .done: return standing == 0 ? "Library in step with PicPlace" : "First connection finished with problems"
        case .failed: return "First connection failed"
        }
    }

    private func initialSyncSubtitle(_ progress: PicPlaceController.InitialSyncProgress,
                                     standing: [(originID: UUID, localID: UUID, record: PicPlaceSyncRecord)]) -> String {
        if case .failed(let why) = progress.phase { return why }
        if case .waiting = progress.phase { return "Runs on its own once the network allows" }
        var parts: [String] = []
        if progress.pulled > 0 || progress.phase == .pulling { parts.append("\(progress.pulled) brought here") }
        if progress.pushed > 0 || progress.phase == .pushing { parts.append("\(progress.pushed) sent") }
        if progress.inStep > 0 { parts.append("\(progress.inStep) in step") }
        if progress.evicted > 0 { parts.append("\(progress.evicted) \(progress.evicted == 1 ? "preview" : "previews") of other libraries removed") }
        if progress.deferred > 0 { parts.append("\(progress.deferred) need a merge (a later stage)") }
        if progress.phase == .done {
            // Live: the projects whose push still stands failed, by name,
            // with the newest reason. Gone once a retry lands.
            if !standing.isEmpty {
                let names = standing.prefix(3).compactMap { picplace.model.capture(id: $0.localID)?.displayTitle }
                let more = standing.count > names.count ? " and \(standing.count - names.count) more" : ""
                let reason = standing.max { ($0.record.failedAt ?? .distantPast) < ($1.record.failedAt ?? .distantPast) }?.record.lastError
                parts.append("\(standing.count) couldn't be sent — \(names.joined(separator: ", "))\(more)\(reason.map { ": \($0)" } ?? "")")
            }
        } else if !progress.failures.isEmpty {
            parts.append(progress.failures.joined(separator: "; "))
        }
        return parts.isEmpty ? "Nothing to exchange" : parts.joined(separator: " · ")
    }

    private var disconnectRow: some View {
        Button {
            isConfirmingDisconnect = true
        } label: {
            LLRow(title: "Disconnect this library…", titleColor: .red) {
                EmptyView()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// A phone whose only library is unbound is being asked which library
    /// it shows (libraries plan §17.4); a Mac, or a phone with others, is
    /// connecting one library.
    private static var unboundTitle: String {
        #if os(iOS)
        if StorageRoot.libraryFolders().count <= 1 { return "Which library should \(PicPlaceController.deviceWord) show? — Choose…" }
        #endif
        return "Not on PicPlace — Connect…"
    }

    /// "518 of 879 projects · 854,2 MB" — how many of this library's
    /// projects PicPlace has as this library, and their size; "518
    /// projects" when it has them all (libraries plan §17.12).
    private var usageText: String {
        guard let usage = picplace.usage else { return "…" }
        let projects: String
        if let t = picplace.tally, t.onPicPlace != t.here {
            projects = "\(t.onPicPlace) of \(t.here) projects"
        } else {
            projects = "\(usage.projects) project\(usage.projects == 1 ? "" : "s")"
        }
        return usage.bytes > 0 ? "\(projects) · \(LLFormat.bytes(usage.bytes))" : projects
    }

    /// "2 not in this library yet" — the account's total is not the
    /// library's; the difference is what a later merge brings here.
    /// One line under it: the originals PicPlace holds, and the gap —
    /// never another library's name.
    private var usageSubtitle: String? {
        guard let t = picplace.tally else { return nil }
        var parts: [String] = []
        if t.onPicPlace > 0 { parts.append("originals for \(t.originalsOnPicPlace)") }
        if t.notYet > 0 { parts.append("\(t.notYet) not on PicPlace yet") }
        if t.elsewhere > 0 { parts.append("\(t.elsewhere) here \(t.elsewhere == 1 ? "is" : "are") filed under other libraries on PicPlace") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - The connect question

/// "Connect this library to PicPlace?" — raised by the controller after a
/// sign-in on an unbound library and by the cards' Connect buttons; every
/// card that can show it attaches this, so it appears wherever the person is.
private struct PicPlaceConnectAlert: ViewModifier {
    @ObservedObject var picplace: PicPlaceController
    /// The name the library goes up under when it has only its folder's
    /// name (libraries plan L16) — the server library needs one a person
    /// chose.
    @State private var nameDraft = ""

    private var needsName: Bool { StorageRoot.identity?.namedByPerson != true }

    /// Stage C: the target chooser is a sheet; the one-line alert stays for
    /// a server that does not keep libraries apart.
    private var showsSheet: Binding<Bool> {
        Binding(get: { picplace.isOfferingConnect && picplace.connectOffer != nil },
                set: { if !$0 { picplace.isOfferingConnect = false } })
    }
    private var showsAlert: Binding<Bool> {
        Binding(get: { picplace.isOfferingConnect && picplace.connectOffer == nil },
                set: { if !$0 { picplace.isOfferingConnect = false } })
    }

    func body(content: Content) -> some View {
        content
        .sheet(isPresented: showsSheet) {
            if let offer = picplace.connectOffer {
                PicPlaceConnectSheet(picplace: picplace, offer: offer)
            }
        }
        .alert("Connect this library to PicPlace?", isPresented: showsAlert) {
            if needsName {
                TextField("Library name", text: $nameDraft)
            }
            Button("Connect") {
                if needsName {
                    let name = LibraryIdentity.cleanName(nameDraft)
                    if !name.isEmpty { try? StorageRoot.renameIdentity(to: name) }
                }
                picplace.connectLibrary()
            }
            Button("Not now", role: .cancel) {}
        } message: {
            Text([
                "Connect as @\(picplace.profile?.username ?? "") on \(picplace.sessionHost)",
                picplace.connectCaseText,
                needsName ? "Give the library a name first — it's what PicPlace and your other devices call it" : nil,
            ].compactMap { $0 }
                .map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
                .joined(separator: ". ") + ".")
        }
        .onChange(of: picplace.isOfferingConnect) { _, offering in
            if offering, nameDraft.isEmpty { nameDraft = StorageRoot.identity?.displayName ?? "" }
        }
    }
}

extension View {
    func picplaceConnectAlert(_ picplace: PicPlaceController) -> some View {
        modifier(PicPlaceConnectAlert(picplace: picplace))
    }
}

/// "Connect ‘Prague LetsLapse Shots’ to PicPlace" — where on PicPlace it
/// goes (stage C, libraries plan §3.7): a new library named after it, the
/// account's unfiled projects taken over, or an existing library linked;
/// the numbers of what goes up and what arrives per choice; the name it
/// takes. Blocking, like the other decisions that own the library.
struct PicPlaceConnectSheet: View {
    @ObservedObject var picplace: PicPlaceController
    let offer: PicPlaceController.ConnectOffer

    @Environment(\.dismiss) private var dismiss
    @State private var target: PicPlaceController.ConnectTarget = .new
    @State private var name = ""

    private var cleanName: String { LibraryIdentity.cleanName(name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Connect “\(cleanName.isEmpty ? offer.suggestedName : cleanName)” to PicPlace")
                    .font(.system(size: 19, weight: .semibold))
                Text("as @\(picplace.profile?.username ?? "") on \(picplace.sessionHost)")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                if let former = offer.former {
                    // L23: a folder that was a server library before leads
                    // with linking to it again — its previews are then in step.
                    Text("This library was “\(former.displayName)” on PicPlace.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }
            .padding(.top, 26)
            .padding(.horizontal, 24)

            HStack(spacing: 10) {
                Text("Name on PicPlace")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                TextField("Library name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .disabled({ if case .link = target { return true } else { return false } }())
            }
            .padding(.top, 18)
            .padding(.horizontal, 24)

            ScrollView {
                VStack(spacing: 0) {
                    choice(.new, title: "New library on PicPlace",
                           detail: offer.summary(for: .new))
                    if offer.defaultEntry != nil {
                        Divider().padding(.leading, 44)
                        choice(.adoptDefault, title: "Take over the \(offer.defaultEntry?.count ?? 0) unfiled project\((offer.defaultEntry?.count ?? 0) == 1 ? "" : "s")",
                               detail: offer.summary(for: .adoptDefault))
                    }
                    ForEach(offer.libraries) { library in
                        Divider().padding(.leading, 44)
                        choice(.link(library), title: "Link to “\(library.displayName)” · \(library.count) project\(library.count == 1 ? "" : "s")",
                               detail: offer.summary(for: .link(library)))
                    }
                }
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 24)
                .padding(.top, 16)
            }
            .frame(maxHeight: 360)

            if let error = picplace.lastConnectError {
                Text(error)
                    .font(.system(size: 12.5))
                    .foregroundStyle(LL.levelOff)
                    .padding(.horizontal, 24)
                    .padding(.top, 10)
            }

            HStack {
                Button("Not now") { dismiss() }
                    .buttonStyle(LLSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(picplace.isConnecting ? "Connecting…" : "Connect") {
                    picplace.connectLibrary(target: target, name: cleanName.isEmpty ? offer.suggestedName : cleanName)
                }
                .buttonStyle(LLPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(picplace.isConnecting || ({ if case .link = target { return false } else { return cleanName.isEmpty && offer.suggestedName.isEmpty } }()))
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
        #if os(macOS)
        .frame(width: 460)
        #endif
        .background(LL.screenBackground)
        .interactiveDismissDisabled(picplace.isConnecting)
        .onAppear {
            if let initial = offer.initialTarget {
                target = initial
                if case .link(let library) = initial { name = library.displayName } else if name.isEmpty { name = offer.suggestedName }
            } else if let former = offer.former {
                target = .link(former)
                name = former.displayName
            } else if name.isEmpty {
                name = offer.suggestedName
            }
        }
        .onChange(of: target) { _, new in
            // Linking takes the server library's name; the others keep the
            // person's.
            if case .link(let library) = new { name = library.displayName } else if name.isEmpty || offer.libraries.contains(where: { $0.displayName == name }) { name = offer.suggestedName }
        }
        .onChange(of: picplace.isOfferingConnect) { _, offering in if !offering { dismiss() } }
    }

    private func choice(_ choice: PicPlaceController.ConnectTarget, title: String, detail: String) -> some View {
        Button {
            target = choice
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: target == choice ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(target == choice ? LL.accent : Color.secondary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 14.5, weight: target == choice ? .semibold : .regular))
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
