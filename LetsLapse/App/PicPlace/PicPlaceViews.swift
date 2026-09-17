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
            .onAppear {
                picplace.refreshProject(captureID)
                if case .notSynced = state { _ = picplace.summary(for: capture) }
            }
            .picplaceConnectAlert(picplace)
            .picplaceConflictsSheet(picplace)
        }
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

            if let action = picplace.originalsAction(for: capture), !isPreviewOnly(state) {
                Divider().padding(.leading, 16)
                originalsRow(for: capture, action: action, size: 16)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
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
            if let action = picplace.originalsAction(for: capture), !isPreviewOnly(state) {
                originalsRow(for: capture, action: action, size: 12)
                    .padding(.leading, 24)
                    .padding(.top, 6)
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

    /// Stage 5: the originals' own line — upload them, or note they are on
    /// both sides. (A preview-only project's main button is the download.)
    private func originalsRow(for capture: AppModel.CaptureProject, action: PicPlaceController.OriginalsAction, size: CGFloat) -> some View {
        HStack {
            switch action {
            case .upload(let files, let bytes):
                VStack(alignment: .leading, spacing: 2) {
                    Text("Originals").font(.system(size: size))
                    Text("\(files.formatted()) file\(files == 1 ? "" : "s") · \(LLFormat.bytes(bytes)) · only on this device")
                        .font(.system(size: size * 0.72)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Upload") { picplace.uploadOriginals(capture) }
                    .buttonStyle(.plain)
                    .font(.system(size: size * 0.8, weight: .semibold))
                    .foregroundStyle(LL.accent)
            case .onBothSides:
                Text("Originals").font(.system(size: size))
                Spacer()
                Text("Here and on PicPlace").font(.system(size: size * 0.85)).foregroundStyle(.secondary)
            case .download:
                EmptyView()
            }
        }
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
        case .previewOnly: return "Preview only"
        case .elsewhere(let name): return name.map { "In “\($0)” on PicPlace" } ?? "In another library on PicPlace"
        case .signedOut: return "Keep a copy on PicPlace"
        case .notConnected: return "Library not connected"
        case .notSynced: return "Not on PicPlace"
        case .changes: return "Changes to sync"
        case .syncing(let progress): return progress.phase == .downloading ? "Downloading originals" : "Syncing to PicPlace"
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
            let files = record?.serverHeavyFiles ?? record?.heavyFiles ?? 0
            let bytes = record?.serverHeavyBytes ?? record?.heavyBytes ?? 0
            if files > 0 {
                return "The originals — \(files.formatted()) file\(files == 1 ? "" : "s") · \(LLFormat.bytes(bytes)) — are on PicPlace, not on this device"
            }
            return "The originals are on PicPlace, not on this device"
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
            }
        case .synced(let record):
            return "Synced \(record.syncedAt.formatted(.relative(presentation: .named))) · "
                + Self.objectsLine(files: record.files, bytes: record.bytes, heavyFiles: record.heavyFiles ?? 0, heavyBytes: record.heavyBytes ?? 0)
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
            case .previewOnly: return (picplace.originalsAction(for: capture) == nil ? "Preview only" : "Download originals", false)
            case .elsewhere: return ("Elsewhere", false)
            case .signedOut: return (picplace.isSigningIn ? "Signing in…" : "Sign in", false)
            case .notConnected: return (picplace.libraryLink == .mismatch ? "Settings" : "Connect…", false)
            case .notSynced: return ("Sync to PicPlace", false)
            case .changes: return ("Sync now", false)
            case .syncing: return ("Cancel", true)
            case .synced: return ("Sync again", false)
            case .failed: return ("Try again", false)
            }
        }()
        return Button {
            switch state {
            case .conflict: picplace.isReviewingConflicts = true
            case .previewOnly: picplace.downloadOriginals(capture)
            case .signedOut: picplace.signIn()
            case .notConnected: if picplace.libraryLink == .unbound || picplace.libraryLink == .needsLibrary { picplace.offerConnect() } else { model.requestedTab = .settings }
            case .syncing: picplace.cancelSync(capture.id)
            default: picplace.sync(capture)
            }
        } label: {
            Text(label)
                .font(.system(size: size, weight: style == .phone ? .semibold : .medium))
                .foregroundStyle(LL.accent)
        }
        .buttonStyle(.plain)
        .disabled((picplace.isSigningIn && !isCancel)
                  || { if case .previewOnly = state { return picplace.originalsAction(for: capture) == nil } else { return false } }()
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
                LLRow(title: "On PicPlace", subtitle: usageSubtitle) {
                    Text(usageText)
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                libraryRow
                initialSyncRow
                autoSyncRows
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
            Text("The library forgets which account it belongs to and what it has synced. Every project stays on this device and on PicPlace; nothing is deleted anywhere.")
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
                    title: picplace.isConnecting ? "Connecting…" : "Not on PicPlace — Connect…",
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
            LLRow(title: initialSyncTitle(progress), subtitle: initialSyncSubtitle(progress)) {
                if progress.phase == .pulling || progress.phase == .pushing || progress.phase == .deciding {
                    ProgressView().controlSize(.small)
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
                  subtitle: "Auto-sync waits for Wi-Fi or Ethernet — a personal hotspot counts as mobile data. Syncing a project yourself works on any connection.") {
                Toggle("", isOn: $picplace.wifiOnly).labelsHidden().disabled(!picplace.autoSyncEnabled)
            }
            LLRow(title: "Upload originals automatically",
                  subtitle: "Source photos, videos and blends of every project, one project at a time. Nothing is ever removed from this device.") {
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

    private func initialSyncTitle(_ progress: PicPlaceController.InitialSyncProgress) -> String {
        switch progress.phase {
        case .waiting(let why): return "First connection — \(why.lowercased())"
        case .deciding: return "Comparing with PicPlace…"
        case .pulling: return "Bringing projects here…"
        case .pushing: return "Sending projects…"
        case .done: return progress.failures.isEmpty ? "Library in step with PicPlace" : "First connection finished with problems"
        case .failed: return "First connection failed"
        }
    }

    private func initialSyncSubtitle(_ progress: PicPlaceController.InitialSyncProgress) -> String {
        if case .failed(let why) = progress.phase { return why }
        if case .waiting = progress.phase { return "Runs on its own once the network allows" }
        var parts: [String] = []
        if progress.pulled > 0 || progress.phase == .pulling { parts.append("\(progress.pulled) brought here") }
        if progress.pushed > 0 || progress.phase == .pushing { parts.append("\(progress.pushed) sent") }
        if progress.inStep > 0 { parts.append("\(progress.inStep) in step") }
        if progress.deferred > 0 { parts.append("\(progress.deferred) need a merge (a later stage)") }
        if !progress.failures.isEmpty { parts.append(progress.failures.joined(separator: "; ")) }
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

    private var usageText: String {
        guard let usage = picplace.usage else { return "…" }
        return "\(usage.projects) project\(usage.projects == 1 ? "" : "s") · \(LLFormat.bytes(usage.bytes))"
    }

    /// "2 not in this library yet" — the account's total is not the
    /// library's; the difference is what a later merge brings here.
    private var usageSubtitle: String? {
        guard let usage = picplace.usage, usage.notInLibrary > 0 else { return nil }
        return "\(usage.notInLibrary) not in this library yet"
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
        .onAppear { if name.isEmpty { name = offer.suggestedName } }
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

// MARK: - List pill (components/picplace-pill.<state>.svg)

/// The 22×18 media pill on a Projects-list thumbnail: synced, syncing or failed.
struct PicPlacePill: View {
    let state: PicPlaceController.ListState

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 22, height: 18)
            .background(Color.black.opacity(0.5), in: Capsule())
            .accessibilityLabel(label)
    }

    private var symbol: String {
        switch state {
        case .synced: return "checkmark.icloud.fill"
        case .syncing: return "icloud.and.arrow.up"
        case .failed: return "exclamationmark.icloud.fill"
        case .previewOnly: return "icloud"
        }
    }

    private var tint: Color {
        switch state {
        case .synced: return .green
        case .syncing: return LL.amber
        case .failed: return LL.levelOff
        case .previewOnly: return .secondary
        }
    }

    private var label: String {
        switch state {
        case .previewOnly: return "Preview only — originals on PicPlace"
        case .synced: return "On PicPlace"
        case .syncing: return "Syncing to PicPlace"
        case .failed: return "PicPlace sync failed"
        }
    }
}
