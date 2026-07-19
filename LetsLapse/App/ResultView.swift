import SwiftUI
import AVKit

struct ResultView: View {
    @EnvironmentObject var model: AppModel
    @State private var player: AVPlayer?

    var body: some View {
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
                    Label("Start Over", systemImage: "arrow.counterclockwise")
                }
            }

            if let note = model.saveConfirmation {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .navigationTitle("Result")
        .onAppear {
            if let url = model.resultVideoURL {
                player = AVPlayer(url: url)
            }
        }
    }
}
