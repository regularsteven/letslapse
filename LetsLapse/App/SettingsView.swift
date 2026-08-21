import SwiftUI
import AVFoundation
import LetsLapseKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Screens Settings can push. Value-based so ContentView can own the
/// navigation path and pop it when the Settings tab is reselected.
enum SettingsDestination: String, Hashable {
    case largeOriginals
    case performance
    case diagnostics
    case blendLearning
    case manageResolutions
    case aiModels
}

/// Creative defaults and recording up top, storage in the middle, and the
/// engine (performance, diagnostics) demoted to Advanced.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var models = ModelManager.shared
    @ObservedObject private var captureLogs = CaptureSessionLogger.shared
    @AppStorage("capture.gpsEnabled") private var gpsEnabled = true
    /// "h264" (distribution default) or "hevc10" — what one tap of Create
    /// produces; the button's carat can override either way per run.
    @AppStorage(AppModel.blendFormatDefaultsKey) private var blendFormat = "h264"
    /// Off by default: this advertises the device on the local network and
    /// accepts start/stop commands, so it is opt-in rather than something the
    /// camera does because the build supports it.
    @AppStorage(CaptureRemoteListener.enabledKey) private var allowRemoteAccess = false
    /// Field-test selector for BLEND=Auto's decision logic (DNG path).
    /// Stored as the raw strategy id; stamped into every run's capture log.
    @AppStorage(BlendStrategyID.defaultsKey) private var blendStrategy = BlendStrategyID.zone.rawValue
    @State private var storage: AppModel.LibraryStorage?
    /// Room left on the volume the library lives on — the number that decides
    /// whether the next shoot fits, which the library's own total never could.
    @State private var freeBytes: Int64?
    @State private var isClearingCache = false
    @State private var showIncompleteCaptures = false
    @State private var customFrameRateText = RecordingSettingsStore.customFrameRate.map(String.init) ?? ""
    #if os(iOS)
    @State private var showCaptureBenchmark = false
    @State private var showCaptureOpticsProbe = false
    @AppStorage(CaptureOpticsStore.enhancedLensesKey) private var enhancedLenses = true
    #endif
    #if os(macOS)
    @State private var cameraAuthorizationStatus = CameraPrivacySettings.authorizationStatus
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Settings")
                    .font(.system(size: 34, weight: .bold))
                    .padding(.horizontal, 4)
                    .padding(.top, 8)
                    .padding(.bottom, 6)

                LLSectionHeader("Creative defaults")
                creativeDefaultsCard
                    .padding(.bottom, 12)

                LLSectionHeader("Video")
                burstRampCard
                    .padding(.bottom, 12)

                LLSectionHeader("Recording")
                recordingCard
                    .padding(.bottom, 12)

                LLSectionHeader("Location")
                locationCard
                    .padding(.bottom, 12)

                LLSectionHeader("On-device AI")
                aiCard
                    .padding(.bottom, 12)

                LLSectionHeader("Storage")
                storageCard
                    .padding(.bottom, 12)

                LLSectionHeader("Advanced")
                advancedCard

                #if os(macOS)
                LLSectionHeader("Camera")
                    .padding(.top, 12)
                cameraCard
                #endif

                Spacer(minLength: 96)
            }
            .padding(.horizontal, 16)
        }
        .background(LL.screenBackground)
        .navigationDestination(for: SettingsDestination.self) { destination in
            switch destination {
            case .largeOriginals: LargeOriginalsView()
            case .performance: PerformanceSettingsView()
            case .diagnostics: DiagnosticsView()
            case .blendLearning: BlendLearningView()
            case .manageResolutions: ManageResolutionsView()
            case .aiModels: AIModelsView()
            }
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showCaptureBenchmark) {
            CaptureBenchmarkView()
        }
        .sheet(isPresented: $showCaptureOpticsProbe) {
            CaptureOpticsProbeView()
        }
        #else
        .navigationTitle("Settings")
        #endif
        .sheet(isPresented: $showIncompleteCaptures) {
            IncompleteCapturesView()
        }
        .task {
            // Re-scan on every visit: a session that crashed since launch
            // leaves its log behind the moment the app comes back.
            CaptureSessionLogger.shared.scanForOrphanedLogs()
            #if DEBUG
            // LL_INCOMPLETE=1 — open the sheet straight from `simctl launch`
            // (with LL_TAB=settings), so the screen can be verified without
            // scrolling Settings by hand.
            if ProcessInfo.processInfo.environment["LL_INCOMPLETE"] == "1" {
                showIncompleteCaptures = true
            }
            #endif
            await refreshFreeSpace()
            if let walked = await model.computeLibraryStorage() {
                storage = walked
            }
        }
        #if os(macOS)
        .onAppear {
            cameraAuthorizationStatus = CameraPrivacySettings.authorizationStatus
        }
        #endif
    }

    // MARK: - Creative defaults

    private var creativeDefaultsCard: some View {
        VStack(spacing: 0) {
            LLRow(title: "Default speed") {
                Menu {
                    ForEach(SpeedMath.presets, id: \.self) { preset in
                        Button {
                            model.defaultSpeed = preset
                        } label: {
                            if preset == model.defaultSpeed {
                                Label("\(preset)× — \(SpeedMath.chipWord(for: preset))", systemImage: "checkmark")
                            } else {
                                Text("\(preset)× — \(SpeedMath.chipWord(for: preset))")
                            }
                        }
                    }
                } label: {
                    menuValueLabel("\(model.defaultSpeed)×")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            LLRow(title: "Output frame rate") {
                Menu {
                    ForEach([24, 25, 30, 50, 60], id: \.self) { fps in
                        Button {
                            model.outputFPS = fps
                        } label: {
                            if fps == model.outputFPS {
                                Label("\(fps) fps", systemImage: "checkmark")
                            } else {
                                Text("\(fps) fps")
                            }
                        }
                    }
                } label: {
                    menuValueLabel("\(model.outputFPS) fps")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            LLRow(title: "New clip format", subtitle: "The Create button's one-tap default") {
                Menu {
                    Button {
                        blendFormat = "h264"
                    } label: {
                        if blendFormat == "h264" {
                            Label("H.264 · widely compatible", systemImage: "checkmark")
                        } else {
                            Text("H.264 · widely compatible")
                        }
                    }
                    Button {
                        blendFormat = "hevc10"
                    } label: {
                        if blendFormat == "hevc10" {
                            Label("10-bit HEVC · highest quality", systemImage: "checkmark")
                        } else {
                            Text("10-bit HEVC · highest quality")
                        }
                    }
                } label: {
                    menuValueLabel(blendFormat == "hevc10" ? "10-bit HEVC" : "H.264")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            LLRow(
                title: "True-light blending",
                subtitle: "Blends in linear light — smoother highlights",
                showsDivider: false
            ) {
                Toggle("", isOn: $model.linearLight)
                    .labelsHidden()
                    .tint(.green)
            }
        }
        .llCard()
    }

    // MARK: - Burst ramp

    /// Where new video projects start on burst ramps. A project can always
    /// override it; with "Remember last" on, the override becomes this.
    private var burstRampCard: some View {
        VStack(spacing: 0) {
            LLRow(
                title: "Default ramp",
                subtitle: model.burstRampRememberLast
                    ? "Following the last ramp you set on a project."
                    : "Eases burst clips into and out of slow motion instead of cutting straight to it."
            ) {
                Menu {
                    Button {
                        model.burstRampDefault = nil
                    } label: {
                        if model.burstRampDefault == nil {
                            Label("Off", systemImage: "checkmark")
                        } else {
                            Text("Off")
                        }
                    }
                    ForEach(BurstRamp.choices, id: \.self) { seconds in
                        Button {
                            model.burstRampDefault = seconds
                        } label: {
                            if model.burstRampDefault == seconds {
                                Label(BurstRamp.label(seconds), systemImage: "checkmark")
                            } else {
                                Text(BurstRamp.label(seconds))
                            }
                        }
                    }
                } label: {
                    menuValueLabel(BurstRamp.label(model.burstRampDefault))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                // Read-only while the projects themselves are driving it —
                // the value still shows, it just isn't the thing to edit.
                .disabled(model.burstRampRememberLast)
            }

            LLRow(
                title: "Remember last",
                subtitle: "A project's ramp becomes the next default."
            ) {
                Toggle("", isOn: $model.burstRampRememberLast)
                    .labelsHidden()
                    .tint(.green)
            }

            LLRow(
                title: "Bursts can raise resolution",
                subtitle: "Adds higher-resolution options to the burst picker, so a "
                    + "moment can shoot 4K off a 1080p base and keep the pixels for a "
                    + "punch-in. Only formats that frame the scene identically are "
                    + "offered. The switch takes longer, so the seam eases wider.",
                showsDivider: false
            ) {
                Toggle("", isOn: $model.burstResolutionEnabled)
                    .labelsHidden()
                    .tint(.green)
            }
        }
        .llCard()
    }

    // MARK: - Recording

    private var recordingCard: some View {
        VStack(spacing: 0) {
            LLRow(
                title: "Remember recording settings",
                subtitle: "Start each shoot in your last-used mode with its settings — lens, resolution, frame rate, stabilization, interval spacing and blend frames"
            ) {
                Toggle("", isOn: $model.rememberRecordingSettings)
                    .labelsHidden()
                    .tint(.green)
            }

            // The JPEG/DNG output choice lives in the capture screen's
            // format sheet with the other per-shoot dials; these rows are
            // the advanced DNG capture experiments, shown once DNG is on.
            #if os(iOS)
            if model.intervalOutputFormat == .dng {
                LLRow(
                    title: "DNG bracketed RAW",
                    subtitle: "Runs of back-to-back sensor frames per request — the tightest spacing possible, and the benchmark's most reliable mechanism. Falls back to single shots if the camera declines."
                ) {
                    Toggle("", isOn: $model.liveBlendBracketedRAW)
                        .labelsHidden()
                        .tint(.green)
                }

                LLRow(
                    title: "DNG tight burst",
                    subtitle: "Captures each blend's frames back-to-back at the start of the interval instead of spreading them out — moving subjects streak instead of ghosting."
                ) {
                    Toggle("", isOn: $model.liveBlendBurstCapture)
                        .labelsHidden()
                        .tint(.green)
                }

                LLRow(
                    title: "DNG fast capture",
                    subtitle: "Experimental: overlaps RAW captures through the system's responsive pipeline. Benchmarked faster than sequential but stalled the camera after ~15 rapid captures — keep off except for testing."
                ) {
                    Toggle("", isOn: $model.liveBlendResponsiveCapture)
                        .labelsHidden()
                        .tint(.green)
                }

                LLRow(
                    title: "Capture benchmark",
                    subtitle: "Automated timing run: 3/5/10-frame RAW bursts under every capture mechanism, ×3, plus the full blend pipeline per stage. Results copy as text."
                ) {
                    Button("Open") { showCaptureBenchmark = true }
                        .buttonStyle(.bordered)
                        .tint(.green)
                }
            }

            LLRow(
                title: "Enhanced lenses",
                subtitle: "Adds the derived sensor-crop and 2× digital lens stops (dot-marked) beside the optical lenses. Optical stops always show."
            ) {
                Toggle("", isOn: $enhancedLenses)
                    .labelsHidden()
                    .tint(.green)
            }

            // Capture Optics groundwork: lens-topology diagnostics, not
            // gated on DNG — the lens model concerns every mode.
            LLRow(
                title: "Capture optics probe",
                subtitle: "Dumps this device's lens topology — switchover factors, native sensor crops, RAW support per stop — and the lens chips it would derive. Results copy as text."
            ) {
                Button("Open") { showCaptureOpticsProbe = true }
                    .buttonStyle(.bordered)
                    .tint(.green)
            }
            #endif

            NavigationLink(value: SettingsDestination.manageResolutions) {
                LLRow(
                    title: "Manage resolutions",
                    subtitle: "Choose which resolutions Capture Format offers — separate lists for stills and video"
                ) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            LLRow(
                title: "Record audio",
                subtitle: "Capture microphone sound with video shoots. Off keeps shoots silent and lets playing music continue.",
                showsDivider: false
            ) {
                Toggle("", isOn: recordAudioBinding)
                    .labelsHidden()
                    .tint(.green)
            }
        }
        .llCard()
    }

    /// Turning audio on asks for microphone access first; the toggle only
    /// sticks when access is granted, so the stored setting always reflects
    /// what a shoot will actually do.
    private var recordAudioBinding: Binding<Bool> {
        Binding(
            get: { model.recordAudio },
            set: { wantsAudio in
                guard wantsAudio else {
                    model.recordAudio = false
                    return
                }
                switch AVCaptureDevice.authorizationStatus(for: .audio) {
                case .authorized:
                    model.recordAudio = true
                case .notDetermined:
                    AVCaptureDevice.requestAccess(for: .audio) { granted in
                        DispatchQueue.main.async { model.recordAudio = granted }
                    }
                default:
                    model.recordAudio = false
                }
            }
        )
    }

    // MARK: - Location

    private var locationCard: some View {
        VStack(spacing: 0) {
            LLRow(
                title: "Geotag captures",
                subtitle: "Save GPS coordinates in photo EXIF and write a GPX track sidecar next to captured video.",
                showsDivider: false
            ) {
                Toggle("", isOn: $gpsEnabled)
                    .labelsHidden()
                    .tint(.green)
            }
        }
        .llCard()
    }

    // MARK: - On-device AI

    /// The only entry point to the model library. The subtitle carries the state so the feature's
    /// readiness is legible without opening the screen — this is what the "Auto rename & tag"
    /// action on a project depends on.
    private var aiCard: some View {
        VStack(spacing: 0) {
            NavigationLink(value: SettingsDestination.aiModels) {
                LLRow(
                    title: "AI Models",
                    subtitle: aiModelsSubtitle,
                    showsDivider: false
                ) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .llCard()
    }

    private var aiModelsSubtitle: String {
        if let active = models.activeModel {
            return "\(active.name) · automatic naming and tagging is on"
        }
        return "Download a model to name and tag captures on this device"
    }

    private func menuValueLabel(_ text: String) -> some View {
        HStack(spacing: 4) {
            Text(text)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 10, weight: .semibold))
        }
        .font(.system(size: 15))
        .foregroundStyle(.secondary)
    }

    // MARK: - Storage

    private var storageCard: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                // First, because it is the one figure here that constrains
                // anything. What the library weighs is a fact about the past;
                // what is free is the answer to "can I shoot this?", and it is
                // the same number the capture screen's headroom chip is
                // costing frames against (see `CaptureHeadroom`).
                HStack {
                    Text("Free on this device")
                        .font(.system(size: 16))
                    Spacer()
                    Text(freeBytes.map { LLFormat.bytes($0) } ?? "…")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(freeSpaceIsTight ? LL.accent : .secondary)
                }

                Divider()

                HStack {
                    Text("LetsLapse library")
                        .font(.system(size: 16))
                    Spacer()
                    Text(storage.map { LLFormat.bytes($0.totalBytes) } ?? "…")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }

                if let storage, storage.totalBytes > 0 {
                    StorageBar(storage: storage)
                    HStack(spacing: 14) {
                        legendDot(color: LL.accent, label: "Originals \(LLFormat.bytes(storage.originalsBytes))")
                        legendDot(color: LL.amber, label: "Blended clips \(LLFormat.bytes(storage.versionsBytes))")
                        legendDot(color: Color.secondary.opacity(0.35), label: "Cache \(LLFormat.bytes(storage.cacheBytes))")
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            Divider().padding(.leading, 16)

            NavigationLink(value: SettingsDestination.largeOriginals) {
                LLRow(title: "Review large originals") {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                clearCache()
            } label: {
                LLRow(
                    title: isClearingCache
                        ? "Clearing…"
                        : "Clear cache\(storage.map { " (\(LLFormat.bytes($0.cacheBytes)))" } ?? "")",
                    titleColor: LL.accent,
                    showsDivider: false
                ) {
                    EmptyView()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isClearingCache || (storage?.cacheBytes ?? 0) == 0)
        }
        .llCard()
    }

    /// Under 2 GB is roughly a minute of 4K or a dozen RAW stills — little
    /// enough that a shoot started now is a shoot that ends by running out.
    /// The same threshold the capture chip goes amber at.
    private var freeSpaceIsTight: Bool {
        (freeBytes ?? .max) < 2 * 1_000_000_000
    }

    private func refreshFreeSpace() async {
        freeBytes = await CaptureHeadroom.freeBytes(near: model.projectsFolderURL)
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func clearCache() {
        isClearingCache = true
        Task {
            await model.clearCache()
            await refreshFreeSpace()
            if let walked = await model.computeLibraryStorage() {
                storage = walked
            }
            isClearingCache = false
        }
    }

    // MARK: - Advanced

    private var advancedCard: some View {
        VStack(spacing: 0) {
            #if os(iOS)
            LLRow(
                title: "Allow remote access",
                subtitle: "Lets a Mac on the same Wi-Fi control this camera. Only while the capture screen is open, and only after entering the pairing code shown there"
            ) {
                Toggle("", isOn: $allowRemoteAccess)
                    .labelsHidden()
                    .tint(.green)
            }
            #endif

            LLRow(
                title: "Custom frame rate",
                subtitle: "Adds an extra rate to capture's frame-rate options whenever the camera supports it"
            ) {
                HStack(spacing: 4) {
                    TextField("Off", text: $customFrameRateText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 48)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                        .onChange(of: customFrameRateText) { commitCustomFrameRate($0) }
                    Text("fps")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
            }

            NavigationLink(value: SettingsDestination.blendLearning) {
                LLRow(title: "Blend learning", subtitle: "What Psycho intervals have taught Safe mode on this device") {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            #if os(iOS)
            LLRow(
                title: "Auto blend strategy",
                subtitle: "Field test: how BLEND Auto picks its depth on DNG shoots. Every run logs what all three would have chosen"
            ) {
                Menu {
                    ForEach(BlendStrategyID.allCases, id: \.rawValue) { strategy in
                        Button {
                            blendStrategy = strategy.rawValue
                        } label: {
                            if strategy.rawValue == blendStrategy {
                                Label(strategy.displayName, systemImage: "checkmark")
                            } else {
                                Text(strategy.displayName)
                            }
                        }
                    }
                } label: {
                    menuValueLabel(BlendStrategyID(rawValue: blendStrategy)?.displayName ?? "Zone")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            #endif

            NavigationLink(value: SettingsDestination.performance) {
                LLRow(title: "Performance", subtitle: "CPU workers, GPU batches") {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            NavigationLink(value: SettingsDestination.diagnostics) {
                LLRow(
                    title: "Diagnostics",
                    subtitle: "Job folders, processing logs",
                    showsDivider: !captureLogs.orphanedLogs.isEmpty
                ) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Only ever shown when there is something to show: a capture log
            // that outlived its process. A clean run deletes its own log, so
            // this row appearing means the app died with the camera open.
            if !captureLogs.orphanedLogs.isEmpty {
                Button {
                    showIncompleteCaptures = true
                } label: {
                    LLRow(
                        title: "Incomplete Captures",
                        subtitle: "Logs from shoots that ended in a crash or force-quit",
                        showsDivider: false
                    ) {
                        HStack(spacing: 6) {
                            Text("\(captureLogs.orphanedLogs.count)")
                                .font(.system(size: 15).monospacedDigit())
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .llCard()
    }

    /// Digits only, clamped to 1–240; empty (or 0) turns the extra rate off.
    private func commitCustomFrameRate(_ text: String) {
        let digits = String(text.filter(\.isNumber).prefix(3))
        guard digits == text else {
            customFrameRateText = digits
            return
        }
        guard let value = Int(digits), value >= 1 else {
            model.customCaptureFrameRate = nil
            return
        }
        let clamped = min(value, 240)
        if clamped != value {
            customFrameRateText = String(clamped)
        }
        model.customCaptureFrameRate = clamped
    }

    // MARK: - macOS camera

    #if os(macOS)
    private var cameraCard: some View {
        VStack(spacing: 0) {
            LLRow(title: "Camera access", showsDivider: cameraAuthorizationStatus != .authorized) {
                Text(cameraStatusText)
                    .font(.system(size: 14))
                    .foregroundStyle(cameraAuthorizationStatus == .authorized ? Color.secondary : Color.red)
            }

            if cameraAuthorizationStatus == .notDetermined {
                Button {
                    CameraPrivacySettings.requestAccess { _ in
                        cameraAuthorizationStatus = CameraPrivacySettings.authorizationStatus
                    }
                } label: {
                    LLRow(title: "Request camera access", titleColor: LL.accent, showsDivider: false) {
                        EmptyView()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else if cameraAuthorizationStatus != .authorized {
                Button {
                    CameraPrivacySettings.open()
                } label: {
                    LLRow(title: "Open camera privacy settings", titleColor: LL.accent, showsDivider: false) {
                        EmptyView()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .llCard()
    }

    private var cameraStatusText: String {
        switch cameraAuthorizationStatus {
        case .authorized: return "Enabled"
        case .notDetermined: return "Not requested"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        @unknown default: return "Unknown"
        }
    }
    #endif
}

// MARK: - Storage bar

private struct StorageBar: View {
    var storage: AppModel.LibraryStorage

    var body: some View {
        GeometryReader { geometry in
            let total = Double(max(1, storage.totalBytes))
            HStack(spacing: 1) {
                Rectangle()
                    .fill(LL.accent)
                    .frame(width: geometry.size.width * (Double(storage.originalsBytes) / total))
                Rectangle()
                    .fill(LL.amber)
                    .frame(width: geometry.size.width * (Double(storage.versionsBytes) / total))
                Rectangle()
                    .fill(Color.secondary.opacity(0.25))
            }
        }
        .frame(height: 8)
        .clipShape(Capsule())
    }
}

// MARK: - Large originals

private struct LargeOriginalsView: View {
    @EnvironmentObject var model: AppModel
    @State private var sizes: [UUID: Int64] = [:]
    @State private var pendingDelete: AppModel.CaptureProject?
    @State private var failure: String?

    private var sorted: [AppModel.CaptureProject] {
        model.captures.sorted { (sizes[$0.id] ?? 0) > (sizes[$1.id] ?? 0) }
    }

    var body: some View {
        List {
            Section {
                ForEach(sorted) { capture in
                    Button {
                        // Jumps to the Projects tab and opens this project
                        // (ContentView switches tabs, ProjectsView sets its path).
                        model.requestedProjectDetailID = capture.id
                    } label: {
                        HStack(spacing: 12) {
                            ProjectThumbnailView(
                                url: capture.isPhotoCapture
                                    ? model.heroImageURL(for: capture)
                                    : model.mediaURL(for: capture),
                                kind: model.mediaKind(for: capture))
                                .frame(width: 64, height: 46)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(capture.displayTitle)
                                    .font(.system(size: 15, weight: .semibold))
                                    .lineLimit(1)
                                let versionCount = model.blends(for: capture).count
                                // A photo capture is one asset — no version tally.
                                Text(capture.isPhotoCapture
                                        ? capture.formatLine
                                        : "\(capture.formatLine) · \(versionCount) blended clip\(versionCount == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(sizes[capture.id].map { LLFormat.bytes($0) } ?? "…")
                                .font(.system(size: 13).monospacedDigit())
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button(role: .destructive) {
                            pendingDelete = capture
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            } footer: {
                #if os(macOS)
                Text("Click a project to open it. Deleting a project removes its original and every blended clip.")
                #else
                Text("Tap a project to open it. Deleting a project removes its original and every blended clip.")
                #endif
            }
        }
        .navigationTitle("Large originals")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            for capture in model.captures {
                // A library can hold hundreds of projects and each walk touches
                // every file in one; stop the moment the screen is closed rather
                // than working through the rest of the list unseen.
                if Task.isCancelled { return }
                if let bytes = await model.storageBytes(for: capture) {
                    sizes[capture.id] = bytes
                }
            }
        }
        .alert(item: $pendingDelete) { capture in
            Alert(
                title: Text("Delete “\(capture.displayTitle)”?"),
                message: Text("This permanently deletes the original and all its blended clips."),
                primaryButton: .destructive(Text("Delete")) {
                    do {
                        try model.deleteCapture(capture)
                    } catch {
                        failure = error.localizedDescription
                    }
                },
                secondaryButton: .cancel()
            )
        }
        .alert(
            "Couldn't delete",
            isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }
}

// MARK: - Performance

private struct PerformanceSettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Stepper(
                    "CPU worker budget: \(model.maxCPUWorkers)",
                    value: $model.maxCPUWorkers,
                    in: 1...max(1, ProcessInfo.processInfo.activeProcessorCount)
                )
                Stepper(
                    "Concurrent blend batches: \(model.maxBlendBatches)",
                    value: $model.maxBlendBatches,
                    in: 1...8
                )
            } footer: {
                Text("Video decode runs mostly serially. Blend batches use Metal on the GPU; higher values may help until disk I/O or GPU contention dominates.")
            }

            #if os(macOS)
            Section {
                Picker("Scratch frame format", selection: $model.scratchFrameFormat) {
                    Text("PNG · lossless 16-bit").tag(ImageFormat.png)
                    Text("HEIC · compact, lossy").tag(ImageFormat.heic)
                    Text("JPEG · compatible, lossy").tag(ImageFormat.jpeg)
                }
                Toggle("Keep extracted frames", isOn: $model.keepExtractedFrames)
            } footer: {
                Text("Blending a video decodes it into scratch frames — 16-bit PNG keeps the pipeline's full depth at tens of MB per 4K frame; HEIC and JPEG are a small fraction of that but lossy 8-bit, which can band skies and smooth gradients. By default each batch's frames are deleted the moment its blended frame is written, so even hour-long clips need only a few GB of scratch. Keep extracted frames leaves every frame in the job folder for inspection and faster re-blends at other speeds — a long 4K clip can then need hundreds of GB.")
            }
            #endif
        }
        .navigationTitle("Performance")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Blend learning

/// What unthrottled ("Psycho") intervals have taught about this device: one
/// profile per pipeline × interval × starting thermal state, with the safe
/// count Safe mode would apply. Reset exists for unusual conditions (a new
/// case, a heatwave) — day-to-day, recent runs already outweigh old ones.
private struct BlendLearningView: View {
    @State private var summaries = BlendProfileStore.shared.summariesForCurrentDevice()
    @State private var confirmingReset = false

    var body: some View {
        Form {
            if summaries.isEmpty {
                Section {
                    Text("Nothing learned yet.")
                        .foregroundStyle(.secondary)
                } footer: {
                    Text("Set BLEND to Psycho on an Interval shoot. Every interval it captures teaches the app what this device manages at that spacing and temperature — once a profile has \(BlendLearningProfile.minSamplesForPrediction) runs, Safe mode unlocks for those conditions.")
                }
            } else {
                Section {
                    ForEach(summaries) { summary in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(title(for: summary))
                                Text("\(summary.sampleCount) run\(summary.sampleCount == 1 ? "" : "s") · best \(summary.bestFrames) · worst \(summary.worstFrames)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(valueLabel(for: summary))
                                .foregroundStyle(summary.safeFrameCount == nil ? .secondary : .primary)
                                .monospacedDigit()
                        }
                    }
                } footer: {
                    Text("Safe mode applies the learned count for the current conditions, re-checked every interval. Recent runs weigh heaviest; best and worst keep the extremes on record.")
                }

                Section {
                    Button("Reset learning", role: .destructive) {
                        confirmingReset = true
                    }
                } footer: {
                    Text("Removes every learned profile on this device. Safe mode locks again until Psycho re-teaches it.")
                }
            }
        }
        .navigationTitle("Blend learning")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .alert("Reset blend learning?", isPresented: $confirmingReset) {
            Button("Reset", role: .destructive) {
                BlendProfileStore.shared.resetAll()
                summaries = BlendProfileStore.shared.summariesForCurrentDevice()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every learned profile on this device is removed, and Safe mode locks until Psycho re-teaches it.")
        }
        .onAppear {
            summaries = BlendProfileStore.shared.summariesForCurrentDevice()
        }
    }

    private func title(for summary: BlendProfileStore.ProfileSummary) -> String {
        let interval = summary.key.intervalSeconds
        let intervalText = interval == interval.rounded(.down)
            ? "\(Int(interval)) s" : String(format: "%.1f s", interval)
        let pipeline = summary.key.pipeline == "dng" ? "DNG" : "JPEG"
        return "Every \(intervalText) · \(summary.key.thermalBucket.rawValue.capitalized) · \(pipeline)"
    }

    private func valueLabel(for summary: BlendProfileStore.ProfileSummary) -> String {
        if let safe = summary.safeFrameCount {
            return "Safe ≈ \(safe)"
        }
        return "learning \(summary.sampleCount)/\(BlendLearningProfile.minSamplesForPrediction)"
    }
}

// MARK: - Incomplete captures

/// The orphaned capture logs, one row each. Everything here is for handing to
/// a developer: the summary says when the shoot died and on what, the detail
/// screen has the whole log, and Copy All puts it on the clipboard.
struct IncompleteCapturesView: View {
    @ObservedObject private var logger = CaptureSessionLogger.shared
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDeleteAll = false

    var body: some View {
        NavigationStack {
            List {
                if logger.orphanedLogs.isEmpty {
                    Section {
                        Text("No incomplete captures.")
                            .foregroundStyle(.secondary)
                    } footer: {
                        Text("A capture session deletes its own log when the capture screen closes normally, so nothing collects here unless the app stops running mid-shoot.")
                    }
                } else {
                    Section {
                        ForEach(logger.orphanedLogs) { log in
                            NavigationLink {
                                CaptureLogDetailView(log: log)
                            } label: {
                                row(for: log)
                            }
                        }
                    } footer: {
                        Text("Each of these is a shoot that ended without the app closing the camera — a crash or a force-quit. Open one and use Copy All to send it to a developer.")
                    }

                    Section {
                        Button("Delete All", role: .destructive) {
                            confirmingDeleteAll = true
                        }
                    }
                }
            }
            .navigationTitle("Incomplete Captures")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Delete all logs?", isPresented: $confirmingDeleteAll) {
                Button("Delete All", role: .destructive) {
                    logger.deleteAllOrphanedLogs()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("All \(logger.orphanedLogs.count) incomplete-capture logs are removed. This can't be undone.")
            }
        }
        .onAppear { logger.scanForOrphanedLogs() }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 420)
        #endif
    }

    private func row(for log: CaptureSessionLogger.OrphanedLog) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(log.startedAt.map { CaptureLogFormat.started($0) } ?? log.fileName)
                    .font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 8)
                Text(log.duration.map { DurationFormatter.recordingTime(from: $0) } ?? "—")
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(subtitle(for: log))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func subtitle(for log: CaptureSessionLogger.OrphanedLog) -> String {
        var parts: [String] = []
        if let mode = log.mode { parts.append(mode) }
        parts.append("last: \(log.lastEvent)")
        parts.append("\(log.eventCount) event\(log.eventCount == 1 ? "" : "s")")
        return parts.joined(separator: " · ")
    }
}

/// One log, line by line. Monospaced and offset-stamped so the sequence of
/// events (and the gaps between them) reads at a glance.
private struct CaptureLogDetailView: View {
    let log: CaptureSessionLogger.OrphanedLog

    @ObservedObject private var logger = CaptureSessionLogger.shared
    @Environment(\.dismiss) private var dismiss
    @State private var events: [CaptureSessionLogger.Event] = []
    @State private var didCopy = false
    @State private var confirmingDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                ForEach(events) { event in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(offsetText(event))
                                .font(.system(size: 11, design: .monospaced).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 62, alignment: .trailing)
                            Text(event.name)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(event.name == "unparsed" ? Color.red : LL.accent)
                        }
                        if !event.detail.isEmpty {
                            Text(event.detail)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .padding(.leading, 70)
                        } else if event.name == "unparsed" {
                            Text(event.raw)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .padding(.leading, 70)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 5)
                    Divider()
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(LL.screenBackground)
        .navigationTitle(log.startedAt.map { CaptureLogFormat.started($0) } ?? log.fileName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    CaptureLogFormat.copyToClipboard(logger.rawText(of: log.url))
                    didCopy = true
                } label: {
                    // Spelled out rather than icon-only: this screen exists to
                    // get a log to a developer, and that is the action. A bare
                    // Text keeps the words — a Label in a nav bar renders as
                    // its icon alone whatever label style it is given.
                    Text(didCopy ? "Copied" : "Copy All")
                }
                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .alert("Delete this log?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                logger.delete(log)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes \(log.fileName). Copy it first if a developer still needs it.")
        }
        .onAppear { events = logger.events(in: log.url) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(log.fileName)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("\(log.eventCount) events · ran \(log.duration.map { DurationFormatter.recordingTime(from: $0) } ?? "—") before it stopped writing · last event \(log.lastEvent)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
    }

    /// Seconds since the log's first event — the axis that matters when
    /// reading for a stall, not the wall clock.
    private func offsetText(_ event: CaptureSessionLogger.Event) -> String {
        guard let offset = event.offset else { return "—" }
        return String(format: "+%.2fs", offset)
    }
}

enum CaptureLogFormat {
    private static let startedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    static func started(_ date: Date) -> String {
        startedFormatter.string(from: date)
    }

    static func copyToClipboard(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

// MARK: - Diagnostics

private struct DiagnosticsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("Latest job folder") {
                if let jobFolderURL = model.jobFolderURL {
                    Text(jobFolderURL.path)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                } else {
                    Text("No job folder yet — appears while a video blend runs.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Processing log") {
                if model.jobLogLines.isEmpty {
                    Text("Log lines appear here during processing.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.jobLogLines, id: \.self) { line in
                        Text(line)
                            .font(.caption.monospaced())
                    }
                }
            }
        }
        .navigationTitle("Diagnostics")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
