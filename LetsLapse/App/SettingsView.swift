import SwiftUI
import AVFoundation
import LetsLapseKit

/// Screens Settings can push. Value-based so ContentView can own the
/// navigation path and pop it when the Settings tab is reselected.
enum SettingsDestination: String, Hashable {
    case largeOriginals
    case performance
    case diagnostics
}

/// Creative defaults and recording up top, storage in the middle, and the
/// engine (performance, diagnostics) demoted to Advanced.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var storage: AppModel.LibraryStorage?
    @State private var isClearingCache = false
    @State private var customFrameRateText = RecordingSettingsStore.customFrameRate.map(String.init) ?? ""
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

                LLSectionHeader("Recording")
                recordingCard
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
            }
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #else
        .navigationTitle("Settings")
        #endif
        .task {
            storage = await model.computeLibraryStorage()
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

    // MARK: - Recording

    private var recordingCard: some View {
        VStack(spacing: 0) {
            LLRow(
                title: "Remember recording settings",
                subtitle: "Start each shoot with your last-used lens, resolution, frame rate and stabilization"
            ) {
                Toggle("", isOn: $model.rememberRecordingSettings)
                    .labelsHidden()
                    .tint(.green)
            }

            LLRow(
                title: "Live Blend output",
                subtitle: "DNG keeps white balance and colour temperature adjustable in post — for day-to-night and mixed-light work. Needs a RAW-capable camera (iPhone/iPad); other sources fall back to Standard."
            ) {
                Menu {
                    Button {
                        model.liveBlendOutputFormat = .standard
                    } label: {
                        if model.liveBlendOutputFormat == .standard {
                            Label("Standard", systemImage: "checkmark")
                        } else {
                            Text("Standard")
                        }
                    }
                    Button {
                        model.liveBlendOutputFormat = .dng
                    } label: {
                        if model.liveBlendOutputFormat == .dng {
                            Label("DNG · when supported", systemImage: "checkmark")
                        } else {
                            Text("DNG · when supported")
                        }
                    }
                } label: {
                    menuValueLabel(model.liveBlendOutputFormat == .dng ? "DNG" : "Standard")
                }
            }

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
                        legendDot(color: LL.amber, label: "Versions \(LLFormat.bytes(storage.versionsBytes))")
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
            storage = await model.computeLibraryStorage()
            isClearingCache = false
        }
    }

    // MARK: - Advanced

    private var advancedCard: some View {
        VStack(spacing: 0) {
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
                LLRow(title: "Diagnostics", subtitle: "Job folders, processing logs", showsDivider: false) {
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
                            ProjectThumbnailView(url: model.mediaURL(for: capture), kind: model.mediaKind(for: capture))
                                .frame(width: 64, height: 46)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(capture.displayTitle)
                                    .font(.system(size: 15, weight: .semibold))
                                    .lineLimit(1)
                                let versionCount = model.blends(for: capture).count
                                Text("\(capture.formatLine) · \(versionCount) version\(versionCount == 1 ? "" : "s")")
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
                Text("Click a project to open it. Deleting a project removes its original and every version.")
                #else
                Text("Tap a project to open it. Deleting a project removes its original and every version.")
                #endif
            }
        }
        .navigationTitle("Large originals")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            for capture in model.captures {
                sizes[capture.id] = await model.storageBytes(for: capture)
            }
        }
        .alert(item: $pendingDelete) { capture in
            Alert(
                title: Text("Delete “\(capture.displayTitle)”?"),
                message: Text("This permanently deletes the original and all its versions."),
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
                    Text("PNG · lossless").tag(ImageFormat.png)
                    Text("HEIC · compact").tag(ImageFormat.heic)
                    Text("JPEG · compatible").tag(ImageFormat.jpeg)
                }
                Toggle("Keep extracted frames", isOn: $model.keepExtractedFrames)
            } footer: {
                Text("Blending a video decodes it into scratch frames — about 8 MB per 4K frame as PNG, a fraction of that as HEIC. By default each batch's frames are deleted the moment its blended frame is written, so even hour-long clips need only a few GB of scratch. Keep extracted frames leaves every frame in the job folder for inspection and faster re-blends at other speeds — a long 4K clip can then need hundreds of GB.")
            }
            #endif
        }
        .navigationTitle("Performance")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
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
