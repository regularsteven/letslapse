import SwiftUI
import AVKit
import LetsLapseKit

struct ResultView: View {
    @EnvironmentObject var model: AppModel
    @State private var player: AVPlayer?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if model.resultVideoURL != nil {
                    VideoPlayer(player: player)
                        .frame(minHeight: 280)
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else if let image = model.resultImage {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .frame(minHeight: 280)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                if let summary = model.resultSummary {
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if let blend = model.currentBlend {
                    Text(blend.parameterSummary)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 20) {
                    if let shareURL = model.resultVideoURL ?? model.resultImageURL {
                        ShareLink(item: shareURL) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    }
                    #if os(iOS)
                    Button {
                        model.saveResultToPhotos()
                    } label: {
                        Label("Save to Photos", systemImage: "photo.badge.arrow.down")
                    }
                    #endif
                    Button {
                        model.reset()
                    } label: {
                        Label("Close", systemImage: "xmark.circle")
                    }
                }

                reblendControls

                if let note = model.saveConfirmation {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .navigationTitle("Result")
        .onAppear {
            updatePlayer()
        }
        .onChange(of: model.resultVideoURL) { _ in
            updatePlayer()
        }
    }

    @ViewBuilder
    private var reblendControls: some View {
        if model.currentCapture != nil {
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("Re-blend from original")
                    .font(.headline)

                if model.source?.isVideo == true {
                    Picker("Frames to one output frame", selection: $model.constantWindow) {
                        ForEach([2, 5, 10, 25, 50], id: \.self) { count in
                            Text("\(count) to 1").tag(count)
                        }
                    }
                    Stepper("Custom: \(model.constantWindow) frame\(model.constantWindow == 1 ? "" : "s")",
                            value: $model.constantWindow, in: 1...120)
                    Picker("Playback timing", selection: $model.outputFPS) {
                        ForEach([24, 25, 30, 50, 60], id: \.self) { fps in
                            Text("\(fps) fps").tag(fps)
                        }
                    }
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
                } else {
                    Toggle("Linear-light averaging", isOn: $model.linearLight)
                }

                Button {
                    model.startProcessing()
                } label: {
                    Label("Regenerate", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: 520, alignment: .leading)
        }
    }

    private func updatePlayer() {
        if let url = model.resultVideoURL {
            player = AVPlayer(url: url)
        } else {
            player = nil
        }
    }
}
