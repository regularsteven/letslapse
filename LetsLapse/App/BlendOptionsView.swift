import SwiftUI
import LetsLapseKit

struct BlendOptionsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("Source") {
                Text(model.source?.summary ?? "—")
                Button("Choose a different source", role: .destructive) {
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
        Section("Blend window") {
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
            } else {
                Stepper("Window: \(model.constantWindow) frames",
                        value: $model.constantWindow, in: 1...120)
            }
            Picker("Output frame rate", selection: $model.outputFPS) {
                ForEach([24, 30, 60], id: \.self) { fps in
                    Text("\(fps) fps").tag(fps)
                }
            }
            Toggle("Linear-light averaging", isOn: $model.linearLight)
        }
        Section {
            Button {
                model.startProcessing()
            } label: {
                Label("Blend Video", systemImage: "wand.and.stars")
                    .frame(maxWidth: .infinity)
            }
        } footer: {
            Text("A ramp from 1 to N starts as dreamy slow motion and accelerates into a motion-blurred hyperlapse. Each output frame averages its window of input frames on the GPU, so blur grows with speed.")
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
