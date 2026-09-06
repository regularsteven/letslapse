#if !os(watchOS)
import SwiftUI

/// The Projects header's sharing control: a pill opposite the title, and the
/// sheet behind it.
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
/// Its own view rather than a computed property on `ProjectsView` so it can
/// `@ObservedObject` the server directly: the list observes the *model*, so the
/// server's published changes — code minted, transfer started — would never
/// redraw a control built inline there.
///
/// Shared with macOS since Phase 3: a Mac serves its library through the same
/// server and shows the same pill in the same header. The Mac has no
/// scene-phase stand-down, so there the pill is also the only visible sign that
/// this machine is advertising — which is exactly why it is not tucked away.
struct ProjectSharingChip: View {
    @ObservedObject var server: ProjectTransferServer
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
        .accessibilityHint("Opens sharing, with the pairing code and its QR")
        .sheet(isPresented: $showsSheet) {
            ProjectSharingSheet(server: server, isEnabled: $isEnabled)
        }
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
        guard isEnabled else { return "Sharing off" }
        if let transfer = server.activeTransfer {
            return "Sharing on, sending \(transfer.projectName)"
        }
        if server.failure != nil { return "Sharing unavailable" }
        return "Sharing on"
    }
}

/// What the pill opens: the switch, the code, the code as a QR, and whatever
/// the server is doing right now.
///
/// The QR is the same code in a form another device's camera can read
/// (`PairingQR`), which is what lets the importing end skip typing six digits
/// off one screen into another. It is drawn from `server.pairingCode`, so it
/// rotates with the code and simply is not there when there is nothing to pair
/// with.
struct ProjectSharingSheet: View {
    @ObservedObject var server: ProjectTransferServer
    @Binding var isEnabled: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
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
        #if os(macOS)
        .frame(width: 360, height: 520)
        #else
        .presentationDetents([.medium, .large])
        #endif
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Share projects")
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
