import SwiftUI

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
        case .signedOut:
            return "Sign in with PicPlace to sync this project"
        case .notConnected:
            switch picplace.libraryLink {
            case .mismatch:
                return "This library belongs to @\(picplace.binding?.user.displayHandle ?? "someone else") on \(picplace.binding?.server.host ?? "PicPlace")"
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
            return record.lastError ?? "Something went wrong"
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
            case .notConnected: if picplace.libraryLink == .unbound { picplace.offerConnect() } else { model.requestedTab = .settings }
            case .syncing: picplace.cancelSync(capture.id)
            default: picplace.sync(capture)
            }
        } label: {
            Text(label)
                .font(.system(size: size, weight: style == .phone ? .semibold : .medium))
                .foregroundStyle(LL.accent)
        }
        .buttonStyle(.plain)
        .disabled((picplace.isSigningIn && !isCancel) || { if case .previewOnly = state { return picplace.originalsAction(for: capture) == nil } else { return false } }())
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
                if picplace.binding != nil { disconnectRow }
                Button {
                    isConfirmingSignOut = true
                } label: {
                    LLRow(title: "Sign out…", titleColor: .red, showsDivider: false) {
                        EmptyView()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
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
                    disconnectRow
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
        if let binding = picplace.binding { return "Sign in as @\(binding.user.displayHandle)" }
        return "Sign in with PicPlace"
    }

    private var signInSubtitle: String {
        if let binding = picplace.binding { return "This library belongs to @\(binding.user.displayHandle) on \(binding.server.host)" }
        return "Keep a copy of your projects on \(PicPlaceConfiguration.serverHost)"
    }

    @ViewBuilder
    private var libraryRow: some View {
        switch picplace.libraryLink {
        case .unbound:
            Button {
                picplace.offerConnect()
            } label: {
                LLRow(
                    title: picplace.isConnecting ? "Connecting…" : "Connect this library",
                    subtitle: picplace.lastConnectError
                        ?? ([
                            "Keep this library's projects on \(picplace.sessionHost) as @\(picplace.profile?.username ?? "")",
                            picplace.connectDestinationDescription,
                        ].compactMap { $0 }.joined(separator: ". ")),
                    titleColor: LL.accent
                ) {
                    EmptyView()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(picplace.isConnecting)
        case .bound:
            LLRow(title: "Library", subtitle: picplace.binding.map { "Connected on \($0.boundAt.formatted(date: .abbreviated, time: .shortened))" }) {
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
            LLRow(title: "Upload originals automatically",
                  subtitle: "Source photos, videos and blends of every project, one project at a time. Nothing is ever removed from this device.") {
                Toggle("", isOn: $picplace.autoOriginalsEnabled).labelsHidden().disabled(!picplace.autoSyncEnabled)
            }
            #if os(iOS)
            if picplace.autoOriginalsEnabled {
                LLRow(title: "Wi-Fi only", subtitle: "Originals wait for Wi-Fi") {
                    Toggle("", isOn: $picplace.wifiOnly).labelsHidden()
                }
            }
            #endif
            if let status = picplace.autoStatus ?? picplace.originalsHold.map { "Originals: \($0)" } {
                LLRow(title: "Auto-sync", subtitle: status) {
                    if picplace.autoStatus != nil { ProgressView().controlSize(.small) }
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

    private var lastCheckText: String? {
        guard let check = picplace.lastCheck else { return "Runs at launch and when the app comes to the front" }
        var parts: [String] = []
        if check.pulled > 0 { parts.append("\(check.pulled) brought here") }
        if check.updated > 0 { parts.append("\(check.updated) updated from PicPlace") }
        if check.pushed > 0 { parts.append("\(check.pushed) sent") }
        if check.deletedThere > 0 { parts.append("\(check.deletedThere) deleted on PicPlace") }
        if check.conflicts > 0 { parts.append("\(check.conflicts) to decide") }
        if !check.failures.isEmpty { parts.append(check.failures.joined(separator: "; ")) }
        let when = check.checkedAt.formatted(.relative(presentation: .named))
        return parts.isEmpty ? "Checked \(when) · nothing changed" : "Checked \(when) · " + parts.joined(separator: " · ")
    }

    private func initialSyncTitle(_ progress: PicPlaceController.InitialSyncProgress) -> String {
        switch progress.phase {
        case .deciding: return "Comparing with PicPlace…"
        case .pulling: return "Bringing projects here…"
        case .pushing: return "Sending projects…"
        case .done: return progress.failures.isEmpty ? "Library in step with PicPlace" : "First connection finished with problems"
        case .failed: return "First connection failed"
        }
    }

    private func initialSyncSubtitle(_ progress: PicPlaceController.InitialSyncProgress) -> String {
        if case .failed(let why) = progress.phase { return why }
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

    func body(content: Content) -> some View {
        content.alert("Connect this library to PicPlace?", isPresented: $picplace.isOfferingConnect) {
            Button("Connect") { picplace.connectLibrary() }
            Button("Not now", role: .cancel) {}
        } message: {
            Text([
                "Connect as @\(picplace.profile?.username ?? "") on \(picplace.sessionHost)",
                picplace.connectCaseText,
                picplace.connectDestinationDescription,
            ].compactMap { $0 }.joined(separator: ". "))
        }
    }
}

extension View {
    func picplaceConnectAlert(_ picplace: PicPlaceController) -> some View {
        modifier(PicPlaceConnectAlert(picplace: picplace))
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
