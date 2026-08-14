#if os(watchOS) || os(macOS)
import SwiftUI

/// A look through the phone's lens, on the wrist.
///
/// You are looking at the watch while your hands move the phone, so this
/// screen is the frame and almost nothing else: the picture, how old it is,
/// and START within reach so framing and starting are one gesture apart.
///
/// Two things it refuses to do:
///
/// - **Pretend a dead frame is live.** A stalled preview is desaturated,
///   blurred, hatched AND captioned — four independent signals, because any
///   one of them can be missed in bright sun or at a glance, and a stale frame
///   read as live is how you shoot forty minutes of the wrong thing.
/// - **Claim to be level when it doesn't know.** No roll reading means no
///   horizon bar, rather than a bar drawn confidently at zero.
struct FramingPreviewView: View {
    @EnvironmentObject private var remote: WatchCaptureRemote
    @Environment(\.dismiss) private var dismiss

    @State private var now = Date()
    @State private var showAids = true
    @State private var lens: AspectLens = .native
    @State private var lensCrown: Double = 0
    @State private var lastLensCrown: Double = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// A frame older than this is not a preview any more.
    private let staleAfter: TimeInterval = 2.5

    /// How the incoming frame is fitted to the watch.
    ///
    /// This is a **viewing lens only** — nothing here is sent to the phone and
    /// no capture or canvas setting changes. It answers "what would this look
    /// like cropped square / tall / wide", which is the question you are
    /// actually asking while you nudge a tripod.
    enum AspectLens: CaseIterable {
        /// The camera's own aspect, letterboxed to fit. What you frame is what
        /// you get, so it is the default.
        case native
        case square
        case tall
        case wide

        var label: String {
            switch self {
            case .native: return "FULL"
            case .square: return "1:1"
            case .tall: return "9:16"
            case .wide: return "16:9"
            }
        }

        /// Width ÷ height, or nil to use the frame's own.
        func ratio(native: Double) -> Double {
            switch self {
            case .native: return native
            case .square: return 1
            case .tall: return 9.0 / 16.0
            case .wide: return 16.0 / 9.0
            }
        }

        var next: AspectLens {
            let all = AspectLens.allCases
            let index = all.firstIndex(of: self) ?? 0
            return all[(index + 1) % all.count]
        }
    }

    private var age: TimeInterval? {
        guard let receivedAt = remote.previewReceivedAt else { return nil }
        return max(0, now.timeIntervalSince(receivedAt))
    }

    private var isStale: Bool {
        guard let age else { return remote.previewMisses >= 3 }
        return age > staleAfter || remote.previewMisses >= 3
    }

    var body: some View {
        ZStack {
            RemoteTint.ground.ignoresSafeArea()

            if let frame = remote.previewFrame {
                framePicture(frame)
            } else {
                waitingState
            }

            if isStale, remote.previewFrame != nil {
                staleBanner
            }

            controls
        }
        // No title: the back chevron is the only chrome this screen wants from
        // the navigation bar, and a title over the picture is a word competing
        // with the thing you came here to look at.
        .navigationTitle("")
        #if os(watchOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // Left-edge swipe back and the system's own back chevron. Going back
        // is navigation, and on this remote navigation is horizontal — the
        // same rule the recording tabs run on.
        .onAppear {
            remote.requestPreviewFrame()
            #if os(watchOS) && DEBUG
            // The lens is this view's own state, so the screenshot hook is
            // read here rather than in the remote.
            switch remote.debugPreviewScreen {
            case "framing-square": lens = .square
            case "framing-tall": lens = .tall
            case "framing-wide": lens = .wide
            default: break
            }
            #endif
        }
        .onDisappear {
            remote.clearPreviewFrame()
        }
        .onReceive(timer) { date in
            now = date
            remote.requestPreviewFrame()
        }
        // The crown has nothing else to do on this screen, so it cycles the
        // lens. The chip does too, for anyone who doesn't think to turn it.
        .crownAdjustable($lensCrown, from: 0, through: 10_000, by: 1)
        .onChange(of: lensCrown) { newValue in
            guard abs(newValue - lastLensCrown) >= 12 else { return }
            lastLensCrown = newValue
            lens = lens.next
        }
    }

    // MARK: - Picture

