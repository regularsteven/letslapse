import SwiftUI
import AVFoundation
import LetsLapseKit
#if os(iOS)
import UIKit
#else
import AppKit
import UniformTypeIdentifiers
#endif

/// Screens Settings can push. Value-based so ContentView can own the
/// navigation path and pop it when the Settings tab is reselected.
/// Cards a launch hook can scroll the Settings list to (`LL_SCROLL`).
enum SettingsAnchor: String, Hashable {
    case picplace
    case libraries
}

enum SettingsDestination: String, Hashable {
    case layout
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
    /// Also off by default, and a different grant from the one above: this
    /// serves the whole library, not the shutter. Every platform that has a
    /// library can offer it, Macs included (Phase 3).
    @AppStorage(ProjectTransferServer.enabledKey) private var allowLibrarySharing = false
    /// Field-test selector for BLEND=Auto's decision logic (DNG path).
    /// Stored as the raw strategy id; stamped into every run's capture log.
    @AppStorage(BlendStrategyID.defaultsKey) private var blendStrategy = BlendStrategyID.zone.rawValue
    /// Settings ▸ Display. The blackout keeps `ShootScreenDimmer.defaultsKey`
    /// through the 2026-09-05 rename so the wire command, the Watch mirror and
    /// `shoot.py --dim` all keep pointing at the same switch.
    @AppStorage(ShootScreenDimmer.defaultsKey) private var blackoutViewfinder = true
    @AppStorage(ShootScreenDimmer.reduceBrightnessKey) private var reduceBrightness = false
    @AppStorage(ShootScreenDimmer.peekEnabledKey) private var scheduledPeek = true
    @AppStorage(ShootScreenDimmer.peekTriggerKey)
    private var peekTrigger = ShootPeekTrigger.defaultTrigger.rawValue
    @AppStorage(ShootScreenDimmer.peekEveryMinutesKey)
    private var peekEveryMinutes = ShootPeekSchedule.defaultEveryMinutes
    /// Per-idiom default: iPhone on, iPad off — see `CreateCameraSetting`.
    @AppStorage(CreateCameraSetting.key) private var opensCameraOnCreate = CreateCameraSetting.defaultValue
    @AppStorage(RawDecodeSettings.storageKey)
    private var rawDecodePath = RawDecodePath.bradfordAdaptation.rawValue
    @AppStorage(RenderVariantRegistry.defaultsKey)
    private var renderVariant = RenderVariantRegistry.baselineID
    @State private var storage: AppModel.LibraryStorage?
    /// Room left on the volume the library lives on — the number that decides
    /// whether the next shoot fits, which the library's own total never could.
    @State private var freeBytes: Int64?
    @State private var isClearingCache = false
    @State private var isEmptyingTrash = false
    @State private var showIncompleteCaptures = false
    @State private var customFrameRateText = RecordingSettingsStore.customFrameRate.map(String.init) ?? ""
    #if os(iOS)
    @State private var showCaptureBenchmark = false
    @State private var showCaptureOpticsProbe = false
    @AppStorage(CaptureOpticsStore.enhancedLensesKey) private var enhancedLenses = true
    #endif
    #if os(macOS)
    @State private var cameraAuthorizationStatus = CameraPrivacySettings.authorizationStatus
    @State private var locationChange: StorageLocationChangeRequest?
    @State private var showRigPicker = false
    @State private var rigVersion = 0
    @State private var locationError: String?
    /// The Libraries list (libraries plan §2.3): the registry's entries with
    /// what each folder holds, read off the main thread by
    /// `refreshLibraryRows()` — never in the body, where every row would
    /// stat a volume on each redraw.
    @State private var libraryRows: [LibraryRow] = []
    @State private var renamingLibrary: LibraryRow?
    @State private var renameDraft = ""
    @State private var confirmingDisconnect = false
    /// Stage C: the account's libraries that are not on this Mac yet.
    @State private var addingFromPicPlace = false
    #endif
    #if os(iOS)
    // The phone's libraries (libraries plan L25, C2c): the folders, their
    // counts and owners, and the doors' state.
    @EnvironmentObject private var host: ModelHost
    @State private var phoneLibraries: [StorageRoot.LibraryFolder] = []
    @State private var phoneCounts: [String: Int] = [:]
    @State private var phoneOwners: [String: String] = [:]
    @State private var addingFromPicPlacePhone = false
    @State private var namingNewLibrary = false
    @State private var newLibraryName = ""
    @State private var phoneRenaming: StorageRoot.LibraryFolder?
    @State private var phoneRenameDraft = ""
    @State private var phoneRemoving: StorageRoot.LibraryFolder?
    @State private var phoneRemovalCheck: LibraryRemoval.Check?
    @State private var phoneLibraryMessage: String?
    @MainActor private static var phoneHookRan = false
    #endif

    /// The variant row's subtitle. It names the axes rather than repeating
    /// the title, because the axes are what a reader needs to reconcile a
    /// picture against `docs/render-variants/ledger.md`.
    private var renderVariantSubtitle: String {
        let variant = RenderVariantRegistry.current
        return variant.id == RenderVariantRegistry.baselineID
            ? "Rendering methodology. A is the shipping renderer; the others are field tests scored in docs/render-variants/ledger.md"
            : "\(variant.axes.summary) — a field test, not the shipping renderer"
    }

    private func scrollToRequestedAnchor(_ scroller: ScrollViewProxy) {
        guard let anchor = model.requestedSettingsAnchor else { return }
        // Twice: the tab has just been selected and the list may not have
        // laid out at the first attempt (the `LL_SCROLL` hook needs 0.5 s
        // on the Mac); the second is a no-op when the first landed.
        for delay in [0.5, 1.1] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                withAnimation(.easeInOut(duration: 0.3)) { scroller.scrollTo(anchor, anchor: .top) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
            if model.requestedSettingsAnchor == anchor { model.requestedSettingsAnchor = nil }
        }
    }

