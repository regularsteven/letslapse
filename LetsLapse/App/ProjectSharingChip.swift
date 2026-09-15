#if !os(watchOS)
import SwiftUI

/// The library's sync control: a pill in the Projects and Gallery headers,
/// and the **sync panel** behind it — PicPlace on top, nearby devices below.
///
/// Modelled on `RemoteLinkChip`, and deliberately somewhere else. That chip
/// lives on the capture screen because the camera remote's code is regenerated
/// every time that screen appears, so a code read anywhere else would already
/// be stale. This code has a different lifetime — it survives tab switches and
/// navigation, which is the point of not hanging the server off a screen — so
/// it belongs where the library is.
///
/// **It used to be a full-width row under the title, and only while sharing was
/// on.** That row carried the code, the state and the stop action across the
/// whole header, and it could only ever say one thing: *you are sharing*. The
/// pill says the same thing in a glyph — **green on, red off** — is always
/// there, and puts everything else (the switch, the code, the QR, what is being
/// sent right now) one tap away in a sheet. The switch inside it is the same
/// `transfer.sharingEnabled` Settings ▸ Advanced writes, so the two are one
/// state rather than two that agree by convention.
///
/// **Since 2026-09-15 the panel is "Project Syncing"** (a working title): the
/// same pill opens it from the Gallery header too, and the panel leads with
/// PicPlace — sign in when signed out, *Check PicPlace now* with the last
/// check's line and what auto-sync is doing when signed in, and a way to the
/// full card in Settings — before the nearby-devices switch it always had.
/// Nothing about the server (the address) is here: that is Settings' only.
///
/// Its own view rather than a computed property on the lists so it can
/// `@ObservedObject` the server directly: the lists observe the *model*, so the
/// server's published changes — code minted, transfer started — would never
/// redraw a control built inline there.
///
/// Shared with macOS since Phase 3: a Mac serves its library through the same
/// server and shows the same pill in the same header. The Mac has no
/// scene-phase stand-down, so there the pill is also the only visible sign that
/// this machine is advertising — which is exactly why it is not tucked away.
struct ProjectSharingChip: View {
    @ObservedObject var server: ProjectTransferServer
    @ObservedObject var picplace: PicPlaceController
    /// The Settings switch, bound through from the list so that turning
    /// sharing on or off here does exactly what turning it on or off there
    /// does — one write, one listener, no third state.
    @Binding var isEnabled: Bool

    @State private var showsSheet = false

    var body: some View {
        Button {
            showsSheet = true
        } label: {
            Image(systemName: glyph)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.12), in: Circle())
                .overlay(Circle().strokeBorder(tint.opacity(0.35), lineWidth: 1))
                .overlay(sendingRing)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens project syncing: PicPlace and nearby devices")
        .sheet(isPresented: $showsSheet) {
            ProjectSyncSheet(server: server, picplace: picplace, isEnabled: $isEnabled)
        }
        #if DEBUG
        // `LL_SYNC_PANEL=1` opens the panel as the header appears — how the
        // sheet is screenshotted for its mirror without a tap.
        .onAppear {
            if ProcessInfo.processInfo.environment["LL_SYNC_PANEL"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { showsSheet = true }
            }
        }
        #endif
    }

    /// Green on, red off — the two states the human asked to be able to read at
    /// a glance. Amber is neither: it is the server saying it tried and could
    /// not (a refused Local Network prompt, most often), which would otherwise
    /// present as "nobody ever connects".
    private var tint: Color {
        if isEnabled, server.failure != nil { return .orange }
        return isEnabled ? .green : .red
    }

    private var glyph: String {
        if isEnabled, server.failure != nil { return "exclamationmark.triangle.fill" }
        return isEnabled ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash"
    }

    /// A send in flight draws its own progress around the pill. The row this
    /// replaced showed a bar and a byte count; losing sight of a 12 GB pull
    /// entirely would be a worse trade than the tidier header is worth, and the
    /// numbers are inside the sheet.
    @ViewBuilder
    private var sendingRing: some View {
        // `fraction` is nil rather than a guess when the job has no honest
        // denominator, and a ring is nothing but a denominator — so there is
        // no ring then, and the sheet's byte count is the only readout.
        if let fraction = server.activeTransfer?.fraction {
            Circle()
                .trim(from: 0, to: max(0.02, fraction))
                .stroke(LL.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(-3)
                .animation(.easeOut(duration: 0.25), value: fraction)
        }
    }

    private var accessibilityLabel: String {
        guard isEnabled else { return "Project syncing, sharing off" }
        if let transfer = server.activeTransfer {
            return "Project syncing, sending \(transfer.projectName)"
        }
        if server.failure != nil { return "Project syncing, sharing unavailable" }
        return "Project syncing, sharing on"
    }
}

