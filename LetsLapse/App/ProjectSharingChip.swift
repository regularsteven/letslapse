#if !os(watchOS)
import SwiftUI

/// The Projects header's "this device is sharing" chip.
///
/// Modelled on `RemoteLinkChip`, and deliberately somewhere else. That chip
/// lives on the capture screen because the camera remote's code is regenerated
/// every time that screen appears, so a code read anywhere else would already
/// be stale. This code has a different lifetime — it survives tab switches and
/// navigation, which is the point of not hanging the server off a screen — so
/// it belongs where the library is.
///
/// Its own view rather than a computed property on `ProjectsView` so it can
/// `@ObservedObject` the server directly: the list observes the *model*, so the
/// server's published changes — code minted, transfer started — would never
/// redraw a chip built inline there.
///
/// Shared with macOS since Phase 3: a Mac serves its library through the same
/// server and shows the same chip in the same header. The Mac has no
/// scene-phase stand-down, so there the chip is also the only visible sign that
/// this machine is advertising — which is exactly why it is not tucked away.
struct ProjectSharingChip: View {
    @ObservedObject var server: ProjectTransferServer
    /// Stops sharing. A tap anywhere on the chip does this — there is nowhere
    /// else for a tap to go, and a separate hit target for one action on a
    /// row this narrow is worse than the whole row being the button.
    var onStop: () -> Void

    var body: some View {
        Button(action: onStop) {
            content
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Stops sharing this library")
    }

    @ViewBuilder
    private var content: some View {
        if let transfer = server.activeTransfer {
            row(
                dot: .green,
                icon: "arrow.up.circle.fill",
                title: "Sending \(transfer.projectName)",
                detail: sendingDetail(transfer),
                trailing: "Stop",
                fraction: transfer.fraction)
        } else if let failure = server.failure {
            // Most likely a denied Local Network prompt, which otherwise
            // presents as "nobody ever connects".
            row(
                dot: .orange,
                icon: "exclamationmark.triangle.fill",
                title: "Sharing unavailable",
                detail: failure,
                trailing: "Stop",
                fraction: nil)
        } else {
            row(
                dot: LL.amber,
                icon: "arrow.up.circle.fill",
                title: "Sharing",
                detail: nil,
                trailing: "Tap to stop",
                fraction: nil,
                code: server.pairingCode)
        }
    }

    private func sendingDetail(_ transfer: ProjectTransferServer.TransferProgress) -> String {
        guard transfer.totalBytes > 0 else { return LLFormat.bytes(transfer.bytesTransferred) }
        return "\(LLFormat.bytes(transfer.bytesTransferred)) of \(LLFormat.bytes(transfer.totalBytes))"
    }

    private func row(
        dot: Color,
        icon: String,
        title: String,
        detail: String?,
        trailing: String,
        fraction: Double?,
        code: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(dot)

                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.primary)

                if let code, code.count == 6 {
                    // Two groups of three, spaced: read off a phone lying on
                    // the desk and typed on the Mac without losing your place.
                    Text(spaced(code))
                        .font(.system(size: 15, weight: .semibold).monospacedDigit())
                        .foregroundStyle(LL.accent)
                        .accessibilityLabel(code.map(String.init).joined(separator: " "))
                }

                Spacer(minLength: 8)

                Text(trailing)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            if let detail {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if let fraction {
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
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LL.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(dot.opacity(0.35), lineWidth: 1))
        .contentShape(Rectangle())
    }

    private func spaced(_ code: String) -> String {
        let digits = Array(code)
        return String(digits[0..<3]) + " " + String(digits[3...])
    }

    private var accessibilityLabel: String {
        if let transfer = server.activeTransfer {
            return "Sending \(transfer.projectName). Tap to stop sharing."
        }
        return "Sharing this library. Code \(server.pairingCode.map(String.init).joined(separator: " ")). Tap to stop."
    }
}
#endif
