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
                    actionButton(for: capture, state: state, size: 12.5)
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
                actionButton(for: capture, state: state, size: 11)
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

    // MARK: Pieces

    @ViewBuilder
    private func glyph(for state: PicPlaceController.ProjectState, size: CGFloat) -> some View {
        switch state {
        case .signedOut, .notSynced:
            Image(systemName: "icloud").font(.system(size: size * 0.85)).foregroundStyle(.secondary)
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
        case .signedOut: return "Keep a copy on PicPlace"
        case .notSynced: return "Not on PicPlace"
        case .changes: return "Changes to sync"
        case .syncing: return "Syncing to PicPlace"
        case .synced: return "On PicPlace"
        case .failed: return "Sync failed"
        }
    }

    private func caption(for capture: AppModel.CaptureProject, state: PicPlaceController.ProjectState) -> String {
        switch state {
        case .signedOut:
            return "Sign in with PicPlace to sync this project"
        case .notSynced:
            if let summary = picplace.summary(for: capture) {
                return "\(summary.files) file\(summary.files == 1 ? "" : "s") · \(LLFormat.bytes(summary.bytes))"
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
            case .finishing: return "Finishing…"
            }
        case .synced(let record):
            return "Synced \(record.syncedAt.formatted(.relative(presentation: .named))) · \(record.files) file\(record.files == 1 ? "" : "s") · \(LLFormat.bytes(record.bytes))"
        case .failed(let record):
            return record.lastError ?? "Something went wrong"
        }
    }

    private func alsoOnText(_ record: PicPlaceSyncRecord) -> String {
        record.alsoOn.isEmpty ? "Only this device" : record.alsoOn.joined(separator: ", ")
    }

    private func actionButton(for capture: AppModel.CaptureProject, state: PicPlaceController.ProjectState, size: CGFloat) -> some View {
        let (label, isCancel): (String, Bool) = {
            switch state {
            case .signedOut: return (picplace.isSigningIn ? "Signing in…" : "Sign in", false)
            case .notSynced: return ("Sync to PicPlace", false)
            case .changes: return ("Sync now", false)
            case .syncing: return ("Cancel", true)
            case .synced: return ("Sync again", false)
            case .failed: return ("Try again", false)
            }
        }()
        return Button {
            switch state {
            case .signedOut: picplace.signIn()
            case .syncing: picplace.cancelSync(capture.id)
            default: picplace.sync(capture)
            }
        } label: {
            Text(label)
                .font(.system(size: size, weight: style == .phone ? .semibold : .medium))
                .foregroundStyle(LL.accent)
        }
        .buttonStyle(.plain)
        .disabled(picplace.isSigningIn && !isCancel)
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
/// the account, this device, what is on the server and sign out once in.
struct PicPlaceSettingsCard: View {
    @ObservedObject var picplace: PicPlaceController
    @State private var isEditingServer = false
    @State private var serverDraft = ""
    @State private var isConfirmingSignOut = false
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
                LLRow(title: "On PicPlace") {
                    Text(usageText)
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                LLRow(title: "Server") {
                    Text(PicPlaceConfiguration.serverHost)
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
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
                        title: picplace.isSigningIn ? "Signing in…" : "Sign in with PicPlace",
                        subtitle: picplace.isSigningIn
                            ? "Finish in your browser, or tap to cancel"
                            : (picplace.lastSignInError ?? "Keep a copy of your projects on \(PicPlaceConfiguration.serverHost)"),
                        titleColor: LL.accent
                    ) {
                        EmptyView()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

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
        .llCard()
        .onAppear { picplace.refreshUsage() }
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
            Text("Your projects stay on PicPlace and on this device; this device just stops syncing until you sign in again.")
        }
    }

    private var usageText: String {
        guard let usage = picplace.usage else { return "…" }
        return "\(usage.projects) project\(usage.projects == 1 ? "" : "s") · \(LLFormat.bytes(usage.bytes))"
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
        }
    }

    private var tint: Color {
        switch state {
        case .synced: return .green
        case .syncing: return LL.amber
        case .failed: return LL.levelOff
        }
    }

    private var label: String {
        switch state {
        case .synced: return "On PicPlace"
        case .syncing: return "Syncing to PicPlace"
        case .failed: return "PicPlace sync failed"
        }
    }
}
