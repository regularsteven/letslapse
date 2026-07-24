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
    /// Interval mode's blend dial: source frames per output image, 1 = no
    /// blending. Default 10: the capture benchmark showed bracketed RAW
    /// delivers 10 frames in ~0.65s, and dense sampling is what reads as
    /// motion blur — 3-5 spread samples read as ghosts.
    @State private var framesPerBlend = 10
    private let blendFrameOptions: [(frames: Int, label: String)] = [
        (1, "No blending"), (3, "Light"), (5, "Standard"), (10, "High"), (20, "Experimental"),
    ]
    private let captureIntervalOptions: [Double] = [0.5, 1.0, 2.0, 3.0, 5.0, 10.0]
    @State private var orientation = currentCaptureOrientation()
    @State private var now = Date()
    @State private var framingStartedAt = Date()
    @State private var showFormatSheet = false
    @State private var showTargetSheet = false
    @State private var showGrid = false
    @State private var activeTarget: CaptureTargetPlan?
    @State private var targetReached = false
    /// Rolling reference scale for the lens pinch — each threshold crossing
    /// steps one lens and re-anchors here, so a long pinch walks the range.
    @State private var pinchBaseline: CGFloat = 1
    /// On-phone shutter delay: tapping record waits 2 s before starting.
    /// Watch remote starts are deliberately immediate — the wrist is already
    /// hands-off the phone.
    @State private var shutterDelayEnabled = false
    /// Deadline of a pending delayed start; nil when none. Tapping the
    /// shutter while pending cancels instead of stacking starts.
    @State private var delayedStartAt: Date?
    private let tick = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    init(intent: CaptureIntent = CaptureIntent()) {
        self.intent = intent
        // An explicit intent (effect cards) wins; otherwise open in the
        // remembered mode with its remembered dials, so a habitual Interval
        // shooter never re-selects Interval and its spacing every shoot.
        let remembering = RecordingSettingsStore.isEnabled
        let mode = intent.mode
            ?? (remembering ? RecordingSettingsStore.captureMode : nil)
            ?? .video
        _mode = State(initialValue: mode)
        _sequenceMode = State(initialValue: intent.sequenceMode)
        if remembering {
            if let seconds = RecordingSettingsStore.intervalSeconds(for: mode) {
                _interval = State(initialValue: seconds)
            }
            if let frames = RecordingSettingsStore.framesPerBlend {
                _framesPerBlend = State(initialValue: frames)
            }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // One persistent preview, filling the whole area. It lives
                // outside the portrait/landscape branch and is sized by normal
                // layout (never .position/.frame-to-a-rect), so it is neither
                // recreated on rotation (no delay) nor blanked in landscape.
                // `.resizeAspect` letterboxes it; the chrome sits over the bars.
                CameraPreview(
                    session: camera.session,
                    camera: camera,
                    orientation: orientation,
                    videoGravity: .resizeAspect
                )
                .allowsHitTesting(false)

                Group {
                    if geometry.size.width > geometry.size.height {
                        landscapeLayout(in: geometry.size)
                    } else {
                        portraitLayout(in: geometry.size)
                    }
                }
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
                model: model,
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
            if let deadline = delayedStartAt, date >= deadline {
                delayedStartAt = nil
                shutterAction()
            }
        }
        // Persist the capture setup as it changes, from any entry path
        // (on-screen pickers, Watch commands). On a mode switch, swap in
        // that mode's remembered spacing, or adopt the carried-over one
        // as its first.
        .onChange(of: mode) { newMode in
            RecordingSettingsStore.save(captureMode: newMode)
            updateAspectPreview()
            guard RecordingSettingsStore.isEnabled else { return }
            if let seconds = RecordingSettingsStore.intervalSeconds(for: newMode) {
                interval = seconds
            } else {
                RecordingSettingsStore.save(intervalSeconds: interval, for: newMode)
            }
        }
        // The viewfinder must show what a DNG shoot will capture — the full
        // 4:3 sensor — so arming/disarming DNG re-configures the preview.
        .onChange(of: model.intervalOutputFormat) { _ in updateAspectPreview() }
        .onChange(of: camera.liveBlendDNGSupport) { _ in updateAspectPreview() }
        .onChange(of: interval) { seconds in
            RecordingSettingsStore.save(intervalSeconds: seconds, for: mode)
        }
        .onChange(of: framesPerBlend) { frames in
            RecordingSettingsStore.save(framesPerBlend: frames)
        }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            // Refresh the orientation the grid overlay sizes against, and nudge
            // a re-render so the preview re-reads its window orientation. The
            // preview itself drives the capture connections in `updateUIView`.
            let device = UIDevice.current.orientation.rawValue
            let next = currentCaptureOrientation()
            LLog("orientationNotif device=\(device) computed=\(next.rawValue) (was \(orientation.rawValue))")
            orientation = next
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
        .onChange(of: camera.isIntervalRunning) { _ in
            updateIdleTimer()
            updateWatchRecordingState()
        }
        .onChange(of: camera.isLiveBlendRunning) { _ in
            updateIdleTimer()
            updateWatchRecordingState()
        }
        .onChange(of: mode) { _ in
            updateWatchModeContext()
            updateWatchContext()
        }
        .onChange(of: model.intervalOutputFormat) { _ in updateWatchContext() }
        .onChange(of: camera.liveBlendDNGSupport) { _ in updateWatchContext() }
        .onChange(of: interval) { _ in updateWatchModeContext() }
        .onChange(of: framesPerBlend) { _ in updateWatchModeContext() }
        .onChange(of: camera.photoCount) { _ in updateWatchModeContext() }
        .onChange(of: camera.liveBlendOutputCount) { _ in updateWatchModeContext() }
        .onChange(of: camera.scheduledStop) { _ in updateWatchScheduledStop() }
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
        // Count the mode the screen opened in as last-used: effect cards set
        // it explicitly, and the plain entry resolved to the remembered mode
        // anyway, so re-saving is a no-op there.
        RecordingSettingsStore.save(captureMode: mode)
        #if os(iOS)
        watchRemote.activate()
        watchRemote.setCommandHandler(handleWatchCommand)
        updateWatchRecordingState()
        updateWatchContext()
        updateWatchModeContext()
        updateWatchScheduledStop()
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
            model.setSource(.photos(urls), mode: "Interval · JPEG")
        }
        camera.onFinishLiveBlend = { result in
            camera.stop()
            dismiss()
            // The experiment log rides along as a JSON sidecar (the project
            // model filters .json from media), so shared/imported projects
            // carry their own capture diagnostics.
            let format = result.outputFormat == "dng" ? "DNG" : "JPEG"
            let blend = framesPerBlend > 1 ? " · \(framesPerBlend)-frame blend" : ""
            model.setSource(
                .photos(result.frameURLs + [result.logURL]),
                mode: "Interval · \(format)\(blend)")
        }
        orientation = currentCaptureOrientation()
        #if os(iOS)
        // Deliver orientation-change notifications so the grid overlay's aspect
        // stays correct and the preview gets nudged to re-read its window
        // orientation on rotation. The preview drives the capture connections.
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        camera.setVideoOrientation(orientation)
        #endif
        camera.start()
        updateAspectPreview()
        framingStartedAt = Date()
    }

    /// True when the next Interval shoot will capture DNG — the session
    /// should be framing on the full 4:3 sensor, not the 16:9 video format.
    private var wantsPhotoAspectPreview: Bool {
        mode == .interval
            && model.intervalOutputFormat == .dng
            && camera.liveBlendDNGSupport.isSupported
    }

    private func updateAspectPreview() {
        camera.setPhotoAspectPreview(wantsPhotoAspectPreview)
    }

    private func cleanUpOnDisappear() {
        #if os(iOS)
        watchRemote.setCommandHandler(nil)
        UIApplication.shared.isIdleTimerDisabled = false
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
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

            if !isCapturing {
                modeRow
            }

            #if os(iOS)
            exposurePanel
            #endif

            HStack {
                leadingControl
                    .frame(width: 96)
                Spacer()
                shutterButton
                Spacer()
                trailingControl
                    .frame(width: 96)
            }
            .padding(.horizontal, 24)
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
                formatPill
                Spacer()
                if !isCapturing {
                    zoomChips
                }
            }
            .padding(.vertical, 16)
            .frame(width: 108)

            // Viewfinder with the estimate/interval chips in the safe corner
            viewfinder
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottomLeading) {
                    Group {
                        if mode == .video {
                            landscapeEstimateChips
                        } else {
                            landscapeIntervalRow
                        }
                    }
                    .padding(10)
                }

            // Right rail: mode + shutter, exposure lock below (the burst/
            // marker trigger takes that slot while recording).
            VStack {
                landscapeModeToggle

                Spacer()
                shutterButton
                Spacer()

                if camera.isRecording {
                    leadingControl
                } else {
                    landscapeExposureControl
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

    /// Stacked upright mode labels for the rail — the words must stay readable
    /// in landscape, so they stack vertically instead of rotating 90°.
    private var landscapeModeToggle: some View {
        VStack(spacing: 10) {
            Button {
                guard !isCapturing else { return }
                mode = .interval
            } label: {
                Text("INTERVAL")
                    .foregroundStyle(mode == .interval ? LL.amber : .white.opacity(0.5))
            }
            .buttonStyle(.plain)

            Button {
                guard !isCapturing else { return }
                mode = .video
            } label: {
                Text("VIDEO")
                    .foregroundStyle(mode == .video ? LL.amber : .white.opacity(0.5))
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 11, weight: .bold))
        .kerning(0.6)
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

    /// The viewfinder region. Transparent — the live preview shows through from
    /// the persistent layer behind `body`'s ZStack; only the grid draws here.
    /// It also hosts the framing gestures: swipe between modes, pinch through
    /// the lenses.
    private var viewfinder: some View {
        GeometryReader { geometry in
            let fitted = aspectFitSize(
                aspectRatio: previewAspectRatio,
                maxWidth: geometry.size.width,
                maxHeight: geometry.size.height
            )
            ZStack {
                Color.clear
                if showGrid {
                    RuleOfThirdsGrid()
                        .frame(width: fitted.width, height: fitted.height)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .contentShape(Rectangle())
        .simultaneousGesture(modeSwipeGesture)
        .simultaneousGesture(lensPinchGesture)
    }

    /// Swipe across the viewfinder to change modes, matching the mode row's
    /// order (INTERVAL · VIDEO): swipe left moves right along the row, swipe
    /// right moves left. The 40 pt floor keeps taps and menu touches free.
    private var modeSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 40)
            .onEnded { value in
                guard !isCapturing else { return }
                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dx) > abs(dy) * 1.5, abs(dx) > 60 else { return }
                mode = dx < 0 ? .video : .interval
            }
    }

    /// Pinch steps through the lenses one stop per threshold crossed:
    /// pinch in walks .5× → 1× → 3×, pinch out walks back, stopping at
    /// the tight and wide ends.
    private var lensPinchGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                guard !isCapturing, camera.availableLenses.count > 1 else { return }
                let threshold: CGFloat = 1.35
                while value / pinchBaseline > threshold {
                    pinchBaseline *= threshold
                    stepLens(tighter: false)
                }
                while value / pinchBaseline < 1 / threshold {
                    pinchBaseline /= threshold
                    stepLens(tighter: true)
                }
            }
            .onEnded { _ in
                pinchBaseline = 1
            }
    }

    private func stepLens(tighter: Bool) {
        let lenses = camera.availableLenses
        guard let index = lenses.firstIndex(of: camera.selectedLens) else { return }
        let next = tighter ? index + 1 : index - 1
        guard lenses.indices.contains(next) else { return }
        camera.selectedLens = lenses[next]
        camera.selectLens(lenses[next])
    }

    private var previewAspectRatio: CGFloat {
        // The letterbox follows what the sensor is actually delivering
        // (4:3 while a DNG shoot is armed), not the video-format selection.
        let resolution = camera.previewDimensions ?? camera.selectedResolution
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
            guard !isCapturing else { return }
            showFormatSheet = true
        } label: {
            HStack(spacing: 4) {
                Text(formatSummary)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isCapturing ? .white.opacity(0.55) : .white)
                if camera.isVideoStabilizationEnabled && mode == .video {
                    Text("· Stab")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isCapturing ? LL.amber.opacity(0.6) : LL.amber)
                }
                if mode == .interval {
                    // The output format is part of the pill in Interval —
                    // DNG in amber (it changes what lands on disk), JPEG in
                    // the ordinary weight.
                    if model.intervalOutputFormat == .dng && camera.liveBlendDNGSupport.isSupported {
                        Text("· DNG")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(isCapturing ? LL.amber.opacity(0.6) : LL.amber)
                    } else {
                        Text("· JPEG")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(isCapturing ? .white.opacity(0.55) : .white)
                    }
                }
                Image(systemName: isCapturing ? "lock.fill" : "chevron.down")
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

    /// Video reads "2160p · 30"; Interval drops the frame rate — stills
    /// have no base rate, the pill's trailing token carries the format.
    /// With DNG armed the shoot captures the full sensor, so the pill
    /// presents the sensor frame ("12MP 4:3"), not the video format.
    private var formatSummary: String {
        if mode == .video {
            return "\(camera.selectedResolution.label) · \(camera.selectedFrameRate)"
        }
        if model.intervalOutputFormat == .dng,
           camera.liveBlendDNGSupport.isSupported,
           let sensor = camera.liveBlendDNGSupport.sensorDimensions {
            return sensorSummaryLabel(sensor)
        }
        return camera.selectedResolution.label
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

    /// One of the interval engines is running — the plain photo timer or the
    /// blend pipeline; either way the row swaps to counters.
    private var isIntervalCapturing: Bool {
        camera.isIntervalRunning || camera.isLiveBlendRunning
    }

    @ViewBuilder
    private var intervalStatusRow: some View {
        if isIntervalCapturing {
            VStack(spacing: 8) {
                intervalRunningPills
                blendDiagnosticsReadout
            }
        } else {
            // The output format lives in the format pill and its sheet — no
            // duplicate copy line here.
            intervalPickerRow
        }
    }

    /// Landscape twin of `intervalStatusRow`, shown in the viewfinder's safe
    /// corner: the controls sit over the live image (no letterbox there), so
    /// they get dark backdrops to stay legible.
    @ViewBuilder
    private var landscapeIntervalRow: some View {
        if isIntervalCapturing {
            VStack(alignment: .leading, spacing: 6) {
                intervalRunningPills
                blendDiagnosticsReadout
            }
        } else {
            intervalPickerRow
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Color.black.opacity(0.5), in: Capsule())
        }
    }

    private var intervalRunningPills: some View {
        HStack(spacing: 12) {
            if camera.isLiveBlendRunning {
                CameraPill(
                    text: "\(camera.liveBlendOutputCount) \(framesPerBlend > 1 ? "blends" : "photos")",
                    tint: LL.amber, bold: true, monospaced: true)
            } else {
                CameraPill(text: "\(camera.photoCount) photos", tint: LL.amber, bold: true, monospaced: true)
            }
            CameraPill(text: elapsedIntervalText, tint: .white.opacity(0.7), monospaced: true)
        }
    }

    private var elapsedIntervalText: String {
        DurationFormatter.recordingTime(from: now.timeIntervalSince(framingStartedAt))
    }

    /// The two interval dials — spacing and blend depth. One line where it
    /// fits (Mac, landscape phones/iPads); portrait iPhones fall back to two
    /// stacked lines.
    private var intervalPickerRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                intervalEveryPicker
                blendFramesPicker
                blendCaption
            }
            VStack(alignment: .leading, spacing: 6) {
                intervalEveryPicker
                HStack(spacing: 8) {
                    blendFramesPicker
                    blendCaption
                }
            }
        }
    }

    private var intervalEveryPicker: some View {
        HStack(spacing: 8) {
            // fixedSize keeps ViewThatFits honest: a wrappable label would
            // let the one-line layout "fit" by folding the word in half.
            Text("EVERY")
                .font(.system(size: 10, weight: .bold))
                .kerning(0.8)
                .foregroundStyle(.white.opacity(0.45))
                .fixedSize()
            Menu {
                ForEach(captureIntervalOptions, id: \.self) { seconds in
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
                pickerMenuLabel(intervalLabel(interval))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private var blendFramesPicker: some View {
        HStack(spacing: 8) {
            Text("BLEND")
                .font(.system(size: 10, weight: .bold))
                .kerning(0.8)
                .foregroundStyle(.white.opacity(0.45))
                .fixedSize()
            Menu {
                ForEach(blendFrameOptions, id: \.frames) { option in
                    Button {
                        framesPerBlend = option.frames
                    } label: {
                        if framesPerBlend == option.frames {
                            Label(blendOptionLabel(option), systemImage: "checkmark")
                        } else {
                            Text(blendOptionLabel(option))
                        }
                    }
                }
            } label: {
                pickerMenuLabel(framesPerBlend == 1 ? "Off" : "\(framesPerBlend) frames")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private func blendOptionLabel(_ option: (frames: Int, label: String)) -> String {
        option.frames == 1 ? option.label : "\(option.frames) frames · \(option.label)"
    }

    /// The trailing "into one image" only makes sense while blending.
    @ViewBuilder
    private var blendCaption: some View {
        if framesPerBlend > 1 {
            Text("into one image")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))
        }
    }

    private func pickerMenuLabel(_ text: String) -> some View {
        HStack(spacing: 4) {
            Text(text)
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

    /// Compact pipeline readout while the blend engine runs; the plain photo
    /// timer produces no diagnostics, so plain-JPEG shoots never see it.
    @ViewBuilder
    private var blendDiagnosticsReadout: some View {
        if camera.isLiveBlendRunning, let diagnostics = camera.liveBlendDiagnostics {
            VStack(alignment: .leading, spacing: 2) {
                Text("frames \(diagnostics.currentWindowSelectedFrames)/\(diagnostics.requestedFramesPerBlend) · last \(diagnostics.lastCapturedFrames.map(String.init) ?? "–")")
                Text("out \(diagnostics.lastOutputIntervalSeconds.map { String(format: "%.2f s", $0) } ?? "–") (req \(String(format: "%.1f s", diagnostics.requestedIntervalSeconds)))")
                Text("blend \(diagnostics.lastBlendMillis.map { String(format: "%.0f ms", $0) } ?? "–")\(diagnostics.outputFormatLabel.map { " · \($0)" } ?? "") · \(diagnostics.status.rawValue)")
                    .foregroundStyle(blendStatusTint(diagnostics.status))
            }
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.75))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func blendStatusTint(_ status: LiveBlendStatus) -> Color {
        switch status {
        case .healthy: return .white.opacity(0.75)
        case .captureFailed: return .red
        default: return LL.amber
        }
    }

    private func intervalLabel(_ seconds: Double) -> String {
        seconds == floor(seconds) ? "\(Int(seconds)) s" : String(format: "%.1f s", seconds)
    }

    // MARK: - Mode + zoom row

    private var modeRow: some View {
        #if os(iOS)
        let spacing: CGFloat = 14
        #else
        let spacing: CGFloat = 22
        #endif
        return HStack(spacing: spacing) {
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
        Button(action: shutterTapped) {
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
                    if let label = shutterDelayLabel {
                        Text(label)
                            .font(.system(size: 17, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                    }
                }
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(camera.isAuthorized != true)
        .accessibilityLabel(isCapturing ? "Stop" : "Record")
    }

    /// "2s" while the delay is armed; the live countdown once tapped.
    private var shutterDelayLabel: String? {
        if let deadline = delayedStartAt {
            return "\(max(1, Int(deadline.timeIntervalSince(now).rounded(.up))))"
        }
        return shutterDelayEnabled ? "2s" : nil
    }

    /// On-phone shutter taps honor the 2 s delay when armed (and a tap
    /// during the countdown cancels it). Stops are always immediate, and the
    /// Watch remote calls `shutterAction()` directly — no delay on the wrist.
    private func shutterTapped() {
        if delayedStartAt != nil {
            delayedStartAt = nil
            return
        }
        if !isCapturing && shutterDelayEnabled {
            delayedStartAt = Date().addingTimeInterval(2)
            return
        }
        shutterAction()
    }

    private var isCapturing: Bool {
        camera.isRecording || camera.isIntervalRunning || camera.isLiveBlendRunning
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
            } else if camera.isLiveBlendRunning {
                camera.stopLiveBlend()
            } else {
                framingStartedAt = Date()
                startIntervalCapture()
            }
        }
    }

    /// Routes an Interval shoot to the engine its dials call for:
    /// plain JPEG stills come from the photo-output timer (Apple's full
    /// processed pipeline, not a video-tap grab), everything else — any
    /// blending, or DNG output — runs through the blend pipeline, which
    /// handles a 1-frame DNG window as untouched originals. DNG on an
    /// unsupported source degrades per dial: blends fall back to the JPEG
    /// video tap, unblended shoots to real JPEG stills.
    private func startIntervalCapture() {
        let wantsDNG = model.intervalOutputFormat == .dng && camera.liveBlendDNGSupport.isSupported
        if !wantsDNG && framesPerBlend == 1 {
            camera.startInterval(every: interval)
            return
        }
        camera.startLiveBlend(
            every: interval,
            framesPerBlend: framesPerBlend,
            preferDNG: wantsDNG,
            options: LiveBlendCaptureOptions(
                responsiveCapture: model.liveBlendResponsiveCapture,
                burstScheduling: model.liveBlendBurstCapture,
                bracketedRAW: model.liveBlendBracketedRAW))
    }

    /// Left of the shutter: the burst/marker trigger while recording,
    /// the exposure lock otherwise.
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
            exposureLockCircle
        }
    }

    /// Circular AE/AF lock, sized for the shutter-row slots and the
    /// landscape rail. The locked readout and fine ISO/focus sliders live in
    /// `exposurePanel` (portrait) once locked.
    private var exposureLockCircle: some View {
        Button {
            toggleExposureLock()
        } label: {
            Image(systemName: camera.isExposureLocked ? "lock.fill" : "lock.open")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(camera.isExposureLocked ? .black : .white)
                .frame(width: 44, height: 44)
                .background(
                    camera.isExposureLocked ? LL.amber : Color(red: 0.17, green: 0.17, blue: 0.18).opacity(0.9),
                    in: Circle()
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(camera.isExposureLocked ? "Unlock exposure and focus" : "Lock exposure and focus")
    }

    /// Right of the shutter: delay + grid toggles idle, the interval/marker
    /// count while recording.
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
            HStack(spacing: 8) {
                Button {
                    shutterDelayEnabled.toggle()
                    if !shutterDelayEnabled {
                        delayedStartAt = nil
                    }
                } label: {
                    Image(systemName: "timer")
                        .font(.system(size: 18))
                        .foregroundStyle(shutterDelayEnabled ? LL.amber : .white)
                        .frame(width: 44, height: 44)
                        .background(Color(red: 0.17, green: 0.17, blue: 0.18).opacity(0.9), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(shutterDelayEnabled ? "Turn off 2 second delay" : "Turn on 2 second delay")

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

    // MARK: - Manual exposure

    /// Landscape-rail variant: the lock circle plus the frozen readout.
    /// Fine ISO/focus tuning lives in portrait or on the Watch crown.
    private var landscapeExposureControl: some View {
        VStack(spacing: 6) {
            exposureLockCircle

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

    #if os(iOS)
    /// The locked-exposure readout and fine ISO/focus sliders, shown in any
    /// mode once AE/AF is locked. The lock toggle itself is the circular
    /// button beside the shutter (`exposureLockCircle`).
    @ViewBuilder
    private var exposurePanel: some View {
        if camera.isExposureLocked {
            VStack(spacing: 10) {
                HStack {
                    Text(exposureReadout)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(LL.amber)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer()
                }

                if isoSliderRange.lowerBound < isoSliderRange.upperBound {
                    exposureSlider(icon: "sun.max.fill", value: isoBinding, range: isoSliderRange)
                }
                exposureSlider(icon: "camera.macro", value: focusBinding, range: 0...1)
            }
            .padding(.horizontal, 16)
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
    #endif

    // MARK: - Watch

    #if os(iOS)
    private func handleWatchCommand(_ command: WatchCaptureCommand, payload: [String: Any]) {
        let value = payload[WatchMessageKey.value] as? Double
        switch command {
        case .startRecording:
            // Starts whatever mode the capture screen is in — the same
            // dispatch as the on-phone shutter, not a forced video recording.
            guard !isCapturing else { return }
            shutterAction()
        case .stopRecording:
            if camera.isRecording {
                camera.stopRecording()
            } else if camera.isIntervalRunning {
                camera.stopInterval()
            } else if camera.isLiveBlendRunning {
                camera.stopLiveBlend()
            }
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
        case .setCaptureMode:
            // token-tolerant: a stale Watch build may still send the retired
            // "Live Blend" mode, which resolves to Interval.
            guard !isCapturing,
                  let token = payload[WatchMessageKey.captureMode] as? String,
                  let newMode = CaptureMode(token: token) else { return }
            mode = newMode
        case .setIntervalSeconds:
            guard !isCapturing, let value, captureIntervalOptions.contains(value) else { return }
            interval = value
        case .setFramesPerBlend:
            guard !isCapturing, let value,
                  blendFrameOptions.contains(where: { $0.frames == Int(value) }) else { return }
            framesPerBlend = Int(value)
        case .scheduleStop:
            guard isCapturing, let value,
                  let token = payload[WatchMessageKey.stopAtUnit] as? String,
                  let unit = ScheduledStopUnit(rawValue: token) else { return }
            camera.scheduleStop(unit: unit, amount: value)
        case .cancelScheduledStop:
            camera.cancelScheduledStop()
        case .state:
            updateWatchRecordingState()
            updateWatchModeContext()
            updateWatchScheduledStop()
        }
    }

    private func updateWatchRecordingState() {
        watchRemote.setRecordingState(
            isCapturing ? .recording : .idle,
            startedAt: camera.recordingStartedAt ?? (isCapturing ? framingStartedAt : nil),
            sequenceMode: camera.activeSequenceMode ?? sequenceMode,
            markerCount: camera.markerCount,
            rampIntervalCount: camera.rampIntervalCount,
            segmentCount: camera.segmentCount,
            isRampActive: camera.isRampActive,
            isRampHighRate: camera.isRampHighRate
        )
    }

    private func updateWatchContext() {
        // Mirror the format pill: Video reads "2160p · 30 fps", Interval
        // reads the still format ("12MP 4:3 · DNG" / "1080p · JPEG").
        let formatLine: String
        if mode == .interval {
            let dngActive = model.intervalOutputFormat == .dng && camera.liveBlendDNGSupport.isSupported
            formatLine = "\(formatSummary) · \(dngActive ? "DNG" : "JPEG")"
        } else {
            formatLine = "\(camera.selectedResolution.label) · \(camera.selectedFrameRate) fps"
        }
        watchRemote.setCaptureContext(
            formatLine: formatLine,
            captureFPS: camera.selectedFrameRate,
            plannedSpeed: model.constantWindow,
            outputFPS: model.outputFPS
        )
    }

    private func updateWatchModeContext() {
        let count: Int
        if camera.isLiveBlendRunning {
            count = camera.liveBlendOutputCount
        } else if camera.isIntervalRunning {
            count = camera.photoCount
        } else {
            count = 0
        }
        watchRemote.setModeContext(
            mode: mode,
            intervalSeconds: interval,
            framesPerBlend: framesPerBlend,
            captureCount: count)
    }

    private func updateWatchScheduledStop() {
        watchRemote.setScheduledStopContext(
            unit: camera.scheduledStop?.unit,
            deadline: camera.scheduledStop?.deadline,
            targetCount: camera.scheduledStop?.targetCount)
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
        UIApplication.shared.isIdleTimerDisabled = camera.isRecording || camera.isIntervalRunning || camera.isLiveBlendRunning
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
            // Strong enough to read over bright scenes — the old 0.22
            // hairline vanished in daylight.
            .stroke(.white.opacity(0.9), lineWidth: 1)
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

/// "12MP 4:3" — a sensor frame the way photographers read one.
private func sensorSummaryLabel(_ sensor: CameraController.CaptureResolution) -> String {
    let megapixels = Int((Double(sensor.width) * Double(sensor.height) / 1_000_000).rounded())
    return "\(megapixels)MP \(sensorAspectLabel(sensor))"
}

private func sensorAspectLabel(_ sensor: CameraController.CaptureResolution) -> String {
    let ratio = Double(sensor.width) / Double(max(sensor.height, 1))
    // Sensors sometimes report a few extra readout pixels (4224×3024), so
    // match the photographic ratios with tolerance before reducing exactly.
    let common: [(label: String, value: Double)] = [
        ("4:3", 4.0 / 3.0), ("3:2", 1.5), ("16:9", 16.0 / 9.0), ("1:1", 1.0),
    ]
    if let match = common.first(where: { abs($0.value - ratio) < 0.02 }) {
        return match.label
    }
    func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
    let divisor = max(gcd(Int(sensor.width), Int(sensor.height)), 1)
    return "\(Int(sensor.width) / divisor):\(Int(sensor.height) / divisor)"
}

/// Advanced capture format, off the viewfinder entirely. Shows each mode
/// its own dials: Video gets frame rates, stabilization and speed bursts;
/// Interval gets the output format (JPEG or DNG) instead — stills have no
/// base frame rate.
private struct FormatSheet: View {
    @ObservedObject var camera: CameraController
    @ObservedObject var model: AppModel
    @Binding var mode: CaptureMode
    @Binding var sequenceMode: LiveCaptureSequence.Mode
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                // Choices with downstream consequences come first: Interval's
                // output format decides whether resolution is even selectable,
                // and Video's stabilization filters the format list below it.
                if mode == .interval {
                    Section {
                        Picker("Output", selection: $model.intervalOutputFormat) {
                            Text("JPEG").tag(IntervalOutputFormat.jpeg)
                            Text("DNG").tag(IntervalOutputFormat.dng)
                        }
                        .pickerStyle(.segmented)
                    } header: {
                        Text("Output format")
                    } footer: {
                        if camera.liveBlendDNGSupport.isSupported {
                            let aspect = camera.liveBlendDNGSupport.sensorDimensions.map(sensorAspectLabel) ?? "4:3"
                            Text("DNG keeps the sensor's raw data — white balance and tone stay adjustable in post, for day-to-night and mixed-light work. Applies with or without blending, and captures the sensor's full \(aspect) frame — the viewfinder shows that framing. JPEG is smaller and ready to share.")
                        } else {
                            Text("DNG unavailable — \(camera.liveBlendDNGSupport.reason ?? "not supported on this camera source"). Shoots fall back to JPEG.")
                        }
                    }
                }

                Section {
                    if mode == .video {
                        Toggle("Stabilization", isOn: Binding(
                            get: { camera.isVideoStabilizationEnabled },
                            set: { camera.setVideoStabilizationEnabled($0) }
                        ))
                    }

                    if mode == .interval && model.intervalOutputFormat == .dng,
                       camera.liveBlendDNGSupport.isSupported,
                       let sensor = camera.liveBlendDNGSupport.sensorDimensions {
                        // DNG captures the sensor's full photo frame — the
                        // video-format list doesn't apply, so state the real
                        // resolution instead of offering a dead picker.
                        HStack {
                            Text("Resolution")
                            Spacer()
                            Text("\(sensor.width)×\(sensor.height) · \(sensorSummaryLabel(sensor))")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Picker("Resolution", selection: $camera.selectedResolution) {
                            ForEach(camera.availableResolutions) { resolution in
                                Text(mode == .video && resolution.isProRes ? "\(resolution.label) *" : resolution.label).tag(resolution)
                            }
                        }
                        .onChange(of: camera.selectedResolution) { resolution in
                            camera.selectResolution(resolution)
                        }
                    }

                    if mode == .video {
                        Picker(sequenceMode == .ramp ? "Base frame rate" : "Frame rate", selection: $camera.selectedFrameRate) {
                            ForEach(camera.availableFrameRates, id: \.self) { fps in
                                Text("\(fps) fps").tag(fps)
                            }
                        }
                        .onChange(of: camera.selectedFrameRate) { fps in
                            camera.selectFrameRate(fps)
                        }
                    }
                } header: {
                    Text("Format")
                } footer: {
                    if mode == .video && camera.availableResolutions.contains(where: { $0.isProRes }) {
                        Text("* ProRes — very large files")
                    }
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
    let camera: CameraController
    let orientation: AVCaptureVideoOrientation
    let videoGravity: AVLayerVideoGravity

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        /// Re-applies the connection orientation outside SwiftUI's update cycle.
        /// Needed because the preview connection does not exist at `makeUIView`
        /// time — the session is configured asynchronously on its queue — and
        /// a freshly formed connection defaults to portrait. Without this, a
        /// first open in landscape shows a sideways feed until a rotation
        /// happens to trigger `updateUIView`.
        var reapplyOrientation: (() -> Void)?
        private var sessionStartObserver: NSObjectProtocol?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                reapplyOrientation?()
            }
        }

        func observeSessionStart(of session: AVCaptureSession) {
            sessionStartObserver = NotificationCenter.default.addObserver(
                forName: .AVCaptureSessionDidStartRunning,
                object: session,
                queue: .main
            ) { [weak self] _ in
                self?.reapplyOrientation?()
            }
        }

        deinit {
            if let sessionStartObserver {
                NotificationCenter.default.removeObserver(sessionStartObserver)
            }
        }
    }

    // Temporary: count preview-view creations. Should stay at 1 for a whole
    // capture session — any increment on rotation means the preview is being
    // torn down and re-attached to the running session.
    private static var makeCount = 0

    func makeUIView(context: Context) -> PreviewView {
        Self.makeCount += 1
        LLog("CameraPreview.makeUIView #\(Self.makeCount) (preview view CREATED)")
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = videoGravity
        view.reapplyOrientation = { [weak view] in
            guard let view else { return }
            applyOrientation(to: view, from: "reapply")
        }
        view.observeSessionStart(of: session)
        applyOrientation(to: view, from: "makeUIView")
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        if uiView.previewLayer.videoGravity != videoGravity {
            uiView.previewLayer.videoGravity = videoGravity
        }
        uiView.reapplyOrientation = { [weak uiView] in
            guard let uiView else { return }
            applyOrientation(to: uiView, from: "reapply")
        }
        applyOrientation(to: uiView, from: "updateUIView")
    }

    /// Rotate only the preview connection to match the current interface
    /// orientation. Because the whole UI rotates with the device, `updateUIView`
    /// runs in step with every rotation, so the preview turns with the layout —
    /// no `UIDevice` motion notifications, no lag. The view's window scene is
    /// authoritative once it's on screen; before then (`makeUIView`) we fall
    /// back to the orientation the view was created with, which is already
    /// correct on a direct landscape launch. `PreviewView.reapplyOrientation`
    /// re-runs this on window attach and on session start, because the
    /// connection this rotates does not exist until the session's async
    /// configuration finishes — without that, a first open in landscape kept
    /// the connection at its portrait default until the device was rotated.
    ///
    /// This deliberately does NOT touch the session's capture outputs or
    /// stabilization — reconfiguring those on the live session mid-rotation was
    /// stalling the capture source. Recording/photo orientation is set at
    /// capture start instead (see `startNextSegment` / `startInterval`).
    private func applyOrientation(to view: PreviewView, from caller: String) {
        let interface = view.window?.windowScene?.interfaceOrientation
        let target = interface.map(effectiveCaptureOrientation(interface:)) ?? orientation
        let connection = view.previewLayer.connection
        LLog("applyOrientation(\(caller)) inWindow=\(view.window != nil) interface=\(interface?.rawValue ?? -1) device=\(UIDevice.current.orientation.rawValue) target=\(target.rawValue) conn=\(connection != nil) supported=\(connection?.isVideoOrientationSupported == true) current=\(connection?.videoOrientation.rawValue ?? -1)")
        if let connection,
           connection.isVideoOrientationSupported,
           connection.videoOrientation != target {
            connection.videoOrientation = target
        }
    }
}
#else
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    let camera: CameraController
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
