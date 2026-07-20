import SwiftUI
import AVFoundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

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
    #if os(iOS)
    @ObservedObject private var watchRemote = WatchRemoteControlReceiver.shared
    #endif
    @StateObject private var camera = CameraController()
    @State private var mode: Mode = .video
    @State private var sequenceMode: LiveCaptureSequence.Mode = .ramp
    @State private var previewLayout: PreviewLayout = .fullscreen
    @State private var interval: Double = 2
    @State private var orientation = currentCaptureOrientation()
    @State private var now = Date()
    private let recordingTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geometry in
            captureLayout(in: geometry.size)
        }
        .background(Color.black.ignoresSafeArea())
        #if os(iOS)
        .statusBarHidden()
        #endif
        .onAppear {
            #if os(iOS)
            watchRemote.activate()
            watchRemote.setCommandHandler(handleWatchCommand)
            updateWatchRecordingState()
            updateIdleTimer()
            #endif
            camera.onFinishLiveCapture = { result in
                camera.stop()
                dismiss()
                model.setSequenceSource(result)
                onCaptureComplete()
            }
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
            #if os(iOS)
            camera.setVideoOrientation(orientation)
            #endif
            camera.start()
        }
        .onDisappear {
            #if os(iOS)
            watchRemote.setCommandHandler(nil)
            UIApplication.shared.isIdleTimerDisabled = false
            #endif
        }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            orientation = currentCaptureOrientation()
            camera.setVideoOrientation(orientation)
        }
        #endif
        .onChange(of: camera.isRecording) { _ in
            #if os(iOS)
            updateWatchRecordingState()
            updateIdleTimer()
            #endif
        }
        .onChange(of: camera.recordingStartedAt) { _ in
            now = Date()
            #if os(iOS)
            updateWatchRecordingState()
            #endif
        }
        .onChange(of: camera.activeSequenceMode) { _ in
            #if os(iOS)
            updateWatchRecordingState()
            #endif
        }
        .onChange(of: camera.markerCount) { _ in
            #if os(iOS)
            updateWatchRecordingState()
            #endif
        }
        .onChange(of: camera.rampIntervalCount) { _ in
            #if os(iOS)
            updateWatchRecordingState()
            #endif
        }
        .onChange(of: camera.segmentCount) { _ in
            #if os(iOS)
            updateWatchRecordingState()
            #endif
        }
        .onChange(of: camera.isRampActive) { _ in
            #if os(iOS)
            updateWatchRecordingState()
            #endif
        }
        .onChange(of: camera.isRampHighRate) { _ in
            #if os(iOS)
            updateWatchRecordingState()
            #endif
        }
        .onChange(of: camera.isIntervalRunning) { _ in
            #if os(iOS)
            updateIdleTimer()
            #endif
        }
        .onReceive(recordingTimer) { date in
            now = date
        }
    }

    private func captureLayout(in size: CGSize) -> some View {
        let isLandscape = size.width > size.height
        let panelWidth = landscapePanelWidth(in: size)
        let previewFrame = previewFrame(in: size, isLandscape: isLandscape, panelWidth: panelWidth)

        return ZStack(alignment: .topLeading) {
            Color.black

            // Keep one preview layer alive while changing its size and gravity. Rebuilding
            // AVCaptureVideoPreviewLayer is needlessly expensive on physical devices.
            CameraPreview(
                session: camera.session,
                orientation: orientation,
                videoGravity: previewLayout == .fullscreen ? .resizeAspectFill : .resizeAspect
            )
            .frame(width: previewFrame.size.width, height: previewFrame.size.height)
            .clipShape(RoundedRectangle(cornerRadius: previewLayout == .window ? 16 : 0))
            .overlay {
                if previewLayout == .window {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(.white.opacity(0.28), lineWidth: 1)
                }
            }
            .position(x: previewFrame.midX, y: previewFrame.midY)
            .ignoresSafeArea()

            if isLandscape {
                landscapeChrome(in: size, panelWidth: panelWidth)
            } else {
                portraitChrome(in: size)
            }

            closeButton
                .position(closeButtonPosition(in: size, previewFrame: previewFrame))

            if camera.isAuthorized == false {
                authorizationMessage
            }
        }
        .clipped()
        .transaction { transaction in
            // A camera viewport switch should feel immediate, not like a sheet animation.
            transaction.animation = nil
        }
    }

    private func previewFrame(
        in size: CGSize,
        isLandscape: Bool,
        panelWidth: CGFloat
    ) -> CGRect {
        guard previewLayout == .window else {
            return CGRect(origin: .zero, size: size)
        }

        if isLandscape {
            let paneWidth = max(1, size.width - panelWidth)
            let fitted = aspectFitSize(
                aspectRatio: previewAspectRatio,
                maxWidth: max(1, paneWidth - 16),
                maxHeight: max(1, size.height - 16)
            )
            return CGRect(
                x: (paneWidth - fitted.width) / 2,
                y: (size.height - fitted.height) / 2,
                width: fitted.width,
                height: fitted.height
            )
        }

        let previewTop: CGFloat = 8
        let controlsAllowance = min(250, size.height * 0.3)
        let maxHeight = max(120, size.height - previewTop - controlsAllowance - 8)
        let fitted = aspectFitSize(
            aspectRatio: previewAspectRatio,
            maxWidth: max(1, size.width - 20),
            maxHeight: maxHeight
        )
        return CGRect(
            x: (size.width - fitted.width) / 2,
            y: previewTop,
            width: fitted.width,
            height: fitted.height
        )
    }

    private func aspectFitSize(
        aspectRatio: CGFloat,
        maxWidth: CGFloat,
        maxHeight: CGFloat
    ) -> CGSize {
        let widthFromHeight = maxHeight * aspectRatio
        if widthFromHeight <= maxWidth {
            return CGSize(width: widthFromHeight, height: maxHeight)
        }
        return CGSize(width: maxWidth, height: maxWidth / max(aspectRatio, 0.01))
    }

    private func landscapePanelWidth(in size: CGSize) -> CGFloat {
        min(300, max(260, size.width * 0.31))
    }

    private func landscapeChrome(in size: CGSize, panelWidth: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            controls(density: .landscape)
                .padding(7)
                .dynamicTypeSize(.xSmall ... .large)
                .frame(width: panelWidth - 12)
                .background(
                    .black.opacity(previewLayout == .fullscreen ? 0.76 : 0.94),
                    in: RoundedRectangle(cornerRadius: 16)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(.white.opacity(0.15))
                }
                .position(
                    x: size.width - (panelWidth / 2) - 2,
                    y: size.height / 2
                )
        }
    }

    private func portraitChrome(in size: CGSize) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            controls(density: previewLayout == .window ? .portraitWindow : .regular)
                .padding(previewLayout == .window ? 8 : 10)
                .dynamicTypeSize(.xSmall ... .large)
                .background(
                    .black.opacity(previewLayout == .window ? 0.94 : 0.76),
                    in: RoundedRectangle(cornerRadius: 16)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(.white.opacity(0.15))
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
        .frame(width: size.width, height: size.height)
    }

    private var closeButton: some View {
        Button {
            camera.stop()
            dismiss()
        } label: {
            Image(systemName: "xmark")
        }
        .buttonStyle(CaptureTopButtonStyle())
        .accessibilityLabel("Close capture")
    }

    private func closeButtonPosition(in size: CGSize, previewFrame: CGRect) -> CGPoint {
        guard previewLayout == .window else {
            return CGPoint(x: 28, y: 28)
        }
        return CGPoint(
            x: min(size.width - 28, previewFrame.minX + 28),
            y: min(size.height - 28, previewFrame.minY + 28)
        )
    }

    private var authorizationMessage: some View {
        VStack(spacing: 12) {
            Image(systemName: "video.slash")
                .font(.largeTitle)
            Text("Camera access is needed to capture. Enable it in Settings.")
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            #if os(macOS)
            Button {
                openCameraPrivacySettings()
            } label: {
                Label("Open Camera Settings", systemImage: "gear")
            }
            .buttonStyle(CaptureActionButtonStyle(tint: .blue, minHeight: 34))

            Button {
                camera.start()
            } label: {
                Label("Try Again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(CaptureActionButtonStyle(tint: .gray, minHeight: 34))
            #endif
        }
        .foregroundStyle(.white)
        .padding(24)
        .background(.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 16))
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    private func controls(density: CaptureControlDensity) -> some View {
        VStack(spacing: density.spacing) {
            CaptureSegmentedControl(
                options: PreviewLayout.allCases,
                selection: $previewLayout,
                density: density
            ) { layout in
                layout.rawValue
            }

            CaptureSegmentedControl(
                options: Mode.allCases,
                selection: $mode,
                isDisabled: camera.isRecording || camera.isIntervalRunning,
                density: density
            ) { mode in
                mode.rawValue
            }

            if camera.availableLenses.count > 1 {
                CaptureSegmentedControl(
                    options: camera.availableLenses,
                    selection: $camera.selectedLens,
                    isDisabled: camera.isRecording || camera.isIntervalRunning,
                    density: density
                ) { lens in
                    lens.label
                }
                .onChange(of: camera.selectedLens) { lens in
                    camera.selectLens(lens)
                }
            }

            if mode == .video {
                CaptureSegmentedControl(
                    options: LiveCaptureSequence.Mode.allCases,
                    selection: $sequenceMode,
                    isDisabled: camera.isRecording || camera.isIntervalRunning,
                    density: density
                ) { mode in
                    mode.label
                }

                stabilizationControl(density: density)
            }

            if !camera.availableResolutions.isEmpty {
                HStack(spacing: density.spacing) {
                    compactFormatMenu(
                        title: "Resolution",
                        selection: $camera.selectedResolution,
                        options: camera.availableResolutions,
                        density: density
                    ) { resolution in
                        resolution.label
                    }
                    .onChange(of: camera.selectedResolution) { resolution in
                        camera.selectResolution(resolution)
                    }

                    compactFormatMenu(
                        title: sequenceMode == .ramp ? "Base FPS" : "Frame rate",
                        selection: $camera.selectedFrameRate,
                        options: camera.availableFrameRates,
                        density: density
                    ) { fps in
                        "\(fps) fps"
                    }
                    .onChange(of: camera.selectedFrameRate) { fps in
                        camera.selectFrameRate(fps)
                    }

                    if mode == .video && sequenceMode == .ramp && !availableRampFrameRates.isEmpty {
                        compactFormatMenu(
                            title: "Ramp FPS",
                            selection: $camera.selectedRampFrameRate,
                            options: availableRampFrameRates,
                            density: density
                        ) { fps in
                            "\(fps) fps"
                        }
                        .onChange(of: camera.selectedRampFrameRate) { fps in
                            camera.selectRampFrameRate(fps)
                        }
                    }
                }
                .disabled(camera.isRecording || camera.isIntervalRunning)
            }

            switch mode {
            case .video:
                if camera.isRecording {
                    VStack(spacing: 6) {
                        Text(elapsedRecordingTime)
                            .font(density.actionFont.monospacedDigit())
                            .foregroundStyle(.white)
                        Text(sequenceStatusLine)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.78))
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 12)
                    .background(.red.opacity(0.28), in: Capsule())
                }

                if camera.isRecording {
                    HStack(spacing: 12) {
                        Button {
                            camera.triggerLiveMoment()
                        } label: {
                            Label(sequenceTriggerTitle, systemImage: sequenceTriggerIcon)
                                .font(density.actionFont)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(camera.isRampActive ? .orange : .blue)
                        .controlSize(.small)

                        Button {
                            camera.stopRecording()
                        } label: {
                            Label("Stop", systemImage: "stop.circle.fill")
                                .font(density.actionFont)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .controlSize(.small)
                    }
                } else {
                    Button {
                        camera.startRecording(mode: sequenceMode)
                    } label: {
                        Label("Record", systemImage: "record.circle")
                            .font(density.actionFont)
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(CaptureActionButtonStyle(tint: .red, minHeight: density.actionHeight))
                    .disabled(camera.isAuthorized != true)
                }
            case .interval:
                if !camera.isIntervalRunning {
                    HStack {
                        Text("Every \(interval, specifier: "%.1f")s")
                            .font(density.pickerFont)
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
                    .font(density.actionFont)
                    .foregroundStyle(camera.isIntervalRunning ? .red : .white)
                }
                .buttonStyle(CaptureActionButtonStyle(
                    tint: camera.isIntervalRunning ? .red : .blue,
                    minHeight: density.actionHeight
                ))
                .disabled(camera.isAuthorized != true)
            }
        }
    }

    private func compactFormatMenu<Option: Hashable>(
        title: String,
        selection: Binding<Option>,
        options: [Option],
        density: CaptureControlDensity,
        label: @escaping (Option) -> String
    ) -> some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button {
                    selection.wrappedValue = option
                } label: {
                    if option == selection.wrappedValue {
                        Label(label(option), systemImage: "checkmark")
                    } else {
                        Text(label(option))
                    }
                }
            }
        } label: {
            VStack(spacing: 1) {
                Text(title.uppercased())
                    .font(.system(size: density.menuTitleSize, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))

                HStack(spacing: 3) {
                    Text(label(selection.wrappedValue))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: density.menuChevronSize, weight: .semibold))
                }
                .font(density.pickerFont)
                .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity, minHeight: density.menuHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    #if os(iOS)
    private func handleWatchCommand(_ command: WatchCaptureCommand) {
        switch command {
        case .startRecording:
            guard !camera.isRecording, !camera.isIntervalRunning else { return }
            mode = .video
            camera.startRecording(mode: sequenceMode)
        case .stopRecording:
            camera.stopRecording()
        case .triggerMoment:
            camera.triggerLiveMoment()
        case .state:
            updateWatchRecordingState()
        }
    }

    private func updateWatchRecordingState() {
        watchRemote.setRecordingState(
            camera.isRecording ? .recording : .idle,
            startedAt: camera.recordingStartedAt,
            sequenceMode: camera.activeSequenceMode ?? sequenceMode,
            markerCount: camera.markerCount,
            rampIntervalCount: camera.rampIntervalCount,
            segmentCount: camera.segmentCount,
            isRampActive: camera.isRampActive,
            isRampHighRate: camera.isRampHighRate
        )
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = camera.isRecording || camera.isIntervalRunning
    }
    #endif

    private var elapsedRecordingTime: String {
        guard let startedAt = camera.recordingStartedAt else { return "00:00" }
        return DurationFormatter.recordingTime(from: max(0, now.timeIntervalSince(startedAt)))
    }

    private var sequenceTriggerTitle: String {
        camera.isRampActive ? "Ramp Off" : "Ramp On"
    }

    private var sequenceTriggerIcon: String {
        camera.isRampActive ? "speedometer" : "speedometer"
    }

    private var sequenceStatusLine: String {
        switch camera.activeSequenceMode ?? sequenceMode {
        case .ramp:
            let rampState = camera.isRampActive ? "ramp on" : "ramp off"
            return "\(camera.rampIntervalCount) ramp intervals · \(camera.segmentCount) segments · \(rampState)"
        case .marker:
            let rampState = camera.isRampActive ? "ramp on" : "ramp off"
            return "\(camera.rampIntervalCount) ramp intervals · \(rampState)"
        }
    }

    private var availableRampFrameRates: [Int] {
        camera.availableFrameRates.filter { $0 > camera.selectedFrameRate }
    }

    private var stabilizationBinding: Binding<Bool> {
        Binding {
            camera.isVideoStabilizationEnabled
        } set: { isEnabled in
            camera.setVideoStabilizationEnabled(isEnabled)
        }
    }

    private func stabilizationControl(density: CaptureControlDensity) -> some View {
        HStack(spacing: density.spacing) {
            Label("Stabilization", systemImage: "hand.raised")
                .font(density.labelFont)
                .foregroundStyle(.white)

            Spacer(minLength: 4)

            Toggle("Stabilization", isOn: stabilizationBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(.green)
                .controlSize(.mini)
                .scaleEffect(0.78, anchor: .trailing)
        }
        .disabled(camera.isRecording || camera.isIntervalRunning)
    }

    #if os(macOS)
    private func openCameraPrivacySettings() {
        CameraPrivacySettings.open()
    }
    #endif
}

private enum CaptureControlDensity {
    case regular
    case portraitWindow
    case landscape

    var spacing: CGFloat {
        switch self {
        case .regular: return 6
        case .portraitWindow: return 5
        case .landscape: return 4
        }
    }

    var segmentHeight: CGFloat {
        switch self {
        case .regular: return 28
        case .portraitWindow: return 24
        case .landscape: return 22
        }
    }

    var actionHeight: CGFloat {
        switch self {
        case .regular: return 40
        case .portraitWindow: return 36
        case .landscape: return 34
        }
    }

    var labelFont: Font {
        switch self {
        case .regular: return .caption
        case .portraitWindow, .landscape: return .caption2
        }
    }

    var pickerFont: Font {
        switch self {
        case .regular: return .caption
        case .portraitWindow, .landscape: return .caption2
        }
    }

    var actionFont: Font {
        switch self {
        case .regular: return .subheadline.weight(.semibold)
        case .portraitWindow, .landscape: return .caption.weight(.semibold)
        }
    }

    var segmentPadding: CGFloat {
        switch self {
        case .regular: return 3
        case .portraitWindow, .landscape: return 2
        }
    }

    var menuHeight: CGFloat {
        switch self {
        case .regular: return 30
        case .portraitWindow: return 28
        case .landscape: return 26
        }
    }

    var menuTitleSize: CGFloat {
        switch self {
        case .regular: return 8
        case .portraitWindow, .landscape: return 7
        }
    }

    var menuChevronSize: CGFloat {
        switch self {
        case .regular: return 8
        case .portraitWindow, .landscape: return 7
        }
    }

}

private struct CaptureTopButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(
                configuration.isPressed ? .black.opacity(0.82) : .black.opacity(0.62),
                in: Circle()
            )
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }
}