/// The nearby-device server's lifecycle, hung off whichever list is showing
/// its pill: armed when the list appears with the switch on, taken down
/// with the switch, and on iOS stood down in the background. One modifier
/// for the two lists, because the server is the model's and a list's
/// `onChange` only fires while that list exists — a switch thrown in the
/// Gallery's panel must take the listener with it whether or not the
/// Projects tab was ever visited.
struct ProjectSharingArming: ViewModifier {
    @ObservedObject var server: ProjectTransferServer
    var isEnabled: Bool
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onAppear {
                if isEnabled, !server.isRunning { server.start() }
            }
            // Turning the setting off has to take the live listener with it —
            // otherwise the device goes on advertising until the app is
            // relaunched, which is precisely the "a code left advertising on a
            // phone in a bag" failure this feature has to design out.
            .onChange(of: isEnabled) { enabled in
                if enabled {
                    if !server.isRunning { server.start() }
                } else {
                    server.stop()
                }
            }
            // iOS suspends network activity in the background anyway; standing
            // the listener down makes that honest rather than silent. A cable
            // does not buy background time either, so this holds over USB too.
            //
            // macOS has no equivalent — switching apps never backgrounds a Mac
            // scene — so there the stand-down is `ProjectTransferServer.idleTimeout`
            // instead: 15 minutes with nobody connected and the listener stops
            // itself, because a Mac left advertising its whole library while
            // nobody is sitting at it is exactly the failure to design out.
            #if os(iOS)
            .onChange(of: scenePhase) { phase in
                guard isEnabled else { return }
                if phase == .background {
                    server.stop()
                } else if phase == .active, !server.isRunning {
                    server.start()
                }
            }
            #endif
    }
}

extension View {
    func armsProjectSharing(_ server: ProjectTransferServer, isEnabled: Bool) -> some View {
        modifier(ProjectSharingArming(server: server, isEnabled: isEnabled))
    }
}

