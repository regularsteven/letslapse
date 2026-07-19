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

            if remote.isReachable {
                Button {
                    if remote.recordingState == .recording {
                        remote.stopRecording()
                    } else {
                        remote.startRecording()
                    }
                } label: {
                    Label(actionTitle, systemImage: actionIcon)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(remote.recordingState == .recording ? .red : .accentColor)
                .disabled(remote.isSending)
            } else {
                Button {
                    remote.refreshState()
                } label: {
                    Label("Find iPhone", systemImage: "iphone.slash")
                        .frame(maxWidth: .infinity)
                }
                .disabled(remote.isSending)
            }
        }
        .padding(.horizontal, 8)
        .onAppear {
            remote.refreshState()
        }
    }

    private var actionTitle: String {
        remote.recordingState == .recording ? "Stop" : "Start"
    }

    private var actionIcon: String {
        remote.recordingState == .recording ? "stop.fill" : "record.circle"
    }

    private var statusLine: String {
        if let lastRoundTripMilliseconds = remote.lastRoundTripMilliseconds {
            return "\(remote.statusText) · \(lastRoundTripMilliseconds) ms"
        }
        return remote.statusText
    }
}
