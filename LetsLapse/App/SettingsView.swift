import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
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
    }
}
