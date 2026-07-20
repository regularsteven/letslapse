#if os(iOS)
import SwiftUI
import AVFoundation

struct CaptureView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case video = "Video"
        case interval = "Interval"
        var id: String { rawValue }
    }

    enum PreviewLayout: String, CaseIterable, Identifiable {
        case fullscreen = "Fullscreen"
        case window = "Window"
        var id: String { rawValue }
    }

    var onCaptureComplete: () -> Void = {}

    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var watchRemote = WatchRemoteControlReceiver.shared
    @StateObject private var camera = CameraController()
    @State private var mode: Mode = .video
    @State private var previewLayout: PreviewLayout = .fullscreen
    @State private var interval: Double = 2
    @State private var orientation = currentCaptureOrientation()
    @State private var now = Date()
    private let recordingTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            preview

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
                    .background(.black.opacity(0.45), in: Capsule())
                    Spacer()
                    Text(camera.activeFormatDescription)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.8))
                        .padding()
                        .background(.black.opacity(0.45), in: Capsule())
                }
                .padding(.horizontal)
                .padding(.top)
                Spacer()
                controls
                    .padding()
                    .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(.white.opacity(0.16))
                    }
                    .padding()
            }
        }
        .statusBarHidden()
        .onAppear {
            watchRemote.activate()
            watchRemote.setCommandHandler(handleWatchCommand)
            updateWatchRecordingState()
            updateIdleTimer()
            camera.onFinishVideo = { url in
                camera.stop()
                dismiss()
                model.setSource(.video(url), mode: camera.activeFormatDescription)
                onCaptureComplete()
            }
            camera.onFinishPhotos = { urls in
                camera.stop()
                dismiss()
                model.setSource(.photos(urls), mode: "Interval photos")
                onCaptureComplete()
            }
            orientation = currentCaptureOrientation()
            camera.setVideoOrientation(orientation)
            camera.start()
        }
        .onDisappear {
            watchRemote.setCommandHandler(nil)
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            orientation = currentCaptureOrientation()
            camera.setVideoOrientation(orientation)
        }
        .onChange(of: camera.isRecording) { _ in
            updateWatchRecordingState()
            updateIdleTimer()
        }
        .onChange(of: camera.recordingStartedAt) { _ in
            now = Date()
            updateWatchRecordingState()
        }
        .onChange(of: camera.isIntervalRunning) { _ in
            updateIdleTimer()
        }
        .onReceive(recordingTimer) { date in
            now = date
        }
    }

    @ViewBuilder
    private var preview: some View {
        switch previewLayout {
        case .fullscreen:
            CameraPreview(session: camera.session, orientation: orientation, videoGravity: .resizeAspectFill)
                .ignoresSafeArea()
        case .window:
            VStack {
                CameraPreview(session: camera.session, orientation: orientation, videoGravity: .resizeAspect)
                    .aspectRatio(previewAspectRatio, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(.white.opacity(0.18))
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 84)
                Spacer(minLength: 260)
            }
        }
    }

    private var previewAspectRatio: CGFloat {
        let resolution = camera.selectedResolution
        let width = CGFloat(max(resolution.width, 1))
        let height = CGFloat(max(resolution.height, 1))
        return orientation == .portrait || orientation == .portraitUpsideDown
            ? height / width
            : width / height
    }

    @ViewBuilder
    private var controls: some View {
        VStack(spacing: 14) {
            CaptureSegmentedControl(
                options: PreviewLayout.allCases,
                selection: $previewLayout
            ) { layout in
                layout.rawValue
            }

            CaptureSegmentedControl(
                options: Mode.allCases,
                selection: $mode,
                isDisabled: camera.isRecording || camera.isIntervalRunning
            ) { mode in
                mode.rawValue
            }

            if camera.availableLenses.count > 1 {
                CaptureSegmentedControl(
                    options: camera.availableLenses,
                    selection: $camera.selectedLens,
                    isDisabled: camera.isRecording || camera.isIntervalRunning
                ) { lens in
                    lens.label
                }
                .onChange(of: camera.selectedLens) { lens in
                    camera.selectLens(lens)
                }
            }

            if mode == .video {
                stabilizationControl
            }

            if !camera.availableResolutions.isEmpty {
                VStack(spacing: 8) {
                    HStack(spacing: 12) {
                        Picker("Resolution", selection: $camera.selectedResolution) {
                            ForEach(camera.availableResolutions) { resolution in
                                Text(resolution.label).tag(resolution)
                            }
                        }
                        .onChange(of: camera.selectedResolution) { resolution in
                            camera.selectResolution(resolution)
                        }

                        Picker("Frame rate", selection: $camera.selectedFrameRate) {
                            ForEach(camera.availableFrameRates, id: \.self) { fps in
                                Text("\(fps) fps").tag(fps)
                            }
                        }
                        .onChange(of: camera.selectedFrameRate) { fps in
                            camera.selectFrameRate(fps)
                        }
                    }
                }
                .pickerStyle(.menu)
                .tint(.white)
                .disabled(camera.isRecording || camera.isIntervalRunning)
            }

            switch mode {
            case .video:
                if camera.isRecording {
                    Text(elapsedRecordingTime)
                        .font(.title3.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 12)
                        .background(.red.opacity(0.28), in: Capsule())
                }
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

    private func handleWatchCommand(_ command: WatchCaptureCommand) {
        switch command {
        case .startRecording:
            guard !camera.isRecording, !camera.isIntervalRunning else { return }
            mode = .video
            camera.startRecording()
        case .stopRecording:
            camera.stopRecording()
        case .state:
            updateWatchRecordingState()
        }
    }

    private func updateWatchRecordingState() {
        watchRemote.setRecordingState(
            camera.isRecording ? .recording : .idle,
            startedAt: camera.recordingStartedAt
        )
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = camera.isRecording || camera.isIntervalRunning
    }

    private var elapsedRecordingTime: String {
        guard let startedAt = camera.recordingStartedAt else { return "00:00" }
        return DurationFormatter.recordingTime(from: max(0, now.timeIntervalSince(startedAt)))
    }

    private var stabilizationBinding: Binding<Bool> {
        Binding {
            camera.isVideoStabilizationEnabled
        } set: { isEnabled in
            camera.setVideoStabilizationEnabled(isEnabled)
        }
    }

    private var stabilizationControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: stabilizationBinding) {
                Label("Stabilization", systemImage: "hand.raised")
                    .foregroundStyle(.white)
            }
            .toggleStyle(.switch)
            .tint(.green)

            Text(camera.isVideoStabilizationEnabled
                 ? "Filters formats to stabilization-capable modes."
                 : "Advanced: full format list for tripod or stable rigs.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(2)
        }
        .disabled(camera.isRecording || camera.isIntervalRunning)
    }
}