/// What the pill opens: **Project Syncing** — the PicPlace block (sign in,
/// or the check, its status and the way to the full card), then the
/// nearby-devices block (the switch, the code, the code as a QR, and
/// whatever the server is doing right now).
///
/// The QR is the same code in a form another device's camera can read
/// (`PairingQR`), which is what lets the importing end skip typing six digits
/// off one screen into another. It is drawn from `server.pairingCode`, so it
/// rotates with the code and simply is not there when there is nothing to pair
/// with.
struct ProjectSyncSheet: View {
    @ObservedObject var server: ProjectTransferServer
    @ObservedObject var picplace: PicPlaceController
    @Binding var isEnabled: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    LLSectionHeader("PicPlace")
                    picplaceBlock
                    LLSectionHeader("Nearby devices")
                        .padding(.top, 6)
                    toggleRow
                    if isEnabled {
                        codeBlock
                    } else {
                        Text("While this is off, this device does not advertise itself and no other device can see its projects.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let transfer = server.activeTransfer {
                        sending(transfer)
                    }
                    if let failure = server.failure {
                        Label(failure, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(LL.screenBackground)
        .picplaceConnectAlert(picplace)
        .picplaceConflictsSheet(picplace)
        .onAppear { if picplace.isSignedIn { picplace.refreshUsage() } }
        #if os(macOS)
        .frame(width: 360, height: 620)
        #else
        .presentationDetents([.medium, .large])
        #endif
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Project Syncing")
                .font(.headline)
            Spacer()
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
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: PicPlace

    /// Signed out → the sign-in button. Signed in on a library that is not
    /// this account's → connect it (or who it belongs to). Connected → the
    /// account line, what is happening, *Check PicPlace now*, and the way to
    /// the full card. The server address is Settings' alone.
    @ViewBuilder
    private var picplaceBlock: some View {
        if !picplace.isSignedIn {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    if picplace.isSigningIn { picplace.cancelSignIn() } else { picplace.signIn() }
                } label: {
                    Label(picplace.isSigningIn ? "Signing in…" : signInTitle,
                          systemImage: picplace.isSigningIn ? "hourglass" : "person.crop.circle.badge.checkmark")
                        .font(.system(size: 15, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(LL.accent)
                Text(picplace.isSigningIn
                     ? "Finish in your browser, or tap to cancel"
                     : (picplace.lastSignInError ?? signInSubtitle))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if !picplace.canSync {
            VStack(alignment: .leading, spacing: 6) {
                if picplace.libraryLink == .unbound {
                    Button {
                        picplace.offerConnect()
                    } label: {
                        Label(picplace.isConnecting ? "Connecting…" : "Connect this library", systemImage: "icloud.and.arrow.up")
                            .font(.system(size: 15, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(LL.accent)
                    .disabled(picplace.isConnecting)
                    Text(picplace.lastConnectError
                         ?? "Signed in as @\(picplace.profile?.username ?? ""). Keep this library's projects on \(picplace.sessionHost) too.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Label("This library belongs to @\(picplace.binding?.user.displayHandle ?? "") on \(picplace.binding?.server.host ?? "")",
                          systemImage: "person.crop.circle.badge.exclamationmark")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(LL.levelOff)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Sign in as them to sync it, or disconnect it in Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                settingsLink
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                // The account, and what the server holds of it.
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.icloud.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.green)
                    Text(accountLine)
                        .font(.system(size: 15, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                statusLine
                checkButton
                settingsLink
            }
        }
    }

    private var signInTitle: String {
        if let binding = picplace.binding { return "Sign in as @\(binding.user.displayHandle)" }
        return "Sign in with PicPlace"
    }

    private var signInSubtitle: String {
        if let binding = picplace.binding { return "This library belongs to @\(binding.user.displayHandle) on \(binding.server.host)" }
        return "Keep a copy of your projects on \(picplace.sessionHost)"
    }

    private var accountLine: String {
        var line = "@\(picplace.profile?.username ?? "") on \(picplace.sessionHost)"
        if let usage = picplace.usage { line += " · \(usage.projects) project\(usage.projects == 1 ? "" : "s")" }
        return line
    }

    /// What is happening, one line: decisions waiting come first, then what
    /// auto-sync is doing or why it is not, then the first connection, then
    /// the last problem — the same readings as the Settings card, in the
    /// order a person needs them.
    @ViewBuilder
    private var statusLine: some View {
        if !picplace.conflicts.isEmpty {
            Button {
                picplace.isReviewingConflicts = true
            } label: {
                HStack(spacing: 8) {
                    Label("\(picplace.conflicts.count) project\(picplace.conflicts.count == 1 ? "" : "s") need\(picplace.conflicts.count == 1 ? "s" : "") your decision",
                          systemImage: "exclamationmark.icloud.fill")
                        .foregroundStyle(LL.amber)
                    Spacer(minLength: 0)
                    Text("Review")
                        .foregroundStyle(LL.accent)
                }
                .font(.system(size: 13.5, weight: .medium))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else if let status = picplace.autoStatus {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(status)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        } else if let progress = picplace.initialSyncProgress, progress.phase != .done {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(initialSyncLine(progress))
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        } else if let error = picplace.autoError {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.system(size: 13.5))
                .foregroundStyle(LL.levelOff)
                .fixedSize(horizontal: false, vertical: true)
        } else if let hold = picplace.autoHold {
            Label("Auto-sync \(hold)", systemImage: "pause.circle")
                .font(.system(size: 13.5))
                .foregroundStyle(.secondary)
        } else if picplace.autoSyncEnabled {
            Label("Edits go to PicPlace as you make them", systemImage: "arrow.triangle.2.circlepath")
                .font(.system(size: 13.5))
                .foregroundStyle(.secondary)
        } else {
            Label("Auto-sync is off — projects sync when you ask", systemImage: "pause.circle")
                .font(.system(size: 13.5))
                .foregroundStyle(.secondary)
        }
    }

    private func initialSyncLine(_ progress: PicPlaceController.InitialSyncProgress) -> String {
        switch progress.phase {
        case .waiting(let why): return "First connection — \(why.lowercased())"
        case .deciding: return "Comparing with PicPlace…"
        case .pulling: return "Bringing projects here… \(progress.pulled) of \(progress.total)"
        case .pushing: return "Sending projects… \(progress.pulled + progress.pushed) of \(progress.total)"
        case .done: return "Library in step with PicPlace"
        case .failed(let why): return "First connection failed — \(why)"
        }
    }

    private var checkButton: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                picplace.checkForChanges(reason: "manual")
            } label: {
                HStack(spacing: 8) {
                    if picplace.isChecking {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise.icloud")
                    }
                    Text(picplace.isChecking ? "Checking PicPlace…" : "Check PicPlace now")
                }
                .font(.system(size: 15, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            .tint(LL.accent)
            .disabled(picplace.isChecking)
            Text(picplace.checkSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The full card — account, library, the switches, the server — is in
    /// Settings; this panel only carries what a person needs beside the list.
    private var settingsLink: some View {
        Button {
            dismiss()
            picplace.model.requestedSettingsAnchor = .picplace
        } label: {
            HStack(spacing: 4) {
                Text("All PicPlace settings")
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
            }
            .font(.system(size: 13.5, weight: .medium))
            .foregroundStyle(LL.accent)
        }
        .buttonStyle(.plain)
    }

    // MARK: Nearby devices

    private var toggleRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $isEnabled) {
                Text("Share with nearby devices")
                    .font(.system(size: 15, weight: .medium))
            }
            .tint(.green)
            Text("The same switch as Settings ▸ Advanced. Anyone with the code can copy every project on this device, not just one.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var codeBlock: some View {
        if server.pairingCode.count == 6 {
            VStack(alignment: .leading, spacing: 10) {
                // Two groups of three, spaced: read off a phone lying on the
                // desk and typed on the Mac without losing your place.
                Text(spaced(server.pairingCode))
                    .font(.system(size: 30, weight: .semibold).monospacedDigit())
                    .foregroundStyle(LL.accent)
                    .accessibilityLabel(server.pairingCode.map(String.init).joined(separator: " "))
                    .textSelection(.enabled)

                if let qr = PairingQR.image(code: server.pairingCode) {
                    HStack {
                        Spacer(minLength: 0)
                        Image(decorative: qr, scale: 1)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 180, height: 180)
                            .padding(10)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .accessibilityHidden(true)
                        Spacer(minLength: 0)
                    }
                }

                Text("On the other device: Create ▸ Import a LetsLapse project ▸ From another device, pick this one, then point its camera here — or type the code.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Starting…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func sending(_ transfer: ProjectTransferServer.TransferProgress) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Sending \(transfer.projectName)", systemImage: "arrow.up.circle.fill")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(.green)
            Text(detail(transfer))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let fraction = transfer.fraction {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.12))
                        Capsule()
                            .fill(LL.accent)
                            .frame(width: max(0, geometry.size.width * fraction))
                    }
                }
                .frame(height: 4)
                .animation(.easeOut(duration: 0.25), value: fraction)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LL.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func detail(_ transfer: ProjectTransferServer.TransferProgress) -> String {
        guard transfer.totalBytes > 0 else { return LLFormat.bytes(transfer.bytesTransferred) }
        return "\(LLFormat.bytes(transfer.bytesTransferred)) of \(LLFormat.bytes(transfer.totalBytes))"
    }

    private func spaced(_ code: String) -> String {
        let digits = Array(code)
        return String(digits[0..<3]) + " " + String(digits[3...])
    }
}
#endif
