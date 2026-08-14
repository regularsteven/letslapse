import SwiftUI

/// The user's own simplicity dial: every resolution the device's cameras
/// offer, checkable per vocabulary — only ticked ones appear in the format
/// sheet's Resolution list. Reached from Settings and from the format sheet
/// itself, so trimming the list is one tap away from where it grates.
struct ManageResolutionsView: View {
    @ObservedObject private var prefs = ResolutionPreferences.shared
    @State private var domain: ResolutionPreferences.Domain
    @State private var capabilities: [CameraController.ResolutionCapability] = []

    init(initialDomain: ResolutionPreferences.Domain = .stills) {
        _domain = State(initialValue: initialDomain)
    }

    /// Stills never record ProRes — those entries are video-only vocabulary.
    private var stillCapabilities: [CameraController.ResolutionCapability] {
        capabilities.filter { !$0.resolution.isProRes }
    }

    private var stabilizedVideo: [CameraController.ResolutionCapability] {
        capabilities.filter(\.supportsStabilization)
    }

    private var unstabilizedVideo: [CameraController.ResolutionCapability] {
        capabilities.filter { !$0.supportsStabilization }
    }

    /// The rows the active tab lists — the pool the "keep at least one"
    /// guard counts over.
    private var activeCapabilities: [CameraController.ResolutionCapability] {
        domain == .stills ? stillCapabilities : capabilities
    }

    private var visibleCount: Int {
        let hidden = prefs.hiddenIDs(in: domain)
        return activeCapabilities.filter { !hidden.contains($0.id) }.count
    }

    var body: some View {
        Form {
            Section {
                Picker("Mode", selection: $domain) {
                    Text("Photo + Interval").tag(ResolutionPreferences.Domain.stills)
                    Text("Video").tag(ResolutionPreferences.Domain.video)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } footer: {
                Text("Only ticked resolutions are offered in Capture Format. The resolution currently in use stays offered until you pick another.")
            }

            if capabilities.isEmpty {
                Section {
                    Text("No camera found to list resolutions from.")
                        .foregroundStyle(.secondary)
                }
            } else if domain == .stills {
                resolutionSection(stillCapabilities, header: "Resolutions", footer: nil)
            } else if stabilizedVideo.isEmpty {
                // Nothing this camera offers can be stabilised — true of every
                // Mac camera, and of external cameras generally. Splitting the
                // list in two would be a distinction without a difference,
                // under headings that point at a Stabilization control the
                // format sheet isn't showing either.
                resolutionSection(capabilities, header: "Resolutions", footer: nil)
            } else {
                resolutionSection(
                    stabilizedVideo,
                    header: "Stabilised",
                    footer: "Formats the hardware can stabilise — the list Video offers while Stabilization is on.")
                resolutionSection(
                    unstabilizedVideo,
                    header: "Not stabilised",
                    footer: "Offered only while Stabilization is off — the hardware cannot stabilise these formats.")
            }

            Section {
                Toggle("Display ratios", isOn: ratioBinding)
            } footer: {
                Text("Shows each resolution with its aspect ratio — 4032×3024 (4:3).")
            }
        }
        .navigationTitle("Manage resolutions")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            if capabilities.isEmpty {
                capabilities = CameraController.resolutionCapabilities()
            }
        }
    }

    @ViewBuilder
    private func resolutionSection(
        _ list: [CameraController.ResolutionCapability],
        header: String,
        footer: String?
    ) -> some View {
        if !list.isEmpty {
            Section {
                ForEach(list) { capability in
                    resolutionRow(capability)
                }
            } header: {
                Text(header)
            } footer: {
                if let footer { Text(footer) }
            }
        }
    }

    private func resolutionRow(_ capability: CameraController.ResolutionCapability) -> some View {
        let isOn = visibilityBinding(for: capability)
        // The last ticked resolution can't be unticked — an empty format
        // list would leave the camera with nothing to offer.
        let isLastVisible = isOn.wrappedValue && visibleCount <= 1
        return Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(rowLabel(for: capability.resolution))
                if capability.resolution.isProRes {
                    Text("ProRes — very large files")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .disabled(isLastVisible)
    }

    /// Stills speak pixels; Video keeps its names ("4K"). The ratio rides
    /// along when the tab's Display ratios is on.
    private func rowLabel(for resolution: CameraController.CaptureResolution) -> String {
        var label = domain == .stills ? resolution.stillLabel : resolution.label
        if prefs.displaysRatios(in: domain) {
            label += " (\(resolution.aspectRatioLabel))"
        }
        return label
    }

    private func visibilityBinding(for capability: CameraController.ResolutionCapability) -> Binding<Bool> {
        Binding(
            get: { prefs.isVisible(capability.resolution, in: domain) },
            set: { prefs.setVisible($0, resolutionID: capability.id, in: domain) }
        )
    }

    private var ratioBinding: Binding<Bool> {
        Binding(
            get: { prefs.displaysRatios(in: domain) },
            set: { newValue in
                if domain == .stills {
                    prefs.displayRatiosForStills = newValue
                } else {
                    prefs.displayRatiosForVideo = newValue
                }
            }
        )
    }
}
