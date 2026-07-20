import SwiftUI
import AVFoundation

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var cameraAuthorizationStatus = CameraPrivacySettings.authorizationStatus

    var body: some View {
        Form {
            #if os(macOS)
            Section {
                LabeledContent("Status") {
                    Text(cameraStatusText)
                        .foregroundStyle(cameraAuthorizationStatus == .authorized ? Color.secondary : Color.red)
                }

                if cameraAuthorizationStatus == .notDetermined {
                    Button {
                        CameraPrivacySettings.requestAccess { _ in
                            cameraAuthorizationStatus = CameraPrivacySettings.authorizationStatus
                        }
                    } label: {
                        Label("Request Camera Access", systemImage: "video")
                    }
                } else if cameraAuthorizationStatus != .authorized {
                    Button {
                        CameraPrivacySettings.open()
                    } label: {
                        Label("Open Camera Privacy Settings", systemImage: "gear")
                    }
                }
            } header: {
                Text("Camera")
            } footer: {
                Text("macOS controls webcam permission in System Settings. After changing access, reopen the capture sheet.")
            }
            #endif

            Section("Defaults") {
                Picker("Output frame rate", selection: $model.outputFPS) {
                    ForEach([24, 25, 30, 50, 60], id: \.self) { fps in
                        Text("\(fps) fps").tag(fps)
                    }
                }
                Picker("Frames to one output frame", selection: $model.constantWindow) {
                    ForEach([2, 5, 10, 25, 50], id: \.self) { count in
                        Text("\(count) to 1").tag(count)
                    }
                }
                Toggle("Linear-light averaging", isOn: $model.linearLight)
            }

            Section {
                Stepper("CPU worker budget: \(model.maxCPUWorkers)",
                        value: $model.maxCPUWorkers,
                        in: 1...max(1, ProcessInfo.processInfo.activeProcessorCount))
                Stepper("Concurrent blend batches: \(model.maxBlendBatches)",
                        value: $model.maxBlendBatches,
                        in: 1...8)
            } header: {
                Text("Performance")
            } footer: {
                Text("Video decode runs mostly serially. Blend batches use Metal on the GPU; higher values may help until disk I/O or GPU contention dominates.")
            }
        }
        .navigationTitle("Settings")
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .padding(.horizontal)
        .frame(maxWidth: 720)
        .onAppear {
            cameraAuthorizationStatus = CameraPrivacySettings.authorizationStatus
        }
    }

    private var cameraStatusText: String {
        switch cameraAuthorizationStatus {
        case .authorized:
            return "Enabled"
        case .notDetermined:
            return "Not requested"
        case .denied:
            return "Denied"
        case .restricted:
            return "Restricted"
        @unknown default:
            return "Unknown"
        }
    }
}