private struct CaptureSegmentedControl<Option: Identifiable & Equatable>: View where Option.ID: Hashable {
    let options: [Option]
    @Binding var selection: Option
    var isDisabled = false
    var title: (Option) -> String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options) { option in
                let isSelected = option == selection
                Button {
                    selection = option
                } label: {
                    Text(title(option))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .foregroundStyle(isSelected ? .black : .white.opacity(0.88))
                        .frame(maxWidth: .infinity, minHeight: 42)
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .background(
                    isSelected ? .white : .white.opacity(0.14),
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSelected ? .white.opacity(0.82) : .white.opacity(0.12))
                }
            }
        }
        .padding(4)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .opacity(isDisabled ? 0.55 : 1)
        .allowsHitTesting(!isDisabled)
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let orientation: AVCaptureVideoOrientation
    let videoGravity: AVLayerVideoGravity

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        override func layoutSubviews() {
            super.layoutSubviews()
            previewLayer.frame = bounds
        }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = videoGravity
        if view.previewLayer.connection?.isVideoOrientationSupported == true {
            view.previewLayer.connection?.videoOrientation = orientation
        }
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.previewLayer.frame = uiView.bounds
        uiView.previewLayer.videoGravity = videoGravity
        if uiView.previewLayer.connection?.isVideoOrientationSupported == true {
            uiView.previewLayer.connection?.videoOrientation = orientation
        }
    }
}
#endif
