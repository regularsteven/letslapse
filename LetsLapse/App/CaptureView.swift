#if os(iOS)
import SwiftUI
import AVFoundation

struct CaptureView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case video = "Video"
        case interval = "Interval"
        var id: String { rawValue }
    }

    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = CameraController()
    @State private var mode: Mode = .video
    @State private var interval: Double = 2
    @State private var highFrameRate = false

    var body: some View {
        ZStack {
            CameraPreview(session: camera.session)
                .ignoresSafeArea()

            if camera.isAuthorized == false {
                VStack(spacing: 12) {
                    Image(systemName: "video.slash")
                        .font(.largeTitle)
                    Text("Camera access is needed to capture. Enable it in Settings.")
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                .foregroundStyle(.white)
            }

            VStack {
                HStack {
                    Button("Cancel") {
                        camera.stop()
                        dismiss()
                    }
                    .padding()
                    .foregroundStyle(.white)
                    Spacer()
                    Text(camera.activeFormatDescription)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.8))
                        .padding()
                }
                Spacer()
                controls
                    .padding()
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 16))
                    .padding()
            }
        }
        .statusBarHidden()
        .onAppear {
            camera.onFinishVideo = { url in
                camera.stop()
                dismiss()
                model.setSource(.video(url))
            }
            camera.onFinishPhotos = { urls in
                camera.stop()
                dismiss()
                model.setSource(.photos(urls))
            }
            camera.start()
        }
    }

    @ViewBuilder
    private var controls: some View {
        VStack(spacing: 14) {
            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(camera.isRecording || camera.isIntervalRunning)

            switch mode {
            case .video:
                Toggle("High frame rate (slow-mo source)", isOn: $highFrameRate)
                    .foregroundStyle(.white)
                    .onChange(of: highFrameRate) { enabled in
                        camera.setHighFrameRate(enabled)
                    }
                    .disabled(camera.isRecording)
                Button {
                    camera.isRecording ? camera.stopRecording() : camera.startRecording()
                } label: {
                    Label(
                        camera.isRecording ? "Stop Recording" : "Record",
                        systemImage: camera.isRecording ? "stop.circle.fill" : "record.circle")
                    .font(.title2)
                    .foregroundStyle(camera.isRecording ? .red : .white)
                }
            case .interval:
                if !camera.isIntervalRunning {
                    HStack {
                        Text("Every \(interval, specifier: "%.1f")s")
                            .foregroundStyle(.white)
                            .monospacedDigit()
                        Slider(value: $interval, in: 0.5...10, step: 0.5)
                    }
                } else {
                    Text("\(camera.photoCount) photos captured")
                        .foregroundStyle(.white)
                        .monospacedDigit()
                }
                Button {
                    camera.isIntervalRunning ? camera.stopInterval() : camera.startInterval(every: interval)
                } label: {
                    Label(
                        camera.isIntervalRunning ? "Finish (\(camera.photoCount))" : "Start Interval Capture",
                        systemImage: camera.isIntervalRunning ? "stop.circle.fill" : "camera.on.rectangle")
                    .font(.title2)
                    .foregroundStyle(camera.isIntervalRunning ? .red : .white)
                }
            }
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
#endif
