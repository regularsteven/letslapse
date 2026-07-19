import SwiftUI

struct WatchControlView: View {
    @EnvironmentObject private var remote: WatchCaptureRemote

    var body: some View {
        VStack(spacing: 10) {
            VStack(spacing: 2) {
                Text(remote.recordingState == .recording ? "Recording" : "Idle")
                    .font(.headline)
                    .foregroundStyle(remote.recordingState == .recording ? .red : .primary)
                Text(statusLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)

            Button {
                remote.stopRecording()
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(remote.isSending)

            Button {
                remote.startRecording()
            } label: {
                Label("Start", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .disabled(remote.isSending)
        }
        .padding(.horizontal, 8)
        .onAppear {
            remote.refreshState()
        }
    }

    private var statusLine: String {
        if let lastRoundTripMilliseconds = remote.lastRoundTripMilliseconds {
            return "\(remote.statusText) · \(lastRoundTripMilliseconds) ms"
        }
        return remote.statusText
    }
}