private struct CaptureActionButtonStyle: ButtonStyle {
    var tint: Color
    var minHeight: CGFloat = 44

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .foregroundStyle(.white)
            .frame(minWidth: 92, maxWidth: .infinity, minHeight: minHeight)
            .padding(.horizontal, 10)
            .background(
                tint.opacity(configuration.isPressed ? 0.66 : 0.92),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .opacity(configuration.isPressed ? 0.88 : 1)
    }
}

private struct CaptureSegmentedControl<Option: Identifiable & Equatable>: View where Option.ID: Hashable {
    let options: [Option]
    @Binding var selection: Option
    var isDisabled = false
    var density: CaptureControlDensity = .regular
    var title: (Option) -> String

    var body: some View {
        HStack(spacing: density.segmentPadding) {
            ForEach(options) { option in
                let isSelected = option == selection
                Button {
                    selection = option
                } label: {
                    Text(title(option))
                        .font(density.labelFont.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.68)
                        .foregroundStyle(isSelected ? .black : .white.opacity(0.88))
                        .frame(maxWidth: .infinity, minHeight: density.segmentHeight)
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .background(
                    isSelected ? .white : .white.opacity(0.11),
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSelected ? .white.opacity(0.72) : .white.opacity(0.08))
                }
            }
        }
        .padding(density.segmentPadding)
        .opacity(isDisabled ? 0.55 : 1)
        .allowsHitTesting(!isDisabled)
    }
}