    private func framePicture(_ frame: RemotePreviewFrame) -> some View {
        GeometryReader { geometry in
            let ratio = lens.ratio(native: frame.aspect)
            let size = fitted(ratio: ratio, in: geometry.size)
            ZStack {
                Image(decorative: frame.image, scale: 1)
                    .resizable()
                    // `.fill` for the crop lenses, `.fit` for native: a square
                    // lens is asking "what does a 1:1 crop of this contain",
                    // which means filling a square with the middle of the
                    // frame, not shrinking the whole frame into one.
                    .aspectRatio(contentMode: lens == .native ? .fit : .fill)
                    .frame(width: size.width, height: size.height)
                    .clipped()

                if showAids {
                    aids(frame: frame, size: size)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            // The bars. Black rather than blurred: a letterbox should read as
            // "outside the frame", and a blurred spill reads as picture.
            .background(RemoteTint.ground)
            .modifier(StaleTreatment(isStale: isStale))
        }
        .ignoresSafeArea()
    }

    /// The largest box of `ratio` that fits, which is what produces the bars —
    /// top and bottom for a wide frame on a tallish watch, left and right for
    /// a tall one.
    private func fitted(ratio: Double, in bounds: CGSize) -> CGSize {
        guard ratio > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let boundsRatio = bounds.width / bounds.height
        if ratio > boundsRatio {
            return CGSize(width: bounds.width, height: bounds.width / ratio)
        }
        return CGSize(width: bounds.height * ratio, height: bounds.height)
    }

    // MARK: - Aids

    private func aids(frame: RemotePreviewFrame, size: CGSize) -> some View {
        ZStack {
            // Thirds.
            Path { path in
                for fraction in [1.0 / 3.0, 2.0 / 3.0] {
                    path.move(to: CGPoint(x: 0, y: size.height * fraction))
                    path.addLine(to: CGPoint(x: size.width, y: size.height * fraction))
                    path.move(to: CGPoint(x: size.width * fraction, y: 0))
                    path.addLine(to: CGPoint(x: size.width * fraction, y: size.height))
                }
            }
            .stroke(.white.opacity(0.28), lineWidth: 1)
            .frame(width: size.width, height: size.height)

            // The horizon. Only drawn when the phone actually knows.
            if let roll = frame.rollDegrees {
                horizonBar(roll: roll, width: size.width)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    /// Rotates with the phone and turns green inside ±1°.
    ///
    /// Level is the one aid worth the pixels at this fidelity: you cannot
    /// judge exposure or focus on a 40 KB JPEG at arm's length, but you can
    /// absolutely judge tilt — and tilt is the mistake that costs a whole
    /// timelapse.
    private func horizonBar(roll: Double, width: CGFloat) -> some View {
        let isLevel = abs(roll) <= 1
        return ZStack {
            Capsule()
                .fill(isLevel ? RemoteTint.go : RemoteTint.burst)
                .frame(width: width * 0.66, height: 2.5)
                .rotationEffect(.degrees(-roll))
            // A gap at the centre so the bar reads as a horizon rather than a
            // crosshair, and so the middle of the frame stays visible.
            Rectangle()
                .fill(RemoteTint.ground.opacity(0.35))
                .frame(width: width * 0.14, height: 4)
        }
    }

    // MARK: - Chrome

    private var controls: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                statusChip
                Spacer(minLength: 0)
                lensChip
            }
            .padding(.horizontal, 8)
            .padding(.top, 2)

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                aidsButton
                startButton
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
            .background(
                LinearGradient(
                    colors: [RemoteTint.ground.opacity(0.85), .clear],
                    startPoint: .bottom,
                    endPoint: .top
                )
                .ignoresSafeArea()
            )
        }
    }

    /// Live at what rate, or how stale. Always shown — a preview without an
    /// age is a picture you have to trust blindly.
    private var statusChip: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isStale ? RemoteTint.record : RemoteTint.go)
                .frame(width: 5, height: 5)
            Text(statusText)
                .font(.system(size: 9, weight: .bold))
                .kerning(0.4)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.black.opacity(0.6), in: Capsule())
    }

    private var statusText: String {
        guard let age else { return "WAITING" }
        if isStale { return String(format: "STALE %.1fs", age) }
        return String(format: "LIVE %.1fs", age)
    }

    /// Doubles as the level readout: when the phone is off level the chip
    /// carries the angle, on the burst yellow, so the number and the bar
    /// always agree.
    private var lensChip: some View {
        Button {
            lens = lens.next
        } label: {
            HStack(spacing: 4) {
                Text(lens.label)
                    .font(.system(size: 9, weight: .bold))
                if let roll = remote.previewFrame?.rollDegrees, abs(roll) > 1 {
                    Text(String(format: "%+.1f°", roll))
                        .font(.system(size: 9, weight: .heavy).monospacedDigit())
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isOffLevel ? .black : .white)
        .background(isOffLevel ? RemoteTint.burst : .black.opacity(0.6), in: Capsule())
        .accessibilityLabel("Framing lens \(lens.label)")
    }

    private var isOffLevel: Bool {
        guard let roll = remote.previewFrame?.rollDegrees else { return false }
        return abs(roll) > 1
    }

    private var aidsButton: some View {
        Button {
            showAids.toggle()
        } label: {
            Image(systemName: "grid")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(showAids ? .black : .white)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            showAids ? Color.white : Color.white.opacity(0.16),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .accessibilityLabel(showAids ? "Hide framing aids" : "Show framing aids")
    }

    /// Starting is still allowed on a stalled preview: the framing may already
    /// be right, and refusing would make a link hiccup cost the shot.
    private var startButton: some View {
        Button {
            remote.startRecording()
            dismiss()
        } label: {
            Text("START")
                .font(.system(size: 15, weight: .heavy))
                .kerning(1)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RemoteTint.record, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .disabled(remote.isSending)
    }

    private var waitingState: some View {
        VStack(spacing: 6) {
            ProgressView()
            Text("Waiting for the camera")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    private var staleBanner: some View {
        VStack(spacing: 4) {
            Spacer(minLength: 0)
            Text("Preview stalled")
                .font(.system(size: 15, weight: .bold))
            Text("Last frame, not live")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.6))
            Spacer(minLength: 0)
        }
    }
}

/// The four signals that a frame is not live: desaturated, blurred, hatched,
/// and (from the caller) captioned. Redundant on purpose — this is the one
/// mistake on this screen that silently wastes a whole shoot.
private struct StaleTreatment: ViewModifier {
    var isStale: Bool

    func body(content: Content) -> some View {
        if isStale {
            content
                .grayscale(1)
                .blur(radius: 3)
                .brightness(-0.25)
                .overlay(hatch.allowsHitTesting(false))
        } else {
            content
        }
    }

    private var hatch: some View {
        GeometryReader { geometry in
            Path { path in
                let step: CGFloat = 10
                var x = -geometry.size.height
                while x < geometry.size.width + geometry.size.height {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x + geometry.size.height, y: geometry.size.height))
                    x += step
                }
            }
            .stroke(.white.opacity(0.05), lineWidth: 5)
        }
    }
}
#endif
