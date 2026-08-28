// A Watch is a remote, never a library — the same exclusion as the rest of
// this feature.
#if !os(watchOS)
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Pulling a project off another device over the local network, with no
/// `.lapse` written on either side.
///
/// ONE view for every platform that can import. macOS hosts it in a `Window`
/// (`Remote/ImportWindow.swift`); iOS and iPadOS present it as a sheet from
/// Create. The flow is identical because the job is identical — the only
/// platform differences are the ones the platforms genuinely have: how a
/// thumbnail is decoded, how Settings is reached, and whether there is a title
/// bar to close.
struct ProjectTransferImportView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var client = ProjectTransferClient()
    @State private var code = ""
    @State private var selectedProject: PTProjectInfo?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 440)
        #endif
        .background(LL.screenBackground)
        .onAppear {
            client.attach(model: model)
            client.startBrowsing()
            #if DEBUG
            autoRunIfRequested()
            #endif
        }
        .onDisappear {
            // Closing is the human saying they are done. An in-flight pull
            // would otherwise keep the other device's radio and this device's
            // disk busy with nowhere to report it.
            client.disconnect()
            client.stopBrowsing()
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(LL.accent)
            VStack(alignment: .leading, spacing: 1) {
                // Not "Import from Device" — on the Mac the title bar already
                // says that, and on iOS the row you tapped did. This line is
                // worth more saying where in the flow you are.
                Text(headline)
                    .font(.headline)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if showsBackButton {
                Button("Back") {
                    code = ""
                    selectedProject = nil
                    client.backToBrowsing()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(LL.accent)
            }
            #if !os(macOS)
            // A sheet has no title bar, so it carries its own way out. Absent
            // mid-transfer for the same reason Back is: the only exits then are
            // Cancel, which tidies up after itself.
            if showsBackButton || isIdlePhase {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary.opacity(0.6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            #endif
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var headline: String {
        switch client.phase {
        case .browsing: return "Choose a device"
        case .enteringCode(let device), .connecting(let device): return device.name
        case .selectingProject, .transferring, .installing, .done, .failed:
            return client.peerName ?? "Connected"
        }
    }

    private var subtitle: String {
        switch client.phase {
        case .browsing: return "On this network"
        case .enteringCode: return "Enter the pairing code"
        case .connecting: return "Pairing…"
        case .selectingProject:
            return client.projects.count == 1 ? "1 project" : "\(client.projects.count) projects"
        case .transferring: return "Copying"
        case .installing: return "Adding to your library"
        case .done: return "Done"
        case .failed: return "Stopped"
        }
    }

    private var showsBackButton: Bool {
        switch client.phase {
        case .browsing, .transferring, .installing: return false
        default: return true
        }
    }

    private var isIdlePhase: Bool {
        if case .browsing = client.phase { return true }
        return false
    }

    @ViewBuilder
    private var content: some View {
        switch client.phase {
        case .browsing:
            browse
        case .enteringCode(let device):
            pair(device, isConnecting: false)
        case .connecting(let device):
            pair(device, isConnecting: true)
        case .selectingProject:
            projectList
        case .transferring(let progress):
            transferring(progress)
        case .installing:
            centred(
                icon: "shippingbox.fill", tint: LL.accent,
                title: "Adding it to your library…",
                detail: "Renaming the received files into place. This is quick.",
                spinner: true)
        case .done(let name):
            done(name)
        case .failed(let message):
            failed(message)
        }
    }

    // MARK: - Phase A · browse

    private var browse: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if client.browseNeedsPermission {
                    permissionHelp
                } else if let failure = client.browseFailure {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if client.libraries.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Looking for devices…").font(.callout)
                        }
                        Text("Open LetsLapse on the other device, go to Projects, and turn on sharing in Settings ▸ Advanced.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 4)
                }

                ForEach(client.libraries) { device in
                    Button {
                        code = ""
                        client.select(device)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: deviceGlyph(device))
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(device.name).font(.callout)
                                Text(deviceCaption(device))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity)
                        .background(LL.cardBackground, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
        }
    }

    private func deviceGlyph(_ device: DiscoveredLibrary) -> String {
        let model = device.model.lowercased()
        if model.contains("ipad") { return "ipad" }
        if model.contains("mac") { return "desktopcomputer" }
        return "iphone"
    }

    private func deviceCaption(_ device: DiscoveredLibrary) -> String {
        var parts: [String] = []
        if !device.model.isEmpty { parts.append(device.model) }
        parts.append(device.projectCount == 1 ? "1 project" : "\(device.projectCount) projects")
        if let label = interfaceLabel(device) { parts.append(label) }
        return parts.joined(separator: " · ")
    }

    /// How the device was reached, but **only when the answer is unambiguous**.
    ///
    /// A cabled iOS device is discovered by exactly the same browser as a
    /// Wi-Fi one — that is what makes USB free — and knowing it is cabled is
    /// worth saying, because it will be fast. But a device advertising on
    /// several interfaces at once cannot be labelled honestly at all, and that
    /// is the normal case: a tethered iPhone 16 Pro reports `wiredEthernet`
    /// AND `wifi` (measured 2026-08-27). So: one interface, one label;
    /// anything else says nothing rather than guessing. `transfer_probe`
    /// prints the raw list for anyone who needs it.
    private func interfaceLabel(_ device: DiscoveredLibrary) -> String? {
        let kinds = Set(device.interfaces).subtracting(["loopback"])
        guard kinds.count == 1, let only = kinds.first else { return nil }
        switch only {
        case "wifi": return "Wi-Fi"
        case "wiredEthernet": return "Cable"
        default: return nil
        }
    }

    // MARK: - Local Network permission

    private var permissionHelp: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Let LetsLapse find your devices")
                .font(.headline)

            Text(permissionExplanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Open Local Network Settings") {
                openLocalNetworkSettings()
            }
            #if os(macOS)
            .keyboardShortcut(.defaultAction)
            #else
            .buttonStyle(LLPrimaryButtonStyle())
            #endif

            #if os(macOS)
            // macOS keys this permission to each COPY of the app, so older
            // builds leave rows behind and the list fills with identical
            // names. Nobody could guess that from looking, so the row this
            // copy needs is named outright. iOS has one copy of an app and no
            // such problem, which is why this whole section is Mac-only.
            DisclosureGroup("Seeing more than one LetsLapse?") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Each copy of the app gets its own switch, so older builds leave rows behind. The one to switch on is this copy:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Text(Bundle.main.bundleURL.path)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(3)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                        } label: {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(.borderless)
                        .help("Show this copy in Finder")
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LL.cardBackground, in: RoundedRectangle(cornerRadius: 6))
                    Text("Right-click a row in Settings and choose Show in Finder to see which copy it belongs to. Rows for copies you have deleted can be ignored.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let failure = client.browseFailure {
                        Text(failure)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.top, 6)
            }
            .font(.callout)
            #endif

            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Still checking…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        }
    }

    private var permissionExplanation: String {
        #if os(macOS)
        return "macOS needs your permission before LetsLapse can see other devices on this network. Open the setting below and switch LetsLapse on — this window will find your devices a moment later, on its own."
        #else
        return "iOS needs your permission before LetsLapse can see other devices on this network. Open the setting below and turn on Local Network — this screen will find your devices a moment later, on its own."
        #endif
    }

    /// Opens the Local Network setting as directly as each platform allows.
    ///
    /// macOS: the pane's own anchor, `privacy-localnetwork`, read out of
    /// SecurityPrivacyExtension since none of the documented `Privacy_*`
    /// anchors covers it. Measured on macOS 26 (2026-08-27): it scrolls the
    /// list to Local Network rather than opening it, which is as far as the
    /// system goes — worth stating so nobody later "fixes" a URL that is
    /// already doing its job. The fallback covers a future rename.
    ///
    /// iOS: `openSettingsURLString` lands on LetsLapse's own settings page,
    /// where Local Network is one of the rows.
    private func openLocalNetworkSettings() {
        #if os(macOS)
        let deepLink = URL(string:
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?privacy-localnetwork")
        let pane = URL(string:
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension")
        if let deepLink, NSWorkspace.shared.open(deepLink) { return }
        if let pane { NSWorkspace.shared.open(pane) }
        #else
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        #endif
    }

    // MARK: - Phase B · pair

    private func pair(_ device: DiscoveredLibrary, isConnecting: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pairing code")
                .font(.headline)
            Text("Shown in Projects on \(device.name), while sharing is on.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                TextField("000000", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 17).monospacedDigit())
                    .frame(width: 110)
                    .disabled(isConnecting)
                    .onSubmit { connect(device) }
                    #if !os(macOS)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    #endif
                Button(isConnecting ? "Pairing…" : "Connect") { connect(device) }
                    .disabled(code.filter(\.isNumber).count != 6 || isConnecting)
                    #if os(macOS)
                    .keyboardShortcut(.defaultAction)
                    #endif
                if isConnecting {
                    ProgressView().controlSize(.small)
                }
            }

            Text("The code grants access to every project on that device, not just one.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
    }

    private func connect(_ device: DiscoveredLibrary) {
        let digits = code.filter(\.isNumber)
        code = String(digits.prefix(6))
        guard code.count == 6 else { return }
        client.connect(to: device, code: code)
    }

    // MARK: - Phase C · pick a project

    private var projectList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if client.projects.isEmpty {
                centred(
                    icon: "square.stack", tint: .secondary,
                    title: "No projects on that device",
                    detail: "Nothing to import yet.",
                    spinner: false)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(client.projects) { project in
                            projectRow(project)
                                // The row asks for its own tile as it appears.
                                // A LazyVStack only builds what is on screen,
                                // so a 300-project library costs the handful
                                // of decodes somebody actually looked at.
                                .onAppear {
                                    client.requestThumbnailIfNeeded(for: project.captureID)
                                }
                        }
                    }
                    .padding(14)
                }
                Divider()
                HStack {
                    if let selectedProject {
                        Text(LLFormat.bytes(selectedProject.totalBytes) + " to copy")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Import") {
                        guard let selectedProject else { return }
                        client.requestProject(selectedProject)
                    }
                    .disabled(selectedProject == nil)
                    #if os(macOS)
                    .keyboardShortcut(.defaultAction)
                    #endif
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
    }

    private func projectRow(_ project: PTProjectInfo) -> some View {
        let isSelected = selectedProject?.captureID == project.captureID
        return Button {
            selectedProject = project
        } label: {
            HStack(spacing: 10) {
                thumbnail(project)
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name ?? "Untitled project")
                        .font(.callout)
                        .lineLimit(1)
                    Text(rowCaption(project))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    // Said here rather than after the tap: on a 128 GB phone
                    // this is the common case, not the edge one.
                    if client.storageShortfall(for: project) != nil {
                        Text("Not enough space on this device")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(LL.accent)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 8).fill(LL.cardBackground))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? LL.accent : Color.clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func rowCaption(_ project: PTProjectInfo) -> String {
        var parts = [project.createdAt.formatted(date: .abbreviated, time: .shortened)]
        if project.frameCount > 0 {
            parts.append(project.frameCount == 1 ? "1 frame" : "\(project.frameCount) frames")
        }
        parts.append(LLFormat.bytes(project.totalBytes))
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func thumbnail(_ project: PTProjectInfo) -> some View {
        // Fetched per visible row rather than shipped with the list: the
        // serving device only has a cached tile for assets some grid has drawn
        // (62 of 293 on a real phone), so eager delivery left most rows blank
        // AND made the list frame big. Asking per row lets the other end spend
        // one decode on a project somebody is actually looking at.
        if let data = client.thumbnails[project.captureID],
           let image = PlatformImage(data: data) {
            platformImage(image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 54, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        } else {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.primary.opacity(0.08))
                .frame(width: 54, height: 40)
                .overlay(Image(systemName: "photo").font(.caption).foregroundStyle(.tertiary))
        }
    }

    // MARK: - Phase D · progress

    private func transferring(_ progress: ProjectTransferClient.Progress) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Copying project")
                .font(.headline)

            bar(progress.fraction)

            Text(progressCaption(progress))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)

            Text(progress.fileName.isEmpty ? " " : progress.fileName)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)

            Text(keepOpenAdvice)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Cancel") {
                    selectedProject = nil
                    client.cancelTransfer()
                }
                #if os(macOS)
                .keyboardShortcut(.cancelAction)
                #endif
            }
        }
        .padding(14)
    }

    private var keepOpenAdvice: String {
        #if os(macOS)
        return "Nothing joins your library until every file has landed, so stopping here leaves no half-project behind."
        #else
        // iOS suspends network activity in the background, so this is not
        // advice, it is the platform rule — and the second sentence is what
        // makes the first one safe to ignore.
        return "Keep LetsLapse open — iOS pauses transfers in the background. Nothing joins your library until every file has landed, so stopping leaves no half-project behind."
        #endif
    }

    private func progressCaption(_ progress: ProjectTransferClient.Progress) -> String {
        guard progress.totalBytes > 0 else { return LLFormat.bytes(progress.bytesReceived) }
        // Both counts are uncompressed and there is no compression on the
        // payload path, so this is the truth rather than an estimate — no
        // "about" hedging is needed here, unlike the archive importer's bar.
        return "\(LLFormat.bytes(progress.bytesReceived)) of \(LLFormat.bytes(progress.totalBytes))"
    }

    /// Drawn rather than a `ProgressView(value:)`: the system linear bar renders
    /// its fill in the control grey on macOS whatever the tint says.
    @ViewBuilder
    private func bar(_ fraction: Double?) -> some View {
        if let fraction {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule()
                        .fill(LL.accent)
                        .frame(width: max(0, geometry.size.width * fraction))
                }
            }
            .frame(height: 6)
            .animation(.easeOut(duration: 0.25), value: fraction)
        } else {
            ProgressView().progressViewStyle(.linear).tint(LL.accent)
        }
    }

    // MARK: - Terminal states

    private func done(_ name: String) -> some View {
        VStack(spacing: 0) {
            centred(
                icon: "checkmark.circle.fill", tint: .green,
                title: "Import complete",
                detail: "“\(name)” was added to your library.",
                spinner: false)
            HStack {
                Spacer()
                Button("Import another") {
                    selectedProject = nil
                    client.backToBrowsing()
                }
                Button("Done") { dismiss() }
                #if os(macOS)
                .keyboardShortcut(.defaultAction)
                #endif
            }
            .padding(14)
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(spacing: 0) {
            centred(
                icon: "exclamationmark.triangle.fill", tint: .orange,
                title: "Couldn't import",
                detail: message,
                spinner: false)
            HStack {
                Spacer()
                Button("Try again") {
                    code = ""
                    selectedProject = nil
                    client.backToBrowsing()
                }
                #if os(macOS)
                .keyboardShortcut(.defaultAction)
                #endif
            }
            .padding(14)
        }
    }

    private func centred(
        icon: String, tint: Color, title: String, detail: String, spinner: Bool
    ) -> some View {
        VStack(spacing: 10) {
            Spacer(minLength: 20)
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(tint)
            Text(title).font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
            if spinner { ProgressView().controlSize(.small) }
            Spacer(minLength: 20)
        }
        .frame(maxWidth: .infinity)
    }

    #if DEBUG
    /// `LL_TRANSFER=<6-digit code>` connects to the first device found;
    /// `LL_TRANSFER_PULL=<index>` then imports that project.
    ///
    /// Same reasoning as `RemoteWindow.autoConnectIfRequested`, and the same
    /// limit: pairing is deliberately a human act — a code read off the other
    /// device's Projects tab, typed here — which is right for the product and
    /// makes the one thing worth verifying (does a real project actually
    /// arrive intact?) unreachable without a person at both ends. **The code
    /// still has to be correct**, so this weakens nothing: it types, it does
    /// not bypass. DEBUG-only.
    private func autoRunIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard let wanted = environment["LL_TRANSFER"], wanted.count == 6 else { return }
        let pull = environment["LL_TRANSFER_PULL"].flatMap(Int.init)
        // `LL_TRANSFER_DEVICE=<name substring>` — which device to pair with.
        // "The first one found" is arbitrary the moment more than one thing is
        // advertising, which in a room with a Mac, a phone and an iPad is
        // always: the run then dials the wrong device with the right code and
        // presents as a pairing failure.
        let wantedDevice = environment["LL_TRANSFER_DEVICE"]?.lowercased()
        code = wanted
        // Poll rather than hook the browser: discovery is asynchronous and can
        // take a couple of seconds on a busy network.
        Task { @MainActor in
            for _ in 0..<60 {
                switch client.phase {
                case .browsing:
                    let match = wantedDevice.map { wanted in
                        client.libraries.first { $0.name.lowercased().contains(wanted) }
                    } ?? client.libraries.first
                    if let match { connect(match) }
                case .selectingProject:
                    guard let pull, client.projects.indices.contains(pull) else { return }
                    selectedProject = client.projects[pull]
                    client.requestProject(client.projects[pull])
                case .done, .failed:
                    return
                default:
                    break
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }
    #endif
}

// MARK: - Platform image

#if os(macOS)
typealias PlatformImage = NSImage
#else
typealias PlatformImage = UIImage
#endif

extension ProjectTransferImportView {
    fileprivate func platformImage(_ image: PlatformImage) -> Image {
        #if os(macOS)
        Image(nsImage: image)
        #else
        Image(uiImage: image)
        #endif
    }
}
#endif
