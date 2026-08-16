#if os(macOS)
import SwiftUI

/// The Mac remote: a Watch-sized canvas running the real `WatchControlView`,
/// wrapped in the connection chrome the Watch has no equivalent for.
///
/// Watch-sized is the point. The whole reason this shares view code rather than
/// resembling the Watch is that layout decisions have to transfer back — a
/// Mac-only improvement is a regression against the goal. So the canvas is
/// pinned to 208×248 pt (Apple Watch 46 mm, matching docs/design/watchOS) and
/// only the chrome around it is Mac-shaped.
struct RemoteWindow: View {
    @StateObject private var transport: LocalNetworkTransport
    @StateObject private var remote: WatchCaptureRemote

    @State private var selected: DiscoveredCamera?
    @State private var code = ""
    @State private var connectError: String?
    @State private var isConnecting = false

    /// The Watch canvas, 46 mm. Layout parity with the watchOS SVGs depends on
    /// this staying exact.
    private static let watchCanvas = CGSize(width: 208, height: 248)

    init() {
        let transport = LocalNetworkTransport()
        _transport = StateObject(wrappedValue: transport)
        _remote = StateObject(wrappedValue: WatchCaptureRemote(transport: transport))
    }

    var body: some View {
        VStack(spacing: 0) {
            if remote.isReachable {
                connectedChrome
                watchCanvas
            } else {
                picker
            }
        }
        .frame(width: 260)
        .onAppear {
            transport.startBrowsing()
            #if DEBUG
            autoConnectIfRequested()
            #endif
        }
        // A camera that goes away must take the selection with it. Otherwise
        // the picker shows "Looking for cameras…" AND an enabled Connect
        // button wired to a stale endpoint — found while testing, and it dials
        // a camera that is no longer there.
        .onChange(of: transport.cameras) { cameras in
            guard let selected else { return }
            if !cameras.contains(where: { $0.id == selected.id }) {
                self.selected = nil
                code = ""
                isConnecting = false
                connectError = nil
            }
        }
    }

    // MARK: - The mirrored view

    private var watchCanvas: some View {
        WatchControlView()
            .environmentObject(remote)
            .frame(width: Self.watchCanvas.width, height: Self.watchCanvas.height)
            // NO font override here, deliberately, and it was tried.
            //
            // watchOS renders SF Compact and macOS renders SF Pro, so text
            // measures differently and can wrap in different places. The
            // obvious fix — forcing SF Compact through the environment — is
            // worse than the disease: `.environment(\.font,)` sets the
            // INHERITED font only, at one fixed size, so every view that
            // doesn't state its own size renders at that size instead of the
            // one it was designed for. It swallowed the format line outright.
            // Fixing it properly would mean rewriting every `.font()` call in
            // WatchControlView, damaging the watchOS side to flatter this one.
            //
            // So the gap is documented rather than papered over: the Mac is
            // the fast iteration surface, and the paired-sim rig stays the
            // sign-off gate. No watchOS SVG is marked synced from a
            // screenshot taken here.
            .background(Color.black)
            // watchOS has no light mode. Without this the canvas inherits the
            // Mac window's appearance, so semantic colours resolve for light
            // mode against a black background — `.secondary` becomes a dark
            // grey on black and text simply vanishes. That is what was
            // swallowing the format line, and it would have been read as a
            // missing binding rather than an invisible one.
            .environment(\.colorScheme, .dark)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(12)
    }

    // MARK: - Chrome

    private var connectedChrome: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.green)
                .frame(width: 6, height: 6)
            Text(selected?.name ?? "Camera")
                .font(.caption)
                .lineLimit(1)
            Spacer()
            Button("Disconnect") {
                transport.disconnect()
                selected = nil
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    @ViewBuilder
    private var picker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connect to a camera")
                .font(.headline)

            if let failure = transport.browseFailure {
                // A denied Local Network prompt is otherwise indistinguishable
                // from "no cameras on this network", which is the single most
                // confusing failure this link has.
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text("Check System Settings ▸ Privacy & Security ▸ Local Network.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if transport.cameras.isEmpty {
                Text("Looking for cameras…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Open the capture screen on the iPad. The link only exists while the camera is on screen.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            ForEach(transport.cameras) { camera in
                Button {
                    selected = camera
                    connectError = nil
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: camera.isRecording ? "record.circle" : "camera")
                            .foregroundStyle(camera.isRecording ? .red : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(camera.name).font(.callout)
                            Text(camera.isRecording ? "Recording" : camera.model)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if selected == camera {
                            Image(systemName: "checkmark")
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if selected != nil {
                Divider()
                Text("Pairing code")
                    .font(.caption)
                Text("Shown on the camera's capture screen.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                HStack {
                    TextField("000000", text: $code)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .onSubmit(connect)
                    Button(isConnecting ? "Pairing…" : "Connect", action: connect)
                        .disabled(code.count != 6 || isConnecting)
                }
                if let connectError {
                    Text(connectError)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
                if let diagnostic = transport.connectionDiagnostic {
                    Text(diagnostic)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(14)
    }

    #if DEBUG
    /// `LL_REMOTE_CONNECT=<6-digit code>` dials the first camera found as soon
    /// as one appears.
    ///
    /// Pairing is deliberately a human act — a code read off the camera's own
    /// screen, typed here — which is exactly right for the product and exactly
    /// wrong for verifying the link, because it makes the one thing worth
    /// checking (does the Mac show what the iPad is really doing?) unreachable
    /// without a person at both ends. The code still has to be correct, so this
    /// weakens nothing: it types, it does not bypass. DEBUG-only.
    private func autoConnectIfRequested() {
        guard let wanted = ProcessInfo.processInfo.environment["LL_REMOTE_CONNECT"],
              wanted.count == 6 else { return }
        code = wanted
        // Poll rather than hook the browser: discovery is asynchronous and can
        // take a couple of seconds on a busy network.
        Task { @MainActor in
            for _ in 0..<40 {
                if transport.isReachable { return }
                if selected == nil, let first = transport.cameras.first {
                    selected = first
                    connect()
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }
    #endif

    private func connect() {
        guard let selected, code.count == 6 else { return }
        connectError = nil
        isConnecting = true
        transport.connect(to: selected, code: code)
        // The camera rejects a wrong code by failing its own first read, which
        // never reaches this side — the connection just sits in .preparing.
        // The transport's own timeout reports it; this only has to stop
        // showing "Pairing…" forever if that path is ever missed.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 9_000_000_000)
            if !transport.isReachable {
                isConnecting = false
                connectError = connectError ?? "Couldn't pair — check the code on the camera"
            } else {
                isConnecting = false
            }
        }
    }
}
#endif
