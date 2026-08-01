import SwiftUI
import AVKit
import LetsLapseKit

/// The review screen. It answers "where did my file go" up front, and turns
/// re-blending into a single "New blended clip" row.
struct ResultView: View {
    @EnvironmentObject var model: AppModel
    @State private var player: AVPlayer?
    @State private var compareItem: MediaPreviewItem?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 14) {
                    playerCard
                        .padding(.top, 20)

                    savedBanner

                    HStack(spacing: 10) {
                        #if os(iOS)
                        Button {
                            model.saveResultToPhotos()
                        } label: {
                            Text("Save to Photos")
                        }
                        .buttonStyle(LLPrimaryButtonStyle())
                        #endif

                        if let shareURL = model.resultVideoURL ?? model.resultImageURL {
                            ShareLink(item: shareURL) {
                                Text("Share")
                                    .font(.system(size: 15.5, weight: .bold))
                                    .foregroundStyle(LL.accent)
                                    .frame(maxWidth: .infinity, minHeight: 50)
                            }
                            .background(LL.cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
                        }
                    }

                    if let note = model.saveConfirmation {
                        Text(note)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    nextSteps

                    if let error = model.errorMessage {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .llCard()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }

            Button {
                model.finishFlow(openProject: true)
            } label: {
                Text("Done")
            }
            .buttonStyle(LLSecondaryButtonStyle(tint: .secondary))
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .background(LL.screenBackground.ignoresSafeArea())
        .onAppear {
            updatePlayer()
        }
        .onChange(of: model.resultVideoURL) { _ in
            updatePlayer()
        }
        .onDisappear {
            player?.pause()
        }
        .sheet(item: $compareItem) { item in
            ProjectMediaPreviewSheet(item: item)
        }
    }

    // MARK: - Player

    private var playerCard: some View {
        ZStack(alignment: .topLeading) {
            Group {
                if model.resultVideoURL != nil {
                    VideoPlayer(player: player)
                } else if let image = model.resultImage {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                } else {
                    Rectangle().fill(.black)
                }
            }
            .frame(height: 300)
            .frame(maxWidth: .infinity)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

            MediaBadge(text: resultChip)
                .padding(12)
        }
    }

    private var resultChip: String {
        guard let blend = model.currentBlend else { return "New blended clip" }
        var parts = [blend.speedLabel]
        if let seconds = blend.outputSeconds {
            parts.append(SpeedMath.clipLengthCompact(seconds))
        }
        if blend.kind == .video, let fps = blend.outputFPS {
            parts.append("\(fps) fps")
        }
        if let width = blend.width, let height = blend.height {
            parts.append(AppModel.CaptureProject.resolutionLabel(width: width, height: height))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Saved banner

    @ViewBuilder
    private var savedBanner: some View {
        if let blend = model.currentBlend, let capture = model.currentCapture {
            HStack(spacing: 10) {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.green)
                Group {
                    Text("Saved as ")
                        + Text("blended clip \(model.versionNumber(for: blend))").bold()
                        + Text(" in ")
                        + Text(capture.displayTitle).bold()
                }
                .font(.system(size: 13.5))
                .lineLimit(2)
                Spacer(minLength: 8)
                Button("View project") {
                    model.finishFlow(openProject: true)
                }
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(LL.accent)
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.green.opacity(0.35), lineWidth: 1)
            )
        }
    }

    // MARK: - Next steps

    /// A Photo-mode result is a single auto-blended shot with no Adjust step —
    /// re-processing isn't a thing, so its "New blended clip" row stays hidden.
    private var isPhotoResult: Bool {
        model.currentCapture?.isPhotoCapture == true
    }

    private var nextSteps: some View {
        VStack(spacing: 0) {
            if !isPhotoResult {
                Button {
                    model.stage = .configure
                } label: {
                    HStack {
                        Label("New blended clip from original", systemImage: "arrow.counterclockwise")
                            .font(.system(size: 15.5, weight: .semibold))
                            .foregroundStyle(LL.accent)
                        Spacer()
                        if let hint = suggestionHint {
                            Text(hint)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if canCompare {
                if !isPhotoResult {
                    Divider().padding(.leading, 16)
                }

                Button {
                    compareWithOriginal()
                } label: {
                    HStack {
                        Text("Compare with original")
                            .font(.system(size: 15.5))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .llCard()
    }

    private var suggestionHint: String? {
        guard let speed = model.suggestedAlternateSpeed() else { return nil }
        guard let seconds = model.estimatedOutputSeconds(speed: speed) else { return "try \(speed)×" }
        return "try \(speed)× → \(SpeedMath.clipLengthCompact(seconds))"
    }

    private var canCompare: Bool {
        guard let capture = model.currentCapture else { return false }
        return model.mediaURL(for: capture) != nil
    }

    private func compareWithOriginal() {
        guard let capture = model.currentCapture,
              let url = model.mediaURL(for: capture) else { return }
        compareItem = MediaPreviewItem(
            title: "Original",
            subtitle: capture.formatLine,
            url: url,
            kind: model.mediaKind(for: capture)
        )
    }

    private func updatePlayer() {
        if let url = model.resultVideoURL {
            PlaybackAudioSession.configureAmbient()
            player = AVPlayer(url: url)
        } else {
            player = nil
        }
    }
}
