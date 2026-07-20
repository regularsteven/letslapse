import SwiftUI
import AVFoundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// The redesigned camera. One rule: the viewfinder is never covered.
/// Portrait puts controls in the letterbox zones; landscape uses side rails.
struct CaptureView: View {
    var intent: CaptureIntent = CaptureIntent()

    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
    @ObservedObject private var watchRemote = WatchRemoteControlReceiver.shared
    #endif
    @StateObject private var camera = CameraController()

    @State private var mode: CaptureMode
    @State private var sequenceMode: LiveCaptureSequence.Mode
    @State private var interval: Double = 2
    @State private var orientation = currentCaptureOrientation()
    @State private var now = Date()
    @State private var framingStartedAt = Date()
    @State private var showFormatSheet = false
    @State private var showTargetSheet = false
    @State private var showGrid = false
    @State private var activeTarget: CaptureTargetPlan?
    @State private var targetReached = false
    private let tick = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    init(intent: CaptureIntent = CaptureIntent()) {
        self.intent = intent
        _mode = State(initialValue: intent.mode)
        _sequenceMode = State(initialValue: intent.sequenceMode)
    }

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width > geometry.size.height {
                landscapeLayout(in: geometry.size)
            } else {
                portraitLayout(in: geometry.size)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        #if os(iOS)
        .statusBarHidden()
        #endif
        .sheet(isPresented: $showFormatSheet) {
            FormatSheet(
                camera: camera,
                mode: $mode,
                sequenceMode: $sequenceMode
            )
        }
        .sheet(isPresented: $showTargetSheet) {
            CaptureTargetSheet(
                captureFPS: camera.selectedFrameRate,
                outputFPS: model.outputFPS
            ) { plan in
                startTargetCapture(plan)
            }
        }
        .onAppear(perform: configureOnAppear)
        .onDisappear(perform: cleanUpOnDisappear)
        .onReceive(tick) { date in
            now = date
            checkTarget()
        }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            orientation = currentCaptureOrientation()
            camera.setVideoOrientation(orientation)
        }
        .onChange(of: camera.isRecording) { isRecording in
            if !isRecording {
                framingStartedAt = Date()
                activeTarget = nil
                targetReached = false
            }
            updateWatchRecordingState()
            updateIdleTimer()
        }
        .onChange(of: camera.recordingStartedAt) { _ in
            now = Date()
            updateWatchRecordingState()
        }
        .onChange(of: camera.activeSequenceMode) { _ in updateWatchRecordingState() }
        .onChange(of: camera.markerCount) { _ in updateWatchRecordingState() }
        .onChange(of: camera.rampIntervalCount) { _ in updateWatchRecordingState() }
        .onChange(of: camera.segmentCount) { _ in updateWatchRecordingState() }
        .onChange(of: camera.isRampActive) { _ in updateWatchRecordingState() }
        .onChange(of: camera.isRampHighRate) { _ in updateWatchRecordingState() }
        .onChange(of: camera.isIntervalRunning) { _ in updateIdleTimer() }
        .onChange(of: camera.selectedResolution) { _ in updateWatchContext() }
        .onChange(of: camera.selectedFrameRate) { _ in updateWatchContext() }
        .onChange(of: model.constantWindow) { _ in updateWatchContext() }
        .onChange(of: camera.isExposureLocked) { _ in updateWatchExposure() }
        .onChange(of: camera.lockedISO) { _ in updateWatchExposure() }
        .onChange(of: camera.lockedLensPosition) { _ in updateWatchExposure() }
        #else
        .onChange(of: camera.isRecording) { isRecording in
            if !isRecording {
                framingStartedAt = Date()
                activeTarget = nil
                targetReached = false
            }
        }
        #endif
    }

    // MARK: - Lifecycle

    private func configureOnAppear() {
        #if os(iOS)
        watchRemote.activate()
        watchRemote.setCommandHandler(handleWatchCommand)
        updateWatchRecordingState()
        updateWatchContext()
        updateWatchExposure()
        updateIdleTimer()
        #endif
        camera.onFinishLiveCapture = { result in
            camera.stop()
            dismiss()
            model.setSequenceSource(result)
        }
        camera.onFinishVideo = { url in
            camera.stop()
            dismiss()
            model.setSource(.video(url), mode: camera.activeFormatDescription)
        }
        camera.onFinishPhotos = { urls in
            camera.stop()
            dismiss()
            model.setSource(.photos(urls), mode: "Interval photos")
        }
        orientation = currentCaptureOrientation()
        #if os(iOS)
        camera.setVideoOrientation(orientation)
        #endif
        camera.start()
        framingStartedAt = Date()
    }

    private func cleanUpOnDisappear() {
        #if os(iOS)
        watchRemote.setCommandHandler(nil)
        UIApplication.shared.isIdleTimerDisabled = false
        #endif
    }

    // MARK: - Portrait

    private func portraitLayout(in size: CGSize) -> some View {
        VStack(spacing: 0) {
            portraitTopBar
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 8)

            viewfinder
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            portraitControls
                .padding(.top, 10)
                .padding(.bottom, 12)
        }
        .overlay {
            if camera.isAuthorized == false {
                authorizationMessage
            }
        }
    }

    private var portraitTopBar: some View {
        HStack {
            if camera.isRecording {
                recordingPill
            } else {
                CameraChromeButton(systemImage: "xmark") {
                    closeCapture()
                }
                .accessibilityLabel("Close capture")
            }

            Spacer()

            formatPill
        }
    }

    private var portraitControls: some View {
        VStack(spacing: 13) {
            if mode == .video {
                if camera.isRecording {
                    speedMarquee
                    segmentStrip
                        .padding(.horizontal, 16)
                } else {
                    speedChipsRow
                }
            } else {
                intervalStatusRow
            }

            if !camera.isRecording && !camera.isIntervalRunning {
                modeRow
            }

            #if os(iOS)
            exposurePanel
            #endif

            HStack {
                leadingControl
                    .frame(width: 64)
                Spacer()
                shutterButton
                Spacer()
                trailingControl
                    .frame(width: 64)
            }
            .padding(.horizontal, 36)
        }
    }

    // MARK: - Landscape (side rails: thumbs on edges, image untouched)

    private func landscapeLayout(in size: CGSize) -> some View {
        HStack(spacing: 0) {
            // Left rail: status + format
            VStack {
                if camera.isRecording {
                    recordingPill
                } else {
                    CameraChromeButton(systemImage: "xmark") {
                        closeCapture()
                    }
                }
                Spacer()
                VStack(spacing: 8) {
                    formatPill
                    #if os(iOS)
                    if mode == .video {
                        landscapeExposureControl
                    }
                    #endif
                }
                Spacer()
                if camera.isIntervalRunning {
                    CameraPill(text: "\(camera.photoCount) photos", tint: LL.amber)
                } else if mode == .video, !camera.isRecording {
                    zoomChips
                }
            }
            .padding(.vertical, 16)
            .frame(width: 108)

            // Viewfinder with the estimate chips in the safe corner
            viewfinder
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottomLeading) {
                    if mode == .video {
                        landscapeEstimateChips
                            .padding(10)
                    }
                }

            // Right rail: mode + shutter
            VStack {
                Button {
                    guard !camera.isRecording, !camera.isIntervalRunning else { return }
                    mode = mode == .video ? .interval : .video
                } label: {
                    verticalModeLabel
                }
                .buttonStyle(.plain)

                Spacer()
                shutterButton
                Spacer()

                if camera.isRecording {
                    leadingControl
                } else {
                    projectThumbnailButton
                }
            }
            .padding(.vertical, 16)
            .frame(width: 118)
        }
        .overlay {
            if camera.isAuthorized == false {
                authorizationMessage
            }
        }
    }

    private var verticalModeLabel: some View {
        HStack(spacing: 4) {
            Text("INTERVAL")
                .foregroundStyle(mode == .interval ? LL.amber : .white.opacity(0.5))
            Text("·")
                .foregroundStyle(.white.opacity(0.4))
            Text("VIDEO")
                .foregroundStyle(mode == .video ? LL.amber : .white.opacity(0.5))
        }
        .font(.system(size: 11, weight: .bold))
        .kerning(0.6)
        .fixedSize()
        .rotationEffect(.degrees(90))
        .frame(width: 24, height: 130)
    }

    private var landscapeEstimateChips: some View {
        HStack(spacing: 6) {
            if let neighbor = neighborSpeeds.first {
                CameraPill(
                    text: "\(neighbor)× → \(estimateText(for: neighbor))",
                    tint: .white.opacity(0.7),
                    monospaced: true
                )
            }
            CameraPill(
                text: "\(model.constantWindow)× → \(estimateText(for: model.constantWindow))",
                tint: LL.amber,
                bold: true,
                monospaced: true
            )
        }
    }

    // MARK: - Viewfinder

    private var viewfinder: some View {
        GeometryReader { geometry in
            let fitted = aspectFitSize(
                aspectRatio: previewAspectRatio,
                maxWidth: geometry.size.width,
                maxHeight: geometry.size.height
            )
            ZStack {
                CameraPreview(
                    session: camera.session,
                    orientation: orientation,
                    videoGravity: .resizeAspect
                )
                if showGrid {
                    RuleOfThirdsGrid()
                        .frame(width: fitted.width, height: fitted.height)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
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

    private func aspectFitSize(aspectRatio: CGFloat, maxWidth: CGFloat, maxHeight: CGFloat) -> CGSize {
        let widthFromHeight = maxHeight * aspectRatio
        if widthFromHeight <= maxWidth {
            return CGSize(width: widthFromHeight, height: maxHeight)
        }
        return CGSize(width: maxWidth, height: maxWidth / max(aspectRatio, 0.01))
    }

    // MARK: - Pills & chrome

    private var recordingPill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
            Text(elapsedRecordingTime)
                .font(.system(size: 14, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.16), in: Capsule())
        .overlay(Capsule().stroke(Color.red.opacity(0.5), lineWidth: 1))
    }

    private var formatPill: some View {
        Button {
            guard !camera.isRecording else { return }
            showFormatSheet = true
        } label: {
            HStack(spacing: 4) {
                Text(formatSummary)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(camera.isRecording ? .white.opacity(0.55) : .white)
                if camera.isVideoStabilizationEnabled && mode == .video {
                    Text("· Stab")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(camera.isRecording ? LL.amber.opacity(0.6) : LL.amber)
                }
                Image(systemName: camera.isRecording ? "lock.fill" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color(red: 0.17, green: 0.17, blue: 0.18).opacity(0.9), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Capture format")
    }

    private var formatSummary: String {
        "\(camera.selectedResolution.label) · \(camera.selectedFrameRate)"
    }

    // MARK: - Speed chips (idle)

    private var speedChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Text("SPEED")
                    .font(.system(size: 10, weight: .bold))
                    .kerning(0.8)
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.trailing, 2)

                ForEach(SpeedMath.presets, id: \.self) { preset in
                    let isSelected = model.constantWindow == preset && !model.useRamp
                    Button {
                        model.useRamp = false
                        model.constantWindow = preset
                    } label: {
                        Group {
                            if isSelected {
                                Text("\(preset)× → \(estimateText(for: preset))")
                                    .foregroundColor(.black)
                                    .fontWeight(.bold)
                            } else {
                                Text("\(preset)× ")
                                    .foregroundColor(.white)
                                    + Text("→ \(estimateText(for: preset))")
                                    .foregroundColor(.white.opacity(0.45))
                            }
                        }
                        .font(.system(size: 12.5))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            isSelected ? LL.amber : Color(red: 0.17, green: 0.17, blue: 0.18).opacity(0.9),
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    showTargetSheet = true
                } label: {
                    Text("Target…")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color(red: 0.17, green: 0.17, blue: 0.18).opacity(0.9), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
        }
    }

    /// Live "what would this be" per speed. While recording it tracks the
    /// elapsed take; while framing it tracks how long you've been framing.
    private func estimateText(for speed: Int) -> String {
        let reference: TimeInterval
        if camera.isRecording, let startedAt = camera.recordingStartedAt {
            reference = now.timeIntervalSince(startedAt)
        } else {
            reference = now.timeIntervalSince(framingStartedAt)
        }
        let seconds = SpeedMath.outputSeconds(
            recordSeconds: max(1, reference),
            captureFPS: Double(camera.selectedFrameRate),
            speed: speed,
            outputFPS: model.outputFPS
        )
        return SpeedMath.clipLengthCompact(seconds)
    }

    // MARK: - Recording marquee + strip

    private var neighborSpeeds: [Int] {
        let current = model.constantWindow
        return [current / 2, current * 2]
            .filter { SpeedMath.range.contains($0) && $0 != current }
    }

    private var speedMarquee: some View {
        HStack(spacing: 14) {
            if let target = activeTarget {
                Text("\(elapsedRecordingTime) / \(DurationFormatter.recordingTime(from: target.recordSeconds))")
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(targetReached ? Color.green : LL.amber)
                Text("target \(SpeedMath.clipLengthCompact(target.clipSeconds)) @ \(target.speed)×")
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
            } else {
                if let lower = neighborSpeeds.first(where: { $0 < model.constantWindow }) {
                    marqueeEntry(speed: lower, emphasized: false)
                }
                marqueeEntry(speed: model.constantWindow, emphasized: true)
                if let higher = neighborSpeeds.first(where: { $0 > model.constantWindow }) {
                    marqueeEntry(speed: higher, emphasized: false)
                }
            }
        }
    }

    private func marqueeEntry(speed: Int, emphasized: Bool) -> some View {
        Text("\(speed)× → \(estimateText(for: speed))")
            .font(.system(size: 12.5, weight: emphasized ? .bold : .regular, design: .monospaced))
            .foregroundStyle(emphasized ? LL.amber : .white.opacity(0.45))
    }

    private var segmentStrip: some View {
        VStack(spacing: 5) {
            GeometryReader { geometry in
                let elapsed = max(1, elapsedSeconds)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color(red: 0.23, green: 0.23, blue: 0.24))
                    ForEach(camera.rampSpans) { span in
                        let start = min(span.start, elapsed)
                        let end = min(span.end ?? elapsed, elapsed)
                        let width = max(0, (end - start) / elapsed) * geometry.size.width
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(LL.amber)
                            .frame(width: max(width, 3))
                            .offset(x: (start / elapsed) * geometry.size.width)
                    }
                }
            }
            .frame(height: 14)

            HStack {
                Text("\(baseFrameRateLabel) fps base")
                Spacer()
                Text(stripCaption)
                    .foregroundStyle(LL.amber)
            }
            .font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.45))
        }
    }

    private var elapsedSeconds: TimeInterval {
        guard let startedAt = camera.recordingStartedAt else { return 0 }
        return max(0, now.timeIntervalSince(startedAt))
    }

    private var baseFrameRateLabel: String {
        "\(camera.selectedFrameRate)"
    }

    private var stripCaption: String {
        let count = camera.rampIntervalCount
        switch camera.activeSequenceMode ?? sequenceMode {
        case .ramp:
            let state = camera.isRampHighRate ? "burst live" : "bursts"
            return "▲ \(camera.selectedRampFrameRate) fps \(state) · \(count)"
        case .marker:
            return "⚑ \(count) marked interval\(count == 1 ? "" : "s")"
        }
    }

    // MARK: - Interval rows

    @ViewBuilder
    private var intervalStatusRow: some View {
        if camera.isIntervalRunning {
            HStack(spacing: 12) {
                CameraPill(text: "\(camera.photoCount) photos", tint: LL.amber, bold: true, monospaced: true)
                CameraPill(text: elapsedIntervalText, tint: .white.opacity(0.7), monospaced: true)
            }
        } else {
            HStack(spacing: 8) {
                Text("EVERY")
                    .font(.system(size: 10, weight: .bold))
                    .kerning(0.8)
                    .foregroundStyle(.white.opacity(0.45))
                Menu {
                    ForEach([0.5, 1.0, 2.0, 3.0, 5.0, 10.0], id: \.self) { seconds in
                        Button {
                            interval = seconds
                        } label: {
                            if interval == seconds {
                                Label(intervalLabel(seconds), systemImage: "checkmark")
                            } else {
                                Text(intervalLabel(seconds))
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(intervalLabel(interval))
                            .font(.system(size: 12.5, weight: .semibold))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color(red: 0.17, green: 0.17, blue: 0.18).opacity(0.9), in: Capsule())
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Text("stacks into one long exposure")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    private func intervalLabel(_ seconds: Double) -> String {
        seconds == floor(seconds) ? "\(Int(seconds)) s" : String(format: "%.1f s", seconds)
    }

    private var elapsedIntervalText: String {
        DurationFormatter.recordingTime(from: now.timeIntervalSince(framingStartedAt))
    }

    // MARK: - Mode + zoom row

    private var modeRow: some View {
        HStack(spacing: 22) {
            Button {
                mode = .interval
            } label: {
                Text("INTERVAL")
                    .foregroundStyle(mode == .interval ? LL.amber : .white.opacity(0.5))
            }
            .buttonStyle(.plain)

            Button {
                mode = .video
            } label: {
                Text("VIDEO")
                    .foregroundStyle(mode == .video ? LL.amber : .white.opacity(0.5))
            }
            .buttonStyle(.plain)

            if camera.availableLenses.count > 1 {
                zoomChips
            }
        }
        .font(.system(size: 13, weight: .semibold))
    }

    private var zoomChips: some View {
        HStack(spacing: 8) {
            ForEach(camera.availableLenses) { lens in
                let isSelected = camera.selectedLens == lens
                Button {
                    camera.selectedLens = lens
                    camera.selectLens(lens)
                } label: {
                    Text(lens.zoomLabel)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isSelected ? LL.amber : .white.opacity(0.6))
                        .frame(minWidth: 30, minHeight: 30)
                        .background(
                            Circle().stroke(
                                isSelected ? LL.amber.opacity(0.8) : .white.opacity(0.25),
                                lineWidth: 1
                            )
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Shutter row

    private var shutterButton: some View {
        Button(action: shutterAction) {
            ZStack {
                Circle()
                    .stroke(.white, lineWidth: 4)
                    .frame(width: 76, height: 76)

                if let target = activeTarget, camera.isRecording {
                    Circle()
                        .trim(from: 0, to: min(1, elapsedSeconds / max(1, target.recordSeconds)))
                        .stroke(targetReached ? Color.green : LL.amber, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 76, height: 76)
                }

                if isCapturing {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.red)
                        .frame(width: 32, height: 32)
                } else {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 60, height: 60)
                }
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(camera.isAuthorized != true)
        .accessibilityLabel(isCapturing ? "Stop" : "Record")
    }

    private var isCapturing: Bool {
        camera.isRecording || camera.isIntervalRunning
    }

    private func shutterAction() {
        switch mode {
        case .video:
            if camera.isRecording {
                camera.stopRecording()
            } else {
                framingStartedAt = Date()
                camera.startRecording(mode: sequenceMode)
            }
        case .interval:
            if camera.isIntervalRunning {
                camera.stopInterval()
            } else {
                framingStartedAt = Date()
                camera.startInterval(every: interval)
            }
        }
    }

    /// Left of the shutter: the burst/marker trigger while recording,
    /// the latest project's thumbnail otherwise.
    @ViewBuilder
    private var leadingControl: some View {
        if camera.isRecording {
            Button {
                camera.triggerLiveMoment()
            } label: {
                Group {
                    switch camera.activeSequenceMode ?? sequenceMode {
                    case .ramp:
                        Text("\(camera.selectedRampFrameRate)")
                            .font(.system(size: 12, weight: .bold))
                    case .marker:
                        Image(systemName: "flag.fill")
                            .font(.system(size: 15, weight: .semibold))
                    }
                }
                .foregroundStyle(camera.isRampActive ? .black : LL.amber)
                .frame(width: 44, height: 44)
                .background(
                    camera.isRampActive ? LL.amber : Color(red: 0.17, green: 0.17, blue: 0.18).opacity(0.9),
                    in: Circle()
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel((camera.activeSequenceMode ?? sequenceMode) == .ramp ? "Toggle speed burst" : "Toggle marker")
        } else {
            projectThumbnailButton
        }
    }

    private var projectThumbnailButton: some View {
        Group {
            if let latest = model.captures.first {
                Button {
                    camera.stop()
                    dismiss()
                    model.requestedProjectDetailID = latest.id
                } label: {
                    ProjectThumbnailView(url: model.mediaURL(for: latest), kind: model.mediaKind(for: latest))
                        .frame(width: 44, height: 44)
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(.white.opacity(0.25), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open latest project")
            } else {
                Color.clear.frame(width: 44, height: 44)
            }
        }
    }

    /// Right of the shutter: grid toggle idle, interval/marker count while busy.
    @ViewBuilder
    private var trailingControl: some View {
        if camera.isRecording {
            let count = camera.rampIntervalCount
            Text("\(count)")
                .font(.system(size: 14, weight: .bold).monospacedDigit())
                .foregroundStyle(count > 0 ? LL.amber : .white.opacity(0.4))
                .frame(width: 44, height: 44)
                .background(Color(red: 0.17, green: 0.17, blue: 0.18).opacity(0.9), in: Circle())
        } else {
            Button {
                showGrid.toggle()
            } label: {
                Image(systemName: showGrid ? "grid.circle.fill" : "grid.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(showGrid ? LL.amber : .white)
                    .frame(width: 44, height: 44)
                    .background(Color(red: 0.17, green: 0.17, blue: 0.18).opacity(0.9), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Toggle grid")
        }
    }

    // MARK: - Target capture

    private func startTargetCapture(_ plan: CaptureTargetPlan) {
        model.useRamp = false
        model.constantWindow = plan.speed
        activeTarget = plan
        targetReached = false
        mode = .video
        framingStartedAt = Date()
        if !camera.isRecording {
            camera.startRecording(mode: sequenceMode)
        }
    }

    private func checkTarget() {
        guard camera.isRecording,
              let target = activeTarget,
              !targetReached,
              elapsedSeconds >= target.recordSeconds else { return }
        targetReached = true
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
        if target.autoStop {
            camera.stopRecording()
        }
    }

    // MARK: - Shared bits

    private func closeCapture() {
        camera.stop()
        dismiss()
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
                CameraPrivacySettings.open()
            } label: {
                Label("Open Camera Settings", systemImage: "gear")
            }
            Button {
                camera.start()
            } label: {
                Label("Try Again", systemImage: "arrow.clockwise")
            }
            #endif
        }
        .foregroundStyle(.white)
        .padding(24)
        .background(.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var elapsedRecordingTime: String {
        guard let startedAt = camera.recordingStartedAt else { return "00:00" }
        return DurationFormatter.recordingTime(from: max(0, now.timeIntervalSince(startedAt)))
    }

    // MARK: - Manual exposure (iOS only)

    #if os(iOS)
    /// Portrait letterbox control: a tap-to-lock AE/AF pill, and — once locked —
    /// ISO and focus sliders. The viewfinder stays uncovered above.
    @ViewBuilder
    private var exposurePanel: some View {
        if mode == .video {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    exposureLockButton
                    if camera.isExposureLocked {
                        Text(exposureReadout)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(LL.amber)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    Spacer()
                }

                if camera.isExposureLocked {
                    if isoSliderRange.lowerBound < isoSliderRange.upperBound {
                        exposureSlider(icon: "sun.max.fill", value: isoBinding, range: isoSliderRange)
                    }
                    exposureSlider(icon: "camera.macro", value: focusBinding, range: 0...1)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var exposureLockButton: some View {
        Button {
            toggleExposureLock()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: camera.isExposureLocked ? "lock.fill" : "lock.open")
                    .font(.system(size: 12, weight: .semibold))
                Text(camera.isExposureLocked ? "AE/AF Lock" : "Lock AE/AF")
                    .font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(camera.isExposureLocked ? .black : .white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                camera.isExposureLocked ? LL.amber : Color(red: 0.17, green: 0.17, blue: 0.18).opacity(0.9),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(camera.isExposureLocked ? "Unlock exposure and focus" : "Lock exposure and focus")
    }

    /// Compact landscape-rail variant: lock toggle plus the frozen readout.
    /// Fine ISO/focus tuning lives in portrait or on the Watch crown.
    private var landscapeExposureControl: some View {
        VStack(spacing: 6) {
            Button {
                toggleExposureLock()
            } label: {
                Image(systemName: camera.isExposureLocked ? "lock.fill" : "lock.open")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(camera.isExposureLocked ? .black : .white)
                    .frame(width: 40, height: 40)
                    .background(
                        camera.isExposureLocked ? LL.amber : Color(red: 0.17, green: 0.17, blue: 0.18).opacity(0.9),
                        in: Circle()
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(camera.isExposureLocked ? "Unlock exposure and focus" : "Lock exposure and focus")

            if camera.isExposureLocked {
                Text(exposureReadout)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(LL.amber)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: 96)
            }
        }
    }

    private func exposureSlider(
        icon: String,
        value: Binding<Float>,
        range: ClosedRange<Float>
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 22)
            Slider(value: value, in: range)
                .tint(LL.amber)
        }
    }

    private var isoSliderRange: ClosedRange<Float> {
        camera.isoRange
    }

    private var isoBinding: Binding<Float> {
        Binding(get: { camera.lockedISO }, set: { camera.setISO($0) })
    }

    private var focusBinding: Binding<Float> {
        Binding(get: { camera.lockedLensPosition }, set: { camera.setLensPosition($0) })
    }

    private func toggleExposureLock() {
        if camera.isExposureLocked {
            camera.unlockExposureAndFocus()
        } else {
            camera.lockExposureAndFocus()
        }
    }

    private var exposureReadout: String {
        "ISO \(Int(camera.lockedISO.rounded())) · \(shutterText(camera.lockedShutterSeconds))"
    }

    private func shutterText(_ seconds: Double) -> String {
        guard seconds > 0 else { return "—" }
        if seconds >= 1 { return String(format: "%.1fs", seconds) }
        return "1/\(Int((1 / seconds).rounded()))"
    }
    #endif

    // MARK: - Watch

    #if os(iOS)
    private func handleWatchCommand(_ command: WatchCaptureCommand, value: Double?) {
        switch command {
        case .startRecording:
            guard !camera.isRecording, !camera.isIntervalRunning else { return }
            mode = .video
            camera.startRecording(mode: sequenceMode)
        case .stopRecording:
            camera.stopRecording()
        case .triggerMoment:
            camera.triggerLiveMoment()
        case .lockExposure:
            camera.lockExposureAndFocus()
        case .unlockExposure:
            camera.unlockExposureAndFocus()
        case .setISO:
            camera.setISO(Float(value ?? 0))
        case .setLensPosition:
            camera.setLensPosition(Float(value ?? 0.5))
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

    private func updateWatchContext() {
        watchRemote.setCaptureContext(
            formatLine: "\(camera.selectedResolution.label) · \(camera.selectedFrameRate) fps",
            captureFPS: camera.selectedFrameRate,
            plannedSpeed: model.constantWindow,
            outputFPS: model.outputFPS
        )
    }

    private func updateWatchExposure() {
        watchRemote.setExposureContext(
            isExposureLocked: camera.isExposureLocked,
            lockedISO: camera.lockedISO,
            lockedShutter: camera.lockedShutterSeconds,
            lockedLensPosition: camera.lockedLensPosition,
            isoMin: camera.isoRange.lowerBound,
            isoMax: camera.isoRange.upperBound
        )
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = camera.isRecording || camera.isIntervalRunning
    }
    #endif
}

// MARK: - Small camera chrome

private struct CameraChromeButton: View {
    var systemImage: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(Color(red: 0.17, green: 0.17, blue: 0.18).opacity(0.9), in: Circle())
        }
        .buttonStyle(.plain)
    }
}

private struct CameraPill: View {
    var text: String
    var tint: Color = .white
    var bold = false
    var monospaced = false

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: bold ? .bold : .semibold, design: monospaced ? .monospaced : .default))
            .foregroundStyle(tint)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.5), in: Capsule())
    }
}

private struct RuleOfThirdsGrid: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let width = geometry.size.width
                let height = geometry.size.height
                for fraction in [1.0 / 3.0, 2.0 / 3.0] {
                    path.move(to: CGPoint(x: width * fraction, y: 0))
                    path.addLine(to: CGPoint(x: width * fraction, y: height))
                    path.move(to: CGPoint(x: 0, y: height * fraction))
                    path.addLine(to: CGPoint(x: width, y: height * fraction))
                }
            }
            .stroke(.white.opacity(0.22), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }
}

private extension CameraController.Lens {
    var zoomLabel: String {
        switch self {
        #if os(iOS)
        case .ultraWide: return ".5×"
        #endif
        case .wide: return "1×"
        #if os(iOS)
        case .telephoto: return "3×"
        #endif
        }
    }
}

// MARK: - Format sheet

/// Advanced capture format, off the viewfinder entirely: lens, resolution,
/// frame rates, stabilization, and how speed bursts are captured.
private struct FormatSheet: View {
    @ObservedObject var camera: CameraController
    @Binding var mode: CaptureMode
    @Binding var sequenceMode: LiveCaptureSequence.Mode
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if camera.availableLenses.count > 1 {
                    Section("Lens") {
                        Picker("Lens", selection: $camera.selectedLens) {
                            ForEach(camera.availableLenses) { lens in
                                Text(lens.label).tag(lens)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: camera.selectedLens) { lens in
                            camera.selectLens(lens)
                        }
                    }
                }

                Section("Format") {
                    Picker("Resolution", selection: $camera.selectedResolution) {
                        ForEach(camera.availableResolutions) { resolution in
                            Text(resolution.label).tag(resolution)
                        }
                    }
                    .onChange(of: camera.selectedResolution) { resolution in
                        camera.selectResolution(resolution)
                    }

                    Picker(sequenceMode == .ramp ? "Base frame rate" : "Frame rate", selection: $camera.selectedFrameRate) {
                        ForEach(camera.availableFrameRates, id: \.self) { fps in
                            Text("\(fps) fps").tag(fps)
                        }
                    }
                    .onChange(of: camera.selectedFrameRate) { fps in
                        camera.selectFrameRate(fps)
                    }

                    Toggle("Stabilization", isOn: Binding(
                        get: { camera.isVideoStabilizationEnabled },
                        set: { camera.setVideoStabilizationEnabled($0) }
                    ))
                }

                if mode == .video {
                    Section {
                        Picker("Speed bursts", selection: $sequenceMode) {
                            Text("Switch sensor rate").tag(LiveCaptureSequence.Mode.ramp)
                            Text("Mark intervals only").tag(LiveCaptureSequence.Mode.marker)
                        }

                        if sequenceMode == .ramp {
                            Picker("Burst frame rate", selection: $camera.selectedRampFrameRate) {
                                ForEach(rampRates, id: \.self) { fps in
                                    Text("\(fps) fps").tag(fps)
                                }
                            }
                            .onChange(of: camera.selectedRampFrameRate) { fps in
                                camera.selectRampFrameRate(fps)
                            }
                        }
                    } header: {
                        Text("Speed bursts")
                    } footer: {
                        Text(sequenceMode == .ramp
                             ? "While recording, the burst button (and Apple Watch) switches the sensor to the burst rate — those moments stay slow and sharp in the final clip."
                             : "Marked intervals keep their real speed in the final clip; the sensor rate never changes.")
                    }
                }
            }
            .navigationTitle("Capture format")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    }

    private var rampRates: [Int] {
        let higher = camera.availableFrameRates.filter { $0 > camera.selectedFrameRate }
        return higher.isEmpty ? [camera.selectedRampFrameRate] : higher
    }
}

// MARK: - Capture target

struct CaptureTargetPlan: Equatable {
    var clipSeconds: Double
    var speed: Int
    var recordSeconds: Double
    var autoStop: Bool
}

/// "I want a 6 s clip at 100×" — pick the clip, we tell you how long to record.
private struct CaptureTargetSheet: View {
    var captureFPS: Int
    var outputFPS: Int
    var onStart: (CaptureTargetPlan) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var clipSeconds: Double = 6
    @State private var speed = 100
    @State private var autoStop = true

    private let speeds = [25, 50, 100, 200]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Capsule()
                .fill(.white.opacity(0.25))
                .frame(width: 36, height: 4)
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
                .padding(.bottom, 18)

            Text("Capture for a target")
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(.white)
            Text("Pick the clip you want — we'll tell you how long to record.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.top, 2)
                .padding(.bottom, 20)

            HStack {
                Text("Clip length")
                    .foregroundStyle(.white)
                Spacer()
                Text(SpeedMath.clipLength(clipSeconds))
                    .fontWeight(.bold)
                    .foregroundStyle(LL.amber)
            }
            .font(.system(size: 14))
            .padding(.bottom, 6)

            Slider(value: $clipSeconds, in: 1...30, step: 0.5)
                .tint(LL.amber)
                .padding(.bottom, 18)

            Text("Speed")
                .font(.system(size: 14))
                .foregroundStyle(.white)
                .padding(.bottom, 8)

            HStack(spacing: 8) {
                ForEach(speeds, id: \.self) { candidate in
                    let isSelected = speed == candidate
                    Button {
                        speed = candidate
                    } label: {
                        Text("\(candidate)×")
                            .font(.system(size: 13, weight: isSelected ? .bold : .regular))
                            .foregroundStyle(isSelected ? .black : .white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(
                                isSelected ? LL.amber : Color.white.opacity(0.1),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 18)

            HStack(spacing: 14) {
                Image(systemName: "timer")
                    .font(.system(size: 20))
                    .foregroundStyle(LL.amber)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Record for \(DurationFormatter.recordingTime(from: recordSeconds))")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                    Text("\(SpeedMath.clipLength(clipSeconds)) · \(outputFPS) fps output · at \(captureFPS) fps capture · ring shows the countdown")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LL.amber.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(LL.amber.opacity(0.35), lineWidth: 1)
            )
            .padding(.bottom, 14)

            Toggle(isOn: $autoStop) {
                Text("Stop automatically at target")
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
            }
            .tint(LL.amber)
            .padding(.bottom, 16)

            Button {
                dismiss()
                onStart(CaptureTargetPlan(
                    clipSeconds: clipSeconds,
                    speed: speed,
                    recordSeconds: recordSeconds,
                    autoStop: autoStop
                ))
            } label: {
                Text("Start capture")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(LL.amber, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)

            Spacer(minLength: 12)
        }
        .padding(.horizontal, 20)
        .background(Color(red: 0.11, green: 0.11, blue: 0.12))
        .preferredColorScheme(.dark)
        #if os(iOS)
        .presentationDetents([.height(470)])
        #endif
    }

    private var recordSeconds: Double {
        SpeedMath.recordSeconds(
            clipSeconds: clipSeconds,
            speed: speed,
            captureFPS: Double(max(1, captureFPS)),
            outputFPS: outputFPS
        )
    }
}

// MARK: - Preview layer

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
