#if os(iOS)
import SwiftUI

/// The camera half of pairing: the code a Mac has to be told, and then who is
/// holding the link.
///
/// This lives on the capture screen rather than in Settings because the code is
/// regenerated every time the listener starts — which is every time this screen
/// appears. A code read anywhere else would already be stale by the time it was
/// typed. It is also the only place the link exists at all: iOS suspends
/// network activity in the background, so leaving this screen ends the session.
///
/// Its own view rather than a computed property on CaptureView so it can
/// `@ObservedObject` the listener directly. CaptureView observes the *receiver*,
/// so the listener's published changes — code assigned, peer connected — would
/// never redraw a chip built inline there.
struct RemoteLinkChip: View {
    @ObservedObject var listener: CaptureRemoteListener

    var body: some View {
        switch listener.state {
        case .idle:
            EmptyView()
        case .advertising:
            if let code = listener.pairingCode {
                chip(
                    dot: LL.amber,
                    label: "Remote",
                    // Spaced so it can be read off a mounted iPad from across
                    // the room and typed without losing your place.
                    value: code.map(String.init).joined(separator: " "),
                    emphasised: true)
            }
        case .connected:
            chip(dot: .green, label: "Remote connected", value: nil, emphasised: false)
        case .failed(let message):
            // Most likely a denied Local Network prompt, which otherwise
            // presents as the Mac simply never finding this camera at all.
            chip(dot: .orange, label: "Remote unavailable", value: message, emphasised: false)
        }
    }

    private func chip(dot: Color, label: String, value: String?, emphasised: Bool) -> some View {
        HStack(spacing: 6) {
            Circle().fill(dot).frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
            if let value {
                Text(value)
                    .font(.system(
                        size: emphasised ? 14 : 12.5,
                        weight: emphasised ? .semibold : .medium)
                        .monospacedDigit())
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color(red: 0.17, green: 0.17, blue: 0.18).opacity(0.9), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(value.map { "\(label) \($0)" } ?? label)
    }
}
#endif
