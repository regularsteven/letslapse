import SwiftUI
import LetsLapseKit

struct BlendOptionsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("Source") {
                Text(model.source?.summary ?? "—")
                if let capture = model.currentCapture {
                    Text(capture.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Choose another source") {
                    model.reset()
                }
            }

            if model.source?.isVideo == true {
                videoOptions
            } else {
                stackOptions
            }

            if let error = model.errorMessage {
                Section {
                    Text(error).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Blend Options")
    }

    @ViewBuilder
    private var videoOptions: some View {
        Section {
            Picker("Frames to one output frame", selection: $model.constantWindow) {
                ForEach([2, 5, 10, 25, 50], id: \.self) { count in
                    Text("\(count) to 1").tag(count)
                }
            }
            Stepper("Custom: \(model.constantWindow) frame\(model.constantWindow == 1 ? "" : "s")",
                    value: $model.constantWindow, in: 1...120)
            Picker("Output frame rate", selection: $model.outputFPS) {
                ForEach([24, 25, 30, 50, 60], id: \.self) { fps in
                    Text("\(fps) fps").tag(fps)
                }
            }
            Toggle("Linear-light averaging", isOn: $model.linearLight)
        } header: {
            Text("Video blend")
        } footer: {
            #if os(macOS)
            Text("Blend creates a .letslapse job folder beside the source video. Completed extraction and blend frames are reused if you run the same job again.")
            #else
            Text("Each output frame averages a fixed number of input frames. 2 to 1 at the same output FPS plays at double speed.")
            #endif
        }

        Section("Advanced") {
            Toggle("Ramp the window across the clip", isOn: $model.useRamp)
            if model.useRamp {
                Stepper("Start: \(model.rampStart) frame\(model.rampStart == 1 ? "" : "s")",
                        value: $model.rampStart, in: 1...120)
                Stepper("End: \(model.rampEnd) frames", value: $model.rampEnd, in: 1...120)
                Picker("Curve", selection: $model.curve) {
                    ForEach(BlendCurve.allCases, id: \.self) { curve in
                        Text(curve.rawValue).tag(curve)
                    }
                }
            }
        }
        Section {
            Toggle("Trim video ends", isOn: $model.trimVideoEnds)
            if model.trimVideoEnds {
                Stepper(
                    "Cut \(model.trimHeadTailSeconds, specifier: "%.1f")s from start and end",
                    value: $model.trimHeadTailSeconds,
                    in: 0.1...30,
                    step: 0.5
                )
            }
        } header: {
            Text("Trim")
        } footer: {
            Text("Removes the same duration from the beginning and end before blending.")
        }
        Section {
            Button {
                model.startProcessing()
            } label: {
                Label("Blend Video", systemImage: "wand.and.stars")
                    .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private var stackOptions: some View {
        Section("Stack") {
            Toggle("Linear-light averaging", isOn: $model.linearLight)
            Text("All photos are averaged into one image — a synthetic long exposure with noise reduced by roughly the square root of the frame count.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        Section {
            Button {
                model.startProcessing()
            } label: {
                Label("Stack Photos", systemImage: "square.3.layers.3d.down.right")
                    .frame(maxWidth: .infinity)
            }
        }
    }
}