#if os(iOS)
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let orientation: AVCaptureVideoOrientation
    let videoGravity: AVLayerVideoGravity

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
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
        if uiView.previewLayer.videoGravity != videoGravity {
            uiView.previewLayer.videoGravity = videoGravity
        }
        if let connection = uiView.previewLayer.connection,
           connection.isVideoOrientationSupported,
           connection.videoOrientation != orientation {
            connection.videoOrientation = orientation
        }
    }
}
#else
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    let orientation: AVCaptureVideoOrientation
    let videoGravity: AVLayerVideoGravity

    final class PreviewView: NSView {
        override func makeBackingLayer() -> CALayer {
            AVCaptureVideoPreviewLayer()
        }

        var previewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }

        override func layout() {
            super.layout()
            previewLayer.frame = bounds
        }
    }

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.wantsLayer = true
        view.previewLayer.session = session
        view.previewLayer.videoGravity = videoGravity
        if view.previewLayer.connection?.isVideoOrientationSupported == true {
            view.previewLayer.connection?.videoOrientation = orientation
        }
        return view
    }

    func updateNSView(_ nsView: PreviewView, context: Context) {
        nsView.previewLayer.frame = nsView.bounds
        nsView.previewLayer.videoGravity = videoGravity
        if nsView.previewLayer.connection?.isVideoOrientationSupported == true {
            nsView.previewLayer.connection?.videoOrientation = orientation
        }
    }
}
#endif