    var body: some View {
        ScrollViewReader { scroller in
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

                // What the screen does while a shoot runs — next to Recording
                // because that is what it is about, and ahead of everything
                // that is about the engine.
                LLSectionHeader("Display")
                displayCard
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

                // The libraries — which one is open, the others this device
                // holds, and the doors (libraries plan §2.3 on the Mac, L25
                // on a phone: folders under Libraries/, switched in place).
                LLSectionHeader("Libraries")
                    .id(SettingsAnchor.libraries)
                #if os(macOS)
                librariesCard
                    .padding(.bottom, 12)
                #else
                librariesCardPhone
                    .padding(.bottom, 12)
                #endif

                // Between Storage and Advanced because it is about where
                // projects live, not about the engine (picplace-sync-v1.md).
                LLSectionHeader("PicPlace")
                PicPlaceSettingsCard(picplace: model.picplace)
                    .padding(.bottom, 12)
                    .id(SettingsAnchor.picplace)

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
        #if DEBUG
        // `LL_SCROLL=picplace` lands the list on a card below the fold — how a
        // headless screenshot reaches the PICPLACE card on the Mac without a
        // scroll event, which would go to whatever window is under the point.
        .onAppear {
            guard let raw = ProcessInfo.processInfo.environment["LL_SCROLL"],
                  let anchor = SettingsAnchor(rawValue: raw) else { return }
            // Twice: the cards above the anchor change height as the storage
            // walk and the AI readiness line land, which moves a target that
            // was scrolled to early.
            for delay in [0.5, 3.0, 6.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { scroller.scrollTo(anchor, anchor: .top) }
            }
        }
        #endif
        // A card asked for from another screen (the sync panel's "All
        // PicPlace settings"): the request may predate this list, so both
        // the appearance and a later change answer it.
        .onAppear { scrollToRequestedAnchor(scroller) }
        .onChange(of: model.requestedSettingsAnchor) { _ in scrollToRequestedAnchor(scroller) }
        }
        .background(LL.screenBackground)
        .navigationDestination(for: SettingsDestination.self) { destination in
            switch destination {
            case .layout: LayoutSettingsView()
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
        #if os(macOS)
        .sheet(item: $locationChange, onDismiss: { refreshLibraryRows() }) { request in
            StorageLocationSheet(request: request)
        }
        .alert(
            "Can't use that folder",
            isPresented: Binding(get: { locationError != nil }, set: { if !$0 { locationError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(locationError ?? "")
        }
        .alert(
            "Rename library",
            isPresented: Binding(get: { renamingLibrary != nil }, set: { if !$0 { renamingLibrary = nil } })
        ) {
            TextField("Name", text: $renameDraft)
            Button("Rename") { renameLibrary() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only the library's name changes; its folder keeps its own.")
        }
        .sheet(isPresented: $addingFromPicPlace, onDismiss: { refreshLibraryRows() }) {
            AddLibraryFromPicPlaceSheet(picplace: model.picplace)
        }
        .confirmationDialog("Disconnect this library from PicPlace?", isPresented: $confirmingDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) {
                model.picplace.disconnectLibrary()
                refreshLibraryRows()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.picplace.disconnectMessage())
        }
        #endif
        .task {
            #if os(macOS)
            refreshLibraryRows()
            #endif
            #if os(macOS) && DEBUG
            // LL_STORAGE=move|adopt|create|list|moving|done|failed — stage the
            // library sheet in one state, or the Libraries list with demo
            // rows, for screenshots. Nothing on disk is touched; pair with
            // LL_TAB=settings. LL_CREATE_LIBRARY=<path>[:<name>] runs a REAL
            // create on a scratch path and stops on the relaunch screen.
            if let hook = ProcessInfo.processInfo.environment["LL_STORAGE"] {
                stageStoragePreview(hook)
            }
            if let spec = ProcessInfo.processInfo.environment["LL_CREATE_LIBRARY"] {
                let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
                createLibraryForHook(at: URL(fileURLWithPath: parts[0], isDirectory: true), name: parts.count > 1 ? parts[1] : "")
            }
            // LL_OPEN_LIBRARY=<path> — what Open Other Library… does with a
            // picked folder, without the panel: the switch sheet for a
            // library, the refusal otherwise.
            if let path = ProcessInfo.processInfo.environment["LL_OPEN_LIBRARY"] {
                handleOpenPick(URL(fileURLWithPath: path, isDirectory: true))
            }
            #endif
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
            #if os(iOS)
            LLRow(
                title: "Open Camera on Create tab",
                subtitle: "Create opens straight into the camera — at launch and whenever you switch to the tab. Off, Create is an editing home and Record starts the camera. On by default on iPhone; off on iPad"
            ) {
                Toggle("", isOn: $opensCameraOnCreate)
                    .labelsHidden()
                    .tint(.green)
            }
            #endif

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

    // MARK: - Display

    /// What the screen does while a shoot runs.
    ///
    /// **Two levers, not one dimmer with a volume knob.** On the OLED iPhones
    /// nearly all the saving is the black *cover* — black pixels are off, so
    /// once the viewfinder is covered the brightness slider is almost free. On
    /// the LCD iPads it is the reverse: the backlight burns whatever is drawn,
    /// so brightness is the only lever there and covering the preview saves
    /// almost nothing. That is why "Reduce brightness" is its own row rather
    /// than the low rung of a three-way picker — and it is also the level a
    /// lifted blackout returns *to*, which the pair could not express as one
    /// control.
    ///
    /// The last three rows are a disclosure group: a peek only means anything
    /// under a blackout. Mirrored by
    /// `docs/design/iOS/settings.display.portrait.svg`.
    private var displayCard: some View {
        VStack(spacing: 0) {
            LLRow(
                title: "Reduce brightness",
                subtitle: "Drops the panel to its lowest level for the whole shoot. On iPad, the only screen saving there is"
            ) {
                Toggle("", isOn: $reduceBrightness)
                    .labelsHidden()
                    .tint(.green)
            }

            LLRow(
                title: "Blackout viewfinder",
                subtitle: "Covers the preview with black — nearly all the thermal saving on OLED phones. Tap to peek",
                showsDivider: blackoutViewfinder
            ) {
                Toggle("", isOn: $blackoutViewfinder)
                    .labelsHidden()
                    .tint(.green)
            }

            if blackoutViewfinder {
                LLRow(
                    title: "Scheduled peek",
                    subtitle: "Lifts the blackout for \(Int(ShootPeekSchedule.peekSeconds)) seconds to show a status card — check the shoot without touching the camera",
                    showsDivider: scheduledPeek
                ) {
                    Toggle("", isOn: $scheduledPeek)
                        .labelsHidden()
                        .tint(.green)
                }

                if scheduledPeek {
                    peekTriggerRow
                    LLRow(
                        title: "Every",
                        subtitle: peekCostSubtitle,
                        showsDivider: false
                    ) {
                        Menu {
                            ForEach(ShootPeekSchedule.everyMinutesChoices, id: \.self) { minutes in
                                Button {
                                    peekEveryMinutes = minutes
                                } label: {
                                    if minutes == peekEveryMinutes {
                                        Label("\(minutes)m", systemImage: "checkmark")
                                    } else {
                                        Text("\(minutes)m")
                                    }
                                }
                            }
                        } label: {
                            menuValueLabel("\(peekEveryMinutes)m")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
            }
        }
        .llCard()
    }

    /// A segment rather than a trailing menu: neither of these is a *value*,
    /// and both words have to be legible to be chosen between — "Interval" and
    /// "Clock" mean nothing folded into a menu label.
    private var peekTriggerRow: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Trigger")
                        .font(.system(size: 16))
                    Text("Interval counts from the moment the shoot started. Clock aligns to the hour, so a whole fleet lights up together")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Picker("Trigger", selection: $peekTrigger) {
                    Text("Interval").tag(ShootPeekTrigger.interval.rawValue)
                    Text("Clock").tag(ShootPeekTrigger.clock.rawValue)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider().padding(.leading, 16)
        }
    }

    /// Prices the choice rather than describing it, the way the storage rows
    /// do: a peek is cheap, and the operator should be able to see that it is.
    private var peekCostSubtitle: String {
        let minutesLit = 120.0 / Double(peekEveryMinutes) * ShootPeekSchedule.peekSeconds / 60
        return "How often the card appears. At \(peekEveryMinutes) minutes a two-hour shoot spends about \(Int(minutesLit.rounded())) minutes with the screen lit"
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
                    showsDivider: installedLanguageModel != nil
                ) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // The engine choice as a plain preference (Auto rename & tag,
            // 2026-09-16): on, the installed language model reads the frame
            // and writes a name; off, Apple Vision tags it. One stored value
            // with the AI Models screen's picker — the toggle just says
            // "installed model or built-in" — so the two never disagree. On
            // by default once a model is present (the manager adopts the
            // download as it finishes).
            if let installed = installedLanguageModel, let builtIn = builtInModel {
                LLRow(
                    title: "Use the installed model for better results",
                    subtitle: "\(installed.name) names the scene and describes it; Apple Vision only tags it.",
                    showsDivider: false
                ) {
                    Toggle("", isOn: Binding(
                        get: { models.activeModel?.isBuiltIn == false },
                        set: { on in models.activeModelID = on ? installed.id : builtIn.id }))
                        .labelsHidden()
                        .tint(.green)
                }
            }
        }
        .llCard()
    }

    /// The language model on disk, if one is — the one the toggle above turns on.
    private var installedLanguageModel: CatalogModel? {
        models.downloadedModels.first { !$0.isBuiltIn && $0.tagsScenes }
    }

    private var builtInModel: CatalogModel? {
        models.downloadedModels.first { $0.isBuiltIn }
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
                    // On the Mac the library can live on any volume, so name
                    // the thing actually being measured.
                    #if os(macOS)
                    Text("Free at the library location")
                        .font(.system(size: 16))
                    #else
                    Text("Free on this device")
                        .font(.system(size: 16))
                    #endif
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

                // W9: deleted projects, blends and collection renders wait
                // here for 30 days (or Empty trash below) — its own line, so
                // the library figure above is explained rather than padded.
                if model.trashItemCount > 0 || (storage?.trashBytes ?? 0) > 0 {
                    Divider()
                    HStack {
                        Text("Trash")
                            .font(.system(size: 16))
                        Text(model.trashItemCount == 1 ? "1 item" : "\(model.trashItemCount) items")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(storage.map { LLFormat.bytes($0.trashBytes) } ?? "…")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
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

            if model.trashItemCount > 0 || (storage?.trashBytes ?? 0) > 0 {
                Button {
                    emptyTrash()
                } label: {
                    LLRow(
                        title: isEmptyingTrash
                            ? "Emptying…"
                            : "Empty trash\(storage.map { " (\(LLFormat.bytes($0.trashBytes)))" } ?? "")",
                        titleColor: LL.accent,
                        showsDivider: false
                    ) {
                        EmptyView()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isEmptyingTrash)
            }
        }
        .llCard()
    }

    private func emptyTrash() {
        isEmptyingTrash = true
        Task {
            await model.emptyTrash()
            await refreshFreeSpace()
            if let walked = await model.computeLibraryStorage() {
                storage = walked
            }
            isEmptyingTrash = false
        }
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

    // MARK: - Libraries (macOS)

    #if os(macOS)
    /// One known library, as the list shows it. Built off the main thread
    /// by `refreshLibraryRows()`: the registry entry plus a stat of the
    /// folder, its live project count and whose it is (the binding).
    struct LibraryRow: Identifiable, Equatable {
        var entry: LibraryRegistry.Entry
        var isCurrent: Bool
        var isReachable: Bool
        var projectCount: Int?
        /// "@regularsteven on picplace.test" when the library is bound.
        var owner: String?
        /// The identity carries only the folder's name as a placeholder
        /// (libraries plan L16): shown as unnamed, with the pencil.
        var isUnnamed = false
        var id: String { entry.path }
    }

    /// Which library is open, the others this Mac knows, and the three
    /// doors: a new one, an existing one, the current one moved. Every path
    /// out ends on the Relaunch button — a location change applies on
    /// relaunch (see `StorageRoot`), never as a silent switch.
    private var librariesCard: some View {
        VStack(spacing: 0) {
            if StorageRoot.customRootUnavailable {
                Button {
                    StorageRoot.forgetCustomPath()
                    refreshLibraryRows()
                } label: {
                    LLRow(
                        title: "Keep using the default location",
                        subtitle: "\(StorageRoot.customPath ?? "The nominated library") isn't reachable — this session runs on the default location. Forgets it; the library there isn't touched.",
                        titleColor: LL.accent
                    ) { EmptyView() }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            ForEach(libraryRows) { row in
                libraryRowView(row)
            }

            Button {
                createNewLibrary()
            } label: {
                LLRow(title: "Create New Library…", subtitle: "An empty library in a folder of your choosing. Nothing is copied.", titleColor: LL.accent) {
                    EmptyView()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.stage == .processing)

            Button {
                openOtherLibrary()
            } label: {
                LLRow(title: "Open Other Library…", subtitle: "A LetsLapse library on any drive — switches to it on relaunch.", titleColor: LL.accent) {
                    EmptyView()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.stage == .processing)

            // Stage C: a library of the account that is not on this Mac —
            // a fresh copy here, pulled on the relaunch (libraries plan §3.7).
            let remote = model.picplace.librariesNotOnThisDevice
            if !remote.isEmpty {
                Button {
                    addingFromPicPlace = true
                } label: {
                    LLRow(title: "Add Library from PicPlace…",
                          subtitle: "\(remote.count) of your libraries \(remote.count == 1 ? "is" : "are") on \(model.picplace.sessionHost) and not on this Mac: \(remote.map { "“\($0.displayName)”" }.joined(separator: ", ")).",
                          titleColor: LL.accent) {
                        EmptyView()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.stage == .processing)
            }

            Button {
                moveThisLibrary()
            } label: {
                LLRow(title: "Move This Library…", subtitle: moveSubtitle, titleColor: LL.accent, showsDivider: false) {
                    EmptyView()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Never move the floor out from under a running render.
            .disabled(model.stage == .processing || StorageRoot.customRootUnavailable)
        }
        .llCard()
    }

    private func libraryRowView(_ row: LibraryRow) -> some View {
        LLRow(title: row.entry.name, subtitle: librarySubtitle(row), titleColor: row.isUnnamed ? .secondary : .primary) {
            // The name is the person's to give (L16): a pencil on every
            // reachable row, not a context menu they have to know about.
            Button {
                renameDraft = row.isUnnamed ? "" : row.entry.name
                renamingLibrary = row
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(row.isUnnamed ? LL.accent : Color.secondary)
            .disabled(!row.isReachable)
            .help(row.isUnnamed ? "Name this library" : "Rename")
            .accessibilityLabel(row.isUnnamed ? "Name this library" : "Rename library")
            if row.isCurrent {
                // Visible, not only in the menu (Steven, 2026-09-16 evening:
                // he looked for it on the card and could not find it).
                if model.picplace.binding != nil {
                    Button("Disconnect…") { confirmingDisconnect = true }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                        .help("Stop syncing this library with PicPlace; nothing is deleted")
                }
                Text("Current")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            } else {
                Button("Switch…") { switchTo(row) }
                    .buttonStyle(.bordered)
                    .tint(.green)
                    .disabled(!row.isReachable || model.stage == .processing)
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button(row.isUnnamed ? "Name…" : "Rename…") {
                renameDraft = row.isUnnamed ? "" : row.entry.name
                renamingLibrary = row
            }
            .disabled(!row.isReachable)
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([row.entry.url])
            }
            .disabled(!row.isReachable)
            if row.isCurrent, model.picplace.binding != nil {
                Divider()
                // The rare act it is (libraries plan L14): switching never
                // does this; it is for a library leaving its account.
                Button("Disconnect from PicPlace…") { confirmingDisconnect = true }
            }
            Divider()
            Button("Remove from List") {
                LibraryRegistry.remove(path: row.entry.path)
                refreshLibraryRows()
            }
            .disabled(row.isCurrent)
        }
    }

    private func librarySubtitle(_ row: LibraryRow) -> String {
        let path = abbreviated(row.entry.path)
        guard row.isReachable else { return "\(path) — not mounted" }
        var parts = [path]
        if row.isUnnamed { parts.insert("Unnamed — the folder's name for now", at: 0) }
        if let count = row.projectCount {
            parts.append(count == 1 ? "1 project" : "\(count) projects")
        }
        if let owner = row.owner { parts.append(owner) }
        return parts.joined(separator: " · ")
    }

    private var moveSubtitle: String {
        let name = StorageRoot.identity?.displayName ?? LibraryIdentity.defaultName(forRoot: StorageRoot.current)
        // The walked originals+clips total is the honest "about" figure;
        // cache lives in temp and stays behind.
        if let storage, storage.originalsBytes + storage.versionsBytes > 0 {
            return "Copies “\(name)” — about \(LLFormat.bytes(storage.originalsBytes + storage.versionsBytes)) — to another folder. Nothing is deleted."
        }
        return "Copies “\(name)” to another folder. Nothing is deleted."
    }

    private func abbreviated(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// The list, off the main thread: a stat per entry, a directory listing
    /// for the count, the binding file. Current first, then most recently
    /// opened.
    private func refreshLibraryRows() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["LL_STORAGE"] == "list" { return }
        #endif
        let entries = LibraryRegistry.entries
        let current = StorageRoot.current.standardizedFileURL.resolvingSymlinksInPath().path
        Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            var rows: [LibraryRow] = []
            for entry in entries {
                let reachable = entry.isReachable
                var count: Int?
                var owner: String?
                if reachable {
                    let projects = entry.url.appendingPathComponent("Projects", isDirectory: true)
                    if let names = try? fileManager.contentsOfDirectory(atPath: projects.path) {
                        count = names.filter { !$0.hasPrefix(".") && UUID(uuidString: $0) != nil }.count
                    }
                    if let binding = PicPlaceBindingRecord.read(inRoot: entry.url) {
                        owner = "@\(binding.user.displayHandle) on \(binding.server.host)"
                    }
                }
                let identity = reachable ? LibraryIdentity.read(inRoot: entry.url) : nil
                rows.append(LibraryRow(
                    entry: entry,
                    isCurrent: entry.url.standardizedFileURL.resolvingSymlinksInPath().path == current,
                    isReachable: reachable, projectCount: count, owner: owner,
                    isUnnamed: identity.map { !$0.namedByPerson } ?? false))
            }
            rows.sort { a, b in
                if a.isCurrent != b.isCurrent { return a.isCurrent }
                let ta = a.entry.lastOpenedAt ?? .distantPast
                let tb = b.entry.lastOpenedAt ?? .distantPast
                if ta != tb { return ta > tb }
                return a.entry.name.localizedStandardCompare(b.entry.name) == .orderedAscending
            }
            let built = rows
            await MainActor.run { libraryRows = built }
        }
    }

    private func renameLibrary() {
        guard let row = renamingLibrary else { return }
        renamingLibrary = nil
        let name = LibraryIdentity.cleanName(renameDraft)
        guard !name.isEmpty else { return }
        do {
            if row.isCurrent {
                try StorageRoot.renameIdentity(to: name)
                model.picplace.libraryRenamed(name)
            } else if var identity = LibraryIdentity.read(inRoot: row.entry.url) {
                identity.name = name
                identity.namedByPerson = true
                try identity.write(inRoot: row.entry.url)
            } else if !LibraryIdentity.exists(inRoot: row.entry.url) {
                // A library from before the identity file: name it now.
                _ = try LibraryIdentity.ensure(inRoot: row.entry.url, name: name, device: DeviceIdentity.id)
            }
            LibraryRegistry.rename(path: row.entry.path, to: name)
        } catch {
            locationError = "Couldn't rename the library: \(error.localizedDescription)"
        }
        refreshLibraryRows()
    }

    // MARK: The three doors

    /// A Save panel, because a new library is a name and a place in one
    /// go — the folder it names is created. Nothing is copied into it.
    private func createNewLibrary() {
        let panel = NSSavePanel()
        panel.title = "Create New Library"
        panel.prompt = "Create"
        panel.nameFieldLabel = "Name:"
        panel.nameFieldStringValue = "New Library"
        panel.message = "Choose a name and a place for the new library. It starts empty — nothing is copied."
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let base = StorageRoot.defaultRootURL
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        panel.directoryURL = base
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            handleCreatePick(url)
        }
    }

    private func openOtherLibrary() {
        let panel = NSOpenPanel()
        panel.title = "Open Other Library"
        panel.prompt = "Open"
        panel.message = "Choose a folder that holds a LetsLapse library. LetsLapse relaunches to use it."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            handleOpenPick(url)
        }
    }

    private func moveThisLibrary() {
        let panel = NSOpenPanel()
        panel.title = "Move This Library"
        panel.prompt = "Move Here"
        panel.message = "Choose an empty folder. The library is copied there and LetsLapse relaunches to use it; the current copy stays until you delete it."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            handleMovePick(url)
        }
    }

    private func switchTo(_ row: LibraryRow) {
        guard row.isReachable else { return }
        locationChange = StorageLocationChangeRequest(
            mode: .adopt, destination: row.entry.url, librarySizeHint: nil, libraryName: row.entry.name)
    }

    /// `check` decides what a pick means; each door reads its outcome for
    /// its own purpose — the same folder is a refusal for one door and the
    /// right answer for another.
    private func handleCreatePick(_ url: URL) {
        switch StorageRoot.check(destination: url) {
        case .empty:
            locationChange = StorageLocationChangeRequest(
                mode: .create(name: url.lastPathComponent), destination: url, librarySizeHint: nil,
                libraryName: url.lastPathComponent)
        case .adopt(let identity):
            locationError = "That folder already holds a LetsLapse library"
                + (identity.map { " (“\($0.displayName)”)" } ?? "")
                + ". Use Open Other Library… to switch to it, or choose a new folder."
        case let other:
            locationError = refusal(other)
        }
    }

    private func handleOpenPick(_ url: URL) {
        switch StorageRoot.check(destination: url) {
        case .adopt(let identity):
            LibraryRegistry.register(root: url, identity: identity)
            locationChange = StorageLocationChangeRequest(
                mode: .adopt, destination: url, librarySizeHint: nil,
                libraryName: identity?.displayName ?? LibraryIdentity.defaultName(forRoot: url))
        case .empty:
            locationError = "There's no LetsLapse library in that folder. Use Create New Library… to start one there."
        case let other:
            locationError = refusal(other)
        }
    }

    private func handleMovePick(_ url: URL) {
        let sizeHint = storage.map { $0.originalsBytes + $0.versionsBytes }
        switch StorageRoot.check(destination: url) {
        case .empty:
            locationChange = StorageLocationChangeRequest(
                mode: .move, destination: url, librarySizeHint: sizeHint,
                libraryName: StorageRoot.identity?.displayName)
        case .adopt:
            locationError = "That folder already holds a LetsLapse library, so moving there would mix the two. "
                + "Choose an empty folder — or, to use that library instead, Open Other Library…"
        case let other:
            locationError = refusal(other)
        }
    }

    private func refusal(_ check: StorageRoot.DestinationCheck) -> String {
        switch check {
        case .alreadyCurrent:
            return "That's the library you're using now."
        case .insideCurrent:
            return "That folder is inside the current library. Choose one outside it."
        case .containsLibrary(let inside):
            return "That folder contains a LetsLapse library (\(inside)). Choose the library's own folder, or one that holds no library."
        case .notWritable:
            return "LetsLapse can't write there. Check the drive isn't read-only and try again."
        case .collision(let name):
            return "That folder already contains “\(name)” without being a LetsLapse library, so using it would mix the two. "
                + "Choose an empty folder — or, if a previous move was interrupted, delete its leftovers there first."
        case .adopt, .empty:
            return "That folder can't be used here."
        }
    }

    #if DEBUG
    /// LL_STORAGE — stage the library sheet or the list for screenshots, no
    /// disk touched.
    private func stageStoragePreview(_ hook: String) {
        if hook == "list" {
            let play = NSHomeDirectory() + "/Library/Application Support/LetsLapse/picplace.test/regularsteven"
            libraryRows = [
                LibraryRow(
                    entry: .init(libraryID: StorageRoot.identity?.id, path: StorageRoot.current.path,
                                 name: StorageRoot.identity?.displayName ?? "letslapse", lastOpenedAt: Date()),
                    isCurrent: true, isReachable: true, projectCount: 365, owner: nil),
                LibraryRow(
                    entry: .init(libraryID: UUID(), path: play, name: "regularsteven", lastOpenedAt: Date().addingTimeInterval(-86_400)),
                    isCurrent: false, isReachable: true, projectCount: 12, owner: "@regularsteven on picplace.test"),
                LibraryRow(
                    entry: .init(libraryID: UUID(), path: "/Volumes/Field/Field 2026", name: "Field 2026", lastOpenedAt: nil),
                    isCurrent: false, isReachable: false, projectCount: nil, owner: nil),
            ]
            return
        }
        var staged: StorageMover.Phase?
        switch hook {
        case "moving":
            staged = .copying(
                copiedBytes: 96_500_000_000, totalBytes: 148_200_000_000,
                itemName: "IMG_0412.dng")
        case "done":
            staged = .done
        case "failed":
            staged = .failed(
                "Not enough space there. The library is 148.2 GB and only 96.5 GB is free at "
                    + "that location.")
        default:
            break
        }
        let mode: StorageLocationChangeRequest.Mode
        switch hook {
        case "adopt": mode = .adopt
        case "create": mode = .create(name: "Field 2026")
        default: mode = .move
        }
        locationChange = StorageLocationChangeRequest(
            mode: mode,
            destination: URL(fileURLWithPath: hook == "create" ? "/Volumes/Field/Field 2026" : "/Volumes/letslapse"),
            librarySizeHint: 148_200_000_000,
            libraryName: hook == "create" ? "Field 2026" : (hook == "adopt" ? "letslapse" : StorageRoot.identity?.displayName),
            stagedPhase: staged)
    }

    /// LL_CREATE_LIBRARY — the real engine on a scratch path, then the
    /// sheet on its relaunch screen (the relaunch itself is the person's).
    private func createLibraryForHook(at url: URL, name: String) {
        guard case .empty = StorageRoot.check(destination: url) else {
            LLog("storage: LL_CREATE_LIBRARY refused — \(url.path) is not empty or not writable")
            return
        }
        let libraryName = name.isEmpty ? url.lastPathComponent : name
        do {
            try StorageRoot.create(at: url, name: libraryName)
            // As the sheet's button does (libraries plan L15): straight on.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { AppRelaunch.relaunchNow() }
        } catch {
            LLog("storage: LL_CREATE_LIBRARY failed — \(error)")
        }
    }
    #endif
    #endif

    // MARK: - Advanced

    #if os(macOS)
    private var rigSubtitle: String {
        _ = rigVersion
        let a = ExternalShapeDetector.availability
        return a.ok ? "Runs the benchmark's Python detectors from \(a.detail)" : a.detail + " — the repository's LetsLapse/tools, with its .venv"
    }
    #endif

    private var advancedCard: some View {
        VStack(spacing: 0) {
            NavigationLink(value: SettingsDestination.layout) {
                LLRow(title: "Layout", subtitle: "Which tabs, filters and editor controls the app shows") {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            #if os(macOS)
            // The shape benchmark rig (tools/shapebench, Python) — what the
            // Find shapes sheet's and the Masks tab's "Python" detectors run.
            LLRow(title: "Shape detectors (Python rig)", subtitle: rigSubtitle) {
                Button("Choose…") { showRigPicker = true }
                    .buttonStyle(.bordered)
            }
            .fileImporter(isPresented: $showRigPicker, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    UserDefaults.standard.set(url.path, forKey: ExternalShapeDetector.rigFolderKey)
                    rigVersion += 1
                }
            }
            #endif

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

            // A separate grant from the camera remote above on purpose:
            // driving this device's shutter and reading every project on it
            // are different things to hand a stranger on the network. The
            // subtitle says the part that matters — the code is not
            // per-project. Not iOS-only: a Mac serves its library the same way
            // (Phase 3), which is how a project gets from here to an iPad.
            LLRow(
                title: "Share projects with nearby devices",
                subtitle: "Shows a pairing code in Projects so another device on the same network can copy projects from here. Anyone with the code can copy every project on this device"
            ) {
                Toggle("", isOn: $allowLibrarySharing)
                    .labelsHidden()
                    .tint(.green)
            }

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

            // Field test, like the blend-strategy row above it: four ways to
            // get a DNG into the grade engine, so they can be compared on real
            // frames. Every case is listed — one that this machine cannot run
            // is labelled with the reason rather than hidden, because a
            // comparison that silently drops an option reads as a bug.
            //
            // "Adobe DCP" is the one that can be unavailable: its profiles
            // ship with Lightroom rather than with this app, so the row is
            // live on a Mac that has them and greyed everywhere else. It is
            // also the only path that changes an untouched render — the other
            // three differ solely in how they realise a temperature move.
            // Render variants — several rendering methodologies in one build.
            // Above the decode-path row on purpose: a variant PINS the decode
            // path, so the row below it is a subset of this one and reads as
            // a contradiction if it comes first.
            LLRow(
                title: "Render variant",
                subtitle: renderVariantSubtitle
            ) {
                Menu {
                    ForEach(RenderVariantRegistry.appSelectable, id: \.id) { variant in
                        Button {
                            RenderVariantRegistry.current = variant
                            renderVariant = variant.id
                        } label: {
                            if variant.id == renderVariant {
                                Label("\(variant.id) · \(variant.title)", systemImage: "checkmark")
                            } else {
                                Text("\(variant.id) · \(variant.title)")
                            }
                        }
                    }
                    // Bench-only variants are LISTED and disabled rather than
                    // hidden: they are in the ledger, somebody will look for
                    // them here, and the reason is more useful than a gap.
                    let benchOnly = RenderVariantRegistry.available
                        .filter { $0.axes.needsSidecar }
                    if !benchOnly.isEmpty {
                        Divider()
                        Section("Bench only — needs a Lightroom sidecar") {
                            ForEach(benchOnly, id: \.id) { variant in
                                Button("\(variant.id) · \(variant.title)") {}.disabled(true)
                            }
                        }
                    }
                } label: {
                    menuValueLabel(RenderVariantRegistry.current.id)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            LLRow(
                title: "Raw decode path",
                subtitle: "Field test: how a DNG is rendered before grading. Changing this re-renders every preview. The render variant above pins this — it only applies on variant \(RenderVariantRegistry.baselineID)"
            ) {
                Menu {
                    ForEach(RawDecodeSettings.allPaths, id: \.rawValue) { path in
                        Button {
                            RawDecodePath.current = path
                            rawDecodePath = path.rawValue
                        } label: {
                            if path.rawValue == rawDecodePath {
                                Label(RawDecodeSettings.label(for: path), systemImage: "checkmark")
                            } else {
                                Text(RawDecodeSettings.label(for: path))
                            }
                        }
                        .disabled(!RawDecodePathRegistry.isAvailable(path))
                    }
                } label: {
                    menuValueLabel(RenderVariantRegistry.current.axes.decodePath.displayName)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(RenderVariantRegistry.current.id != RenderVariantRegistry.baselineID)
            }

            NavigationLink(value: SettingsDestination.performance) {
                LLRow(title: "Performance", subtitle: "Capture stream rate, CPU workers, GPU batches") {
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

    /// The index's size order first (measured sizes), refined by the walks
    /// this screen does as they land (M3).
    private var sorted: [AppModel.CaptureProject] {
        model.liveCaptures({ var q = LibraryIndex.ProjectQuery(); q.sort = .size; return q }())
            .sorted { (sizes[$0.id] ?? 0) > (sizes[$1.id] ?? 0) }
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
            for capture in model.liveCaptures() {
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

// MARK: - Layout

/// What the shell shows. Everything here is about where things are listed, not
/// about what the engine does with them — which is why the Scans switch turns a
/// tab into a filter rather than turning scanning off, and the pads switch
/// changes the Editor's controls without changing what they control.
private struct LayoutSettingsView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(LayoutSettings.scansMenuKey) private var scansMenuEnabled = true
    @AppStorage(LayoutSettings.projectCountsKey) private var showsCounts = false
    @AppStorage(LayoutSettings.editorPadsKey) private var usesPads = true

    var body: some View {
        Form {
            Section {
                Toggle("Enable Scans menu", isOn: $scansMenuEnabled)
            } footer: {
                Text(scansFooter)
            }

            Section {
                Toggle("Display count in Projects", isOn: $showsCounts)
            } footer: {
                Text("Spells out how many projects each filter holds — “All 292”, “Photos 18”. The counts follow the search, so they always match what tapping a filter shows.")
            }

            // Board 6d: the row carries its own subtitle, the section its
            // footer — the copy verbatim.
            Section {
                Toggle(isOn: $usesPads) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use Pads in Editor")
                        Text("Paired adjustments share an XY pad. Off shows plain sliders.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("Applies to the Editor on iPhone, iPad and Mac. Grouping, presets and the timeline are unchanged either way.")
            }
        }
        .navigationTitle("Layout")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// Says which of the two halves of the rule is currently keeping the tab
    /// off screen — the setting, or an empty library — because "on but not
    /// showing" is otherwise indistinguishable from a bug.
    private var scansFooter: String {
        guard scansMenuEnabled else {
            return "Scans are listed in Projects instead, behind their own filter between Photos and Interval."
        }
        return model.hasScanSessions
            ? "The Scans tab is in the tab bar. Turn this off to list scans in Projects instead, behind their own filter."
            : "The Scans tab appears in the tab bar as soon as you have a scan. Turn this off to list scans in Projects instead, behind their own filter."
    }
}

private struct PerformanceSettingsView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(StreamRatePolicy.defaultsKey) private var streamRateRaw = StreamRatePolicy.auto.rawValue
    @AppStorage(StreamRateLearning.learnedReducedKey) private var streamRateLearnedReduced = false
    @AppStorage(StreamRateLearning.engagedRunsKey) private var streamRateEngagedRuns = 0

    private var streamRate: Binding<StreamRatePolicy> {
        Binding(
            get: { StreamRatePolicy(rawValue: streamRateRaw) ?? .auto },
            set: { policy in
                // Choosing Auto again is the reset: the device gets to prove
                // it needs the throttle over fresh runs. Off (Full) or
                // Reduced by hand overrides whatever was learned.
                if policy == .auto, streamRateRaw != StreamRatePolicy.auto.rawValue {
                    StreamRateLearning.reset()
                }
                streamRateRaw = policy.rawValue
            })
    }

    var body: some View {
        Form {
            #if !os(macOS)
            Section {
                Picker("Capture stream rate", selection: streamRate) {
                    ForEach(StreamRatePolicy.allCases) { policy in
                        Text(policy.label).tag(policy)
                    }
                }
                if streamRate.wrappedValue == .auto, streamRateLearnedReduced {
                    LLRow(title: "Reduced on this device",
                          subtitle: "Auto needed the throttle on \(max(streamRateEngagedRuns, StreamRateLearning.runsToLearn)) shoots, so runs now start reduced. Choose Auto again to reset.") {
                        EmptyView()
                    }
                }
            } footer: {
                Text(streamRateFooter)
            }
            #endif

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

    /// One sentence per choice, and the cost named: the preview shares the
    /// stream, the pixels do not change.
    private var streamRateFooter: String {
        switch streamRate.wrappedValue {
        case .auto:
            return "How fast the camera streams while a blend runs — the main thermal lever. Auto keeps the full rate while the camera is cool and streams only what the blend needs once it reports serious pressure, then returns to full as it cools. A device that keeps needing it starts reduced. The preview slows with the stream; the frames do not change."
        case .reduced:
            return "Streams only what the blend needs from the first frame, with headroom for dropped frames. Coolest option; the preview runs at a few frames per second during the shoot. The frames do not change."
        case .full:
            return "Never throttles the stream. Warmest option — on an iPhone 12 Pro this reached thermal critical, where the lens stabiliser parks and the framing jumps, in 12–16 minutes. A shoot that reaches critical still ends there, cleanly."
        }
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

// MARK: - A library from PicPlace (macOS, stage C)

#if os(macOS)

/// "Add Library from PicPlace": one of the account's libraries that is not
/// on this Mac becomes a local copy — folder, identity, binding pending
/// its first pull — and LetsLapse relaunches on it to pull the previews
/// (libraries plan §3.7). The place is chosen once; the app names the
/// folder inside it (`<host>/<username>/<name>/` when free).
struct AddLibraryFromPicPlaceSheet: View {
    @ObservedObject var picplace: PicPlaceController
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: PPLibrary?
    @State private var container = StorageRoot.defaultRootURL
    @State private var failure: String?

    private var remote: [PPLibrary] { picplace.librariesNotOnThisDevice }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add a library from PicPlace")
                .font(.system(size: 19, weight: .semibold))
                .padding(.top, 26)
            Text("A copy of the library is made here — its projects arrive as previews; originals download per project. LetsLapse relaunches on it.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)

            VStack(spacing: 0) {
                ForEach(remote) { library in
                    Button {
                        chosen = library
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: chosen?.id == library.id ? "largecircle.fill.circle" : "circle")
                                .font(.system(size: 16))
                                .foregroundStyle(chosen?.id == library.id ? LL.accent : Color.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(library.displayName).font(.system(size: 14.5, weight: chosen?.id == library.id ? .semibold : .regular))
                                Text("\(library.count) project\(library.count == 1 ? "" : "s") · \(LLFormat.bytes(library.usedBytes ?? 0)) on PicPlace")
                                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if library.id != remote.last?.id { Divider().padding(.leading, 44) }
                }
            }
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.top, 16)

            HStack(spacing: 10) {
                Text("Place")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text(shownPath(container.path))
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Choose…") { choosePlace() }
                    .buttonStyle(.bordered)
            }
            .padding(.top, 14)

            if let failure {
                Text(failure).font(.system(size: 12.5)).foregroundStyle(LL.levelOff).padding(.top, 8)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(LLSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Add and Relaunch") { add() }
                    .buttonStyle(LLPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen == nil)
            }
            .padding(.top, 20)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .frame(width: 460)
        .background(LL.screenBackground)
        .onAppear { if chosen == nil { chosen = remote.first } }
    }

    private func choosePlace() {
        let panel = NSOpenPanel()
        panel.title = "Where the library goes"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = container
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            container = url
        }
    }

    private func add() {
        guard let chosen else { return }
        do {
            let root = try picplace.addLibraryFromPicPlace(chosen, in: container)
            StorageRoot.commit(destination: root)
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { AppRelaunch.relaunchNow() }
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func shownPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

#endif

// MARK: - Library location (macOS)

#if os(macOS)

/// What Settings decided a picked folder means, handed to the sheet. Built
/// only after `StorageRoot.check` cleared the pick, so the sheet never has to
/// re-litigate whether the destination is usable.
struct StorageLocationChangeRequest: Identifiable {
    enum Mode: Equatable {
        /// Copy the library into the folder, then relaunch.
        case move
        /// The folder already holds a library — switch to it, no copying.
        case adopt
        /// Start a new, empty library in the folder (libraries plan §3.1),
        /// then relaunch. Nothing is copied.
        case create(name: String)
    }

    let id = UUID()
    let mode: Mode
    let destination: URL
    /// Settings' walked total when it had one — the confirm screen's "about"
    /// figure. The mover measures exactly before copying regardless.
    let librarySizeHint: Int64?
    /// The library's name for the copy — the one being switched to, created,
    /// or moved. nil for a folder whose library has no identity yet.
    var libraryName: String?
    /// LL_STORAGE screenshot hook only: open with the mover pre-staged.
    var stagedPhase: StorageMover.Phase?
}

/// Blocking, like the import sheet and for the same reason: the copy owns the
/// disk for minutes. Every exit is explicit — Cancel cleans up after itself,
/// and both finished states end on Relaunch because the new location only
/// takes effect on the next launch (see `StorageRoot`).
struct StorageLocationSheet: View {
    let request: StorageLocationChangeRequest

    @Environment(\.dismiss) private var dismiss
    @StateObject private var mover = StorageMover()
    /// Adopt and create commit without copying — straight to the relaunch screen.
    @State private var committed = false
    /// A create that failed (the mover has no part in it).
    @State private var createFailure: String?

    private var showsRelaunch: Bool { committed || mover.phase == .done }

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: icon)
                .font(.system(size: 30))
                .foregroundStyle(isFailure ? Color.red : LL.accent)
                .padding(.top, 30)

            Text(title)
                .font(.system(size: 19, weight: .semibold))
                .padding(.top, 14)

            Text(shownPath(request.destination.path))
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .padding(.top, 3)
                .padding(.horizontal, 24)

            middle

            Spacer(minLength: 20)

            buttons
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .frame(width: 380)
        .frame(minHeight: 320)
        .background(LL.screenBackground)
        .interactiveDismissDisabled()
        .onAppear {
            #if DEBUG
            if let staged = request.stagedPhase {
                mover.stagePreview(staged)
            }
            #endif
        }
    }

    // MARK: - States

    @ViewBuilder
    private var middle: some View {
        if showsRelaunch {
            prose(relaunchProse)
        } else if let createFailure {
            prose(createFailure)
        } else {
            switch mover.phase {
            case .idle:
                prose(confirmProse)
            case .preparing:
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(LL.accent)
                    .padding(.top, 22)
                    .padding(.horizontal, 24)
                caption("Sizing up the library…")
            case .copying(let copied, let total, let item):
                bar(copied: copied, total: total)
                    .padding(.top, 22)
                    .padding(.horizontal, 24)
                caption("\(LLFormat.bytes(copied)) of \(LLFormat.bytes(total))")
                if !item.isEmpty {
                    Text(item)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.top, 3)
                        .padding(.horizontal, 24)
                }
            case .failed(let reason):
                prose(reason)
            case .done:
                // `showsRelaunch` owns this state.
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        if showsRelaunch {
            VStack(spacing: 10) {
                Button("Relaunch LetsLapse") {
                    // The sheet closes and terminate lands on the next turn
                    // (reproduced 2026-08-25 — sent during the presentation
                    // it was swallowed); relaunchNow carries a hard-exit
                    // fallback for anything else that swallows it.
                    relaunch()
                }
                .buttonStyle(LLPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                Button("Not Yet") { dismiss() }
                    .buttonStyle(LLSecondaryButtonStyle())
            }
        } else if createFailure != nil {
            Button("Close") { dismiss() }
                .buttonStyle(LLPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
        } else {
            switch mover.phase {
            case .idle:
                VStack(spacing: 10) {
                    Button(primaryTitle) {
                        switch request.mode {
                        case .move:
                            mover.begin(destination: request.destination)
                        case .adopt:
                            // Switch and create relaunch from here (libraries
                            // plan L15): the confirm already said so, and a
                            // second screen repeating it was a wasted one.
                            // Only a move — minutes of copying — keeps its
                            // done screen.
                            LibraryRegistry.register(root: request.destination, identity: LibraryIdentity.read(inRoot: request.destination))
                            StorageRoot.commit(destination: request.destination)
                            LLog("storage: switching to the library at \(request.destination.path) — relaunching")
                            relaunch()
                        case .create(let name):
                            do {
                                try StorageRoot.create(at: request.destination, name: name)
                                relaunch()
                            } catch {
                                createFailure = "Couldn't create the library: \(error.localizedDescription)"
                            }
                        }
                    }
                    .buttonStyle(LLPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)

                    Button("Cancel") { dismiss() }
                        .buttonStyle(LLSecondaryButtonStyle())
                        .keyboardShortcut(.cancelAction)
                }
            case .preparing, .copying:
                Button("Cancel") {
                    mover.cancel()
                    dismiss()
                }
                .buttonStyle(LLSecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
            case .failed:
                Button("Close") { dismiss() }
                    .buttonStyle(LLPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            case .done:
                EmptyView()
            }
        }
    }

    /// Dismiss BEFORE terminating: NSApp.terminate sent while the sheet is
    /// still presented is silently swallowed (reproduced 2026-08-25).
    private func relaunch() {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            AppRelaunch.relaunchNow()
        }
    }

    // MARK: - Copy

    private var isFailure: Bool {
        if createFailure != nil { return true }
        if case .failed = mover.phase { return true }
        return false
    }

    private var icon: String {
        if isFailure { return "exclamationmark.triangle.fill" }
        if showsRelaunch { return "externaldrive.fill.badge.checkmark" }
        if case .create = request.mode { return "externaldrive.fill.badge.plus" }
        return "externaldrive.fill"
    }

    private var quotedName: String? {
        request.libraryName.map { "“\($0)”" }
    }

    private var primaryTitle: String {
        switch request.mode {
        case .move: return "Move Library"
        case .adopt: return "Switch and Relaunch"
        case .create: return "Create and Relaunch"
        }
    }

    private var title: String {
        if showsRelaunch { return "Relaunch to finish" }
        if createFailure != nil { return "Couldn't create the library" }
        switch mover.phase {
        case .idle:
            switch request.mode {
            case .move: return "Move library?"
            case .adopt: return quotedName.map { "Switch to \($0)?" } ?? "Use this library?"
            case .create: return "Create library?"
            }
        case .preparing, .copying:
            return "Moving library"
        case .failed:
            return "Couldn't move the library"
        case .done:
            return "Relaunch to finish"
        }
    }

    private var confirmProse: String {
        let from = shownPath(StorageRoot.current.path)
        switch request.mode {
        case .move:
            let size = request.librarySizeHint.map { "about \(LLFormat.bytes($0)) of " } ?? ""
            return "Your library — \(size)projects, thumbnails and capture logs — is copied to "
                + "this folder, and LetsLapse relaunches to use it there. Nothing is deleted: the "
                + "current copy stays at \(from) until you remove it yourself in Finder."
        case .adopt:
            if let quotedName {
                return "LetsLapse relaunches on \(quotedName) now. Nothing is copied or moved: the "
                    + "library you're using now stays at \(from), unchanged, and is still in the list."
            }
            return "This folder already holds a LetsLapse library, and LetsLapse switches to it "
                + "on relaunch. It may not match the library you're using now. The current one "
                + "stays at \(from), unchanged — to move it instead, clear the old library out of "
                + "this folder first."
        case .create(let name):
            return "A new, empty library named “\(name)” is made in this folder, and LetsLapse "
                + "relaunches on it now. Nothing is copied: the library you're using now stays at "
                + "\(from), unchanged, and is still in the list."
        }
    }

    /// Only a move reaches this screen (L15).
    private var relaunchProse: String {
        "The library has been copied. Until the relaunch, anything new still lands at "
            + "the previous location — relaunch now, and delete the old copy in Finder once "
            + "you've checked the new one."
    }

    private func shownPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private func prose(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 16)
            .padding(.horizontal, 12)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5).monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.top, 8)
    }

    /// Drawn rather than `ProgressView(value:)` for the same reason the import
    /// sheet draws its own: the system linear bar fills in control grey on
    /// macOS whatever the tint says.
    private func bar(copied: Int64, total: Int64) -> some View {
        let fraction = total > 0 ? Double(copied) / Double(total) : 0
        return GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(LL.accent)
                    .frame(width: max(0, geometry.size.width * fraction))
            }
        }
        .frame(height: 6)
        .animation(.easeOut(duration: 0.25), value: fraction)
    }
}

#endif

#if os(iOS)
// MARK: - The phone's libraries (libraries plan L25, C2c)

extension SettingsView {
    /// Which library is open, the others on this phone, and the doors: a
    /// library of the account added from PicPlace, a new one made there,
    /// and — on a row — rename, or remove from this device. A switch is a
    /// new model over the other folder, in place (L22).
    var librariesCardPhone: some View {
        VStack(spacing: 0) {
            ForEach(phoneLibraries) { folder in
                LLRow(title: folder.name, subtitle: phoneLibrarySubtitle(folder),
                      titleColor: folder.identity?.namedByPerson == false ? .secondary : .primary) {
                    if folder.isCurrent {
                        Text("Current").font(.system(size: 15)).foregroundStyle(.secondary)
                    } else {
                        Button("Switch") { switchPhoneLibrary(to: folder) }
                            .buttonStyle(.bordered)
                            .disabled(model.stage == .processing)
                    }
                }
                .contentShape(Rectangle())
                .contextMenu {
                    Button {
                        phoneRenameDraft = folder.identity?.namedByPerson == false ? "" : folder.name
                        phoneRenaming = folder
                    } label: { Label(folder.identity?.namedByPerson == false ? "Name this library…" : "Rename…", systemImage: "pencil") }
                    if !folder.isCurrent {
                        Button(role: .destructive) { askToRemove(folder) } label: {
                            Label("Remove from \(PicPlaceController.deviceWord)…", systemImage: "trash")
                        }
                    }
                }
            }

            let remote = model.picplace.librariesNotOnThisDevice
            if !remote.isEmpty {
                Button { addingFromPicPlacePhone = true } label: {
                    LLRow(title: "Add Library from PicPlace…",
                          subtitle: "\(remote.count) of your libraries \(remote.count == 1 ? "is" : "are") on \(model.picplace.sessionHost) and not on \(PicPlaceController.deviceWord): \(remote.map { "“\($0.displayName)”" }.joined(separator: ", ")).",
                          titleColor: LL.accent) { EmptyView() }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.stage == .processing)
            }

            if model.picplace.isSignedIn, model.picplace.serverHasLibraries {
                Button { newLibraryName = ""; namingNewLibrary = true } label: {
                    LLRow(title: "New Library on PicPlace…",
                          subtitle: "An empty library on \(model.picplace.sessionHost) as @\(model.picplace.profile?.username ?? ""); \(PicPlaceController.deviceWord) opens it. Nothing is copied.",
                          titleColor: LL.accent, showsDivider: false) { EmptyView() }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.stage == .processing)
            } else if phoneLibraries.count <= 1 {
                LLRow(title: "One library on \(PicPlaceController.deviceWord)",
                      subtitle: "Sign in with PicPlace to add your other libraries here or start a new one.",
                      titleColor: .secondary, showsDivider: false) { EmptyView() }
            }
        }
        .llCard()
        .task {
            refreshPhoneLibraries()
            #if DEBUG
            await runPhoneLibraryHook()
            #endif
        }
        .onReceive(model.picplace.objectWillChange) { _ in refreshPhoneLibraries() }
        .sheet(isPresented: $addingFromPicPlacePhone) {
            AddLibraryFromPicPlacePhoneSheet(picplace: model.picplace) { folder in switchPhoneLibrary(to: folder) }
        }
        .alert("New library on PicPlace", isPresented: $namingNewLibrary) {
            TextField("Library name", text: $newLibraryName)
            Button("Create") { Task { await createLibraryOnPicPlace() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("An empty library named on PicPlace; \(PicPlaceController.deviceWord) opens it and captures land in it.")
        }
        .alert(phoneRenaming?.identity?.namedByPerson == false ? "Name this library" : "Rename library",
               isPresented: Binding(get: { phoneRenaming != nil }, set: { if !$0 { phoneRenaming = nil } })) {
            TextField("Library name", text: $phoneRenameDraft)
            Button("Save") { renamePhoneLibrary() }
            Button("Cancel", role: .cancel) { phoneRenaming = nil }
        }
        .confirmationDialog("Remove “\(phoneRemoving?.name ?? "")” from \(PicPlaceController.deviceWord)?",
                            isPresented: Binding(get: { phoneRemoving != nil }, set: { if !$0 { phoneRemoving = nil } }),
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) { if let folder = phoneRemoving { removePhoneLibrary(folder) } }
            Button("Cancel", role: .cancel) { phoneRemoving = nil }
        } message: {
            Text(removalMessage)
        }
        .alert("Libraries", isPresented: Binding(get: { phoneLibraryMessage != nil }, set: { if !$0 { phoneLibraryMessage = nil } })) {
            Button("OK", role: .cancel) { phoneLibraryMessage = nil }
        } message: {
            Text(phoneLibraryMessage ?? "")
        }
    }

    private func phoneLibrarySubtitle(_ folder: StorageRoot.LibraryFolder) -> String {
        var parts: [String] = []
        if let count = phoneCounts[folder.id] { parts.append("\(count) project\(count == 1 ? "" : "s")") }
        parts.append(phoneOwners[folder.id] ?? "not on PicPlace")
        return parts.joined(separator: " · ")
    }

    private var removalMessage: String {
        guard let check = phoneRemovalCheck else { return "" }
        let previews = check.projects - check.originalsHere
        var parts: [String] = []
        if check.projects == 0 { parts.append("It is empty.") }
        if previews > 0 { parts.append("\(previews) preview\(previews == 1 ? "" : "s") go\(previews == 1 ? "es" : "").") }
        if check.originalsHere > 0 { parts.append("\(check.originalsHere) project\(check.originalsHere == 1 ? "'s" : "s'") originals here go — PicPlace holds them.") }
        parts.append(check.bound ? "The library stays on PicPlace and on your other devices." : "Nothing is on PicPlace for it.")
        return parts.joined(separator: " ")
    }

    /// The folders, their project counts (a listing of `Projects/`) and
    /// owners, off the main actor.
    func refreshPhoneLibraries() {
        let folders = StorageRoot.libraryFolders()
        Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            var counts: [String: Int] = [:]
            var owners: [String: String] = [:]
            for folder in folders {
                let projects = folder.url.appendingPathComponent("Projects", isDirectory: true)
                if let names = try? fileManager.contentsOfDirectory(atPath: projects.path) {
                    counts[folder.id] = names.filter { !$0.hasPrefix(".") && UUID(uuidString: $0) != nil }.count
                }
                if let binding = PicPlaceBindingRecord.read(inRoot: folder.url) {
                    owners[folder.id] = "@\(binding.user.displayHandle) on \(binding.server.host)"
                }
            }
            let sorted = folders.sorted { a, b in
                if a.isCurrent != b.isCurrent { return a.isCurrent }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            await MainActor.run {
                phoneLibraries = sorted
                phoneCounts = counts
                phoneOwners = owners
            }
        }
    }

    private func switchPhoneLibrary(to folder: StorageRoot.LibraryFolder) {
        host.landingTab = .settings
        if !host.switchLibrary(to: folder) { phoneLibraryMessage = host.lastRefusal }
    }

    private func createLibraryOnPicPlace() async {
        let name = newLibraryName
        do {
            let folder = try await model.picplace.createLibraryOnPicPlace(name: name)
            switchPhoneLibrary(to: folder)
        } catch {
            phoneLibraryMessage = (error as? PicPlaceAPIError)?.cardCaption ?? (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func renamePhoneLibrary() {
        guard let folder = phoneRenaming else { return }
        phoneRenaming = nil
        let name = LibraryIdentity.cleanName(phoneRenameDraft)
        guard !name.isEmpty else { return }
        do {
            if folder.isCurrent {
                try StorageRoot.renameIdentity(to: name)
                model.picplace.libraryRenamed(name)
            } else if var identity = folder.identity {
                identity.name = name
                identity.namedByPerson = true
                try identity.write(inRoot: folder.url)
            } else {
                _ = try LibraryIdentity.ensure(inRoot: folder.url, name: name, device: DeviceIdentity.id)
            }
        } catch {
            phoneLibraryMessage = "Couldn't rename the library: \(error.localizedDescription)"
        }
        refreshPhoneLibraries()
    }

    /// The check first, off the main actor — a big library is many folders
    /// — then the confirm with its numbers, or the refusal naming what
    /// exists only here.
    private func askToRemove(_ folder: StorageRoot.LibraryFolder) {
        Task.detached(priority: .userInitiated) {
            let check = LibraryRemoval.check(for: folder.url)
            await MainActor.run {
                if check.onlyHere.isEmpty {
                    phoneRemovalCheck = check
                    phoneRemoving = folder
                } else {
                    let names = check.onlyHere.prefix(5).map { "“\($0)”" }.joined(separator: ", ")
                    phoneLibraryMessage = "\(check.onlyHere.count) project\(check.onlyHere.count == 1 ? "" : "s") in “\(folder.name)” exist\(check.onlyHere.count == 1 ? "s" : "") only on \(PicPlaceController.deviceWord): \(names)\(check.onlyHere.count > 5 ? ", …" : ""). Upload the originals first, or keep the library."
                    LLog("storage: remove of \(folder.id) refused — \(check.onlyHere.count) project(s) exist only here")
                }
            }
        }
    }

    private func removePhoneLibrary(_ folder: StorageRoot.LibraryFolder) {
        phoneRemoving = nil
        do {
            try StorageRoot.removeLibraryFolder(folder)
        } catch {
            phoneLibraryMessage = "Couldn't remove the library: \(error.localizedDescription)"
        }
        refreshPhoneLibraries()
    }

    #if DEBUG
    /// `LL_LIBRARY=switch:<id>|add:<server uuid>|new:<name>|remove:<id>|rename:<id>:<name>`
    /// — the doors without a finger (the bench); waits for the session when
    /// PicPlace is needed. Once per process.
    private func runPhoneLibraryHook() async {
        guard let raw = ProcessInfo.processInfo.environment["LL_LIBRARY"], !Self.phoneHookRan else { return }
        Self.phoneHookRan = true
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        let parts = raw.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return }
        func folder(_ id: String) -> StorageRoot.LibraryFolder? { StorageRoot.libraryFolders().first { $0.id == id } }
        func awaitSession() async -> Bool {
            for _ in 0..<60 where !(model.picplace.isSignedIn && model.picplace.serverHasLibraries) { try? await Task.sleep(nanoseconds: 500_000_000) }
            return model.picplace.isSignedIn && model.picplace.serverHasLibraries
        }
        switch parts[0] {
        case "switch":
            if let target = folder(parts[1]) { switchPhoneLibrary(to: target) } else { LLog("libraries hook: no folder \(parts[1])") }
        case "add":
            guard await awaitSession() else { LLog("libraries hook: no session"); return }
            if let library = model.picplace.librariesNotOnThisDevice.first(where: { $0.libraryUUID?.uuidString.lowercased() == parts[1].lowercased() }) {
                do { let made = try model.picplace.addLibraryFromPicPlace(library); switchPhoneLibrary(to: made) }
                catch { LLog("libraries hook: add failed — \(error)") }
            } else { LLog("libraries hook: \(parts[1]) is not a library of the account that is missing here") }
        case "new":
            guard await awaitSession() else { LLog("libraries hook: no session"); return }
            newLibraryName = parts[1]
            await createLibraryOnPicPlace()
        case "remove":
            if let target = folder(parts[1]) {
                let check = LibraryRemoval.check(for: target.url)
                LLog("libraries hook: remove check for \(target.id) — \(check.projects) project(s), \(check.originalsHere) with originals here, \(check.onlyHere.count) only here")
                if check.onlyHere.isEmpty { removePhoneLibrary(target) } else { LLog("libraries hook: remove refused — only here: \(check.onlyHere)") }
            }
        case "rename":
            if parts.count == 3, let target = folder(parts[1]) { phoneRenameDraft = parts[2]; phoneRenaming = target; renamePhoneLibrary() }
        default:
            LLog("libraries hook: unknown action \(parts[0])")
        }
    }
    #endif
}

/// What Remove from this iPhone would take, read off the folder without
/// opening the library (L25): how many projects, how many with originals
/// here, and the names of those whose originals exist only here — no
/// record says PicPlace holds them.
enum LibraryRemoval {
    struct Check {
        var projects = 0
        var originalsHere = 0
        var onlyHere: [String] = []
        var bound = false
    }

    static func check(for root: URL) -> Check {
        var check = Check()
        check.bound = PicPlaceBindingRecord.read(inRoot: root)?.library != nil
        let records = PicPlaceSyncState.load(root: root).records
        let projects = root.appendingPathComponent("Projects", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: projects.path)) ?? []
        for name in names {
            guard !name.hasPrefix("."), let id = UUID(uuidString: name) else { continue }
            check.projects += 1
            let folder = projects.appendingPathComponent(name, isDirectory: true)
            let entries = (try? PicPlaceSyncRun.listFiles(in: folder)) ?? []
            let summary = PicPlaceSyncInventory.summary(of: PicPlaceSyncInventory.classify(entries), policy: .minimal)
            guard summary.heavyFiles > 0 else { continue }
            check.originalsHere += 1
            let onServer = records[id].map { ($0.serverHeavyFiles ?? 0) >= summary.heavyFiles || $0.originalsMovedAt != nil } ?? false
            if !onServer { check.onlyHere.append(projectName(in: folder) ?? String(name.prefix(8))) }
        }
        return check
    }

    private static func projectName(in folder: URL) -> String? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(ProjectFileRegistry.projectDocumentName)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return ((object["capture"] as? [String: Any])?["name"] as? String) ?? (object["name"] as? String)
    }
}

/// "Add a library from PicPlace" on a phone: the account's libraries not
/// here; the chosen one is copied as a folder and opened at once.
struct AddLibraryFromPicPlacePhoneSheet: View {
    @ObservedObject var picplace: PicPlaceController
    var onAdded: (StorageRoot.LibraryFolder) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: PPLibrary?
    @State private var failure: String?

    private var remote: [PPLibrary] { picplace.librariesNotOnThisDevice }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add a library from PicPlace")
                .font(.system(size: 19, weight: .semibold))
                .padding(.top, 26)
            Text("A copy of the library is made on \(PicPlaceController.deviceWord) — its projects arrive as previews; originals download per project. It opens right away.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(remote) { library in
                        Button { chosen = library } label: {
                            HStack(spacing: 12) {
                                Image(systemName: chosen?.id == library.id ? "largecircle.fill.circle" : "circle")
                                    .font(.system(size: 16))
                                    .foregroundStyle(chosen?.id == library.id ? LL.accent : Color.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(library.displayName).font(.system(size: 14.5, weight: chosen?.id == library.id ? .semibold : .regular))
                                    Text("\(library.count) project\(library.count == 1 ? "" : "s") · \(LLFormat.bytes(library.usedBytes ?? 0)) on PicPlace")
                                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 11)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if library.id != remote.last?.id { Divider().padding(.leading, 44) }
                    }
                }
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.top, 16)
            }
            .frame(maxHeight: 360)

            if let failure {
                Text(failure).font(.system(size: 12.5)).foregroundStyle(LL.levelOff).padding(.top, 8)
            }

            Spacer(minLength: 0)

            HStack {
                Button("Not now") { dismiss() }
                    .buttonStyle(LLSecondaryButtonStyle())
                Button("Add and Open") { add() }
                    .buttonStyle(LLPrimaryButtonStyle())
                    .disabled(chosen == nil)
            }
            .padding(.top, 20)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .background(LL.screenBackground)
        .onAppear { if chosen == nil { chosen = remote.first } }
    }

    private func add() {
        guard let chosen else { return }
        do {
            let folder = try picplace.addLibraryFromPicPlace(chosen)
            dismiss()
            onAdded(folder)
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
#endif
