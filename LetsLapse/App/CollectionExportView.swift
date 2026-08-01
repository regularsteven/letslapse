import AVKit
import SwiftUI

/// The export cover: progress while the render runs, the result once it's
/// done. Reuses the app's Processing pattern — one ring over the footage,
/// an explicit phase checklist, an honest status line, and a Cancel that
/// really cancels ("Cancelling keeps your collection — nothing is lost.").
struct CollectionExportFlowView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var controller: CollectionExportController
    @Environment(\.dismiss) private var dismiss
    /// The toast the detail screen shows once the cover is down.
    var onClose: (String?) -> Void

    var body: some View {
        Group {
            switch controller.state {
            case .idle, .exporting:
                CollectionExportProgressView(controller: controller) {
                    controller.cancel()
                }
            case .done(let url):
                CollectionExportResultView(controller: controller, url: url) {
                    dismiss()
                    onClose(nil)
                }
            case .failed(let message):
                failedCard(message)
            case .cancelled:
                Color.clear
            }
        }
        .background(LL.screenBackground.ignoresSafeArea())
        .onChange(of: controller.state) { state in
            if state == .cancelled {
                dismiss()
                onClose("Export cancelled — your collection is untouched")
            }
        }
        #if os(iOS)
        .interactiveDismissDisabled(controller.state == .exporting)
        #endif
    }

    private func failedCard(_ message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Export didn't finish")
                .font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Your collection is untouched.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Done") {
                dismiss()
                onClose(nil)
            }
            .buttonStyle(LLSecondaryButtonStyle(tint: .secondary))
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 16)
    }
}

// MARK: - Progress

private struct CollectionExportProgressView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var controller: CollectionExportController
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            hero
                .padding(.top, 40)

            checklist

            Text(controller.statusLine)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            Spacer(minLength: 0)

            VStack(spacing: 8) {
                Button("Cancel", action: onCancel)
                    .buttonStyle(LLSecondaryButtonStyle(tint: .red))
                Text("Cancelling keeps your collection — nothing is lost.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 16)
    }

    private var hero: some View {
        ZStack {
            ProjectThumbnailView(url: firstClipURL, kind: .video)
                .frame(height: 260)
                .frame(maxWidth: .infinity)
                .blur(radius: 2.5)
                .overlay(Color.black.opacity(0.45))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

            ZStack {
                Circle()
                    .stroke(.white.opacity(0.2), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: max(0.003, controller.progress))
                    .stroke(LL.amber, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.3), value: controller.progress)
                Text("\(Int((controller.progress * 100).rounded()))%")
                    .font(.system(size: 17, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
            }
            .frame(width: 92, height: 92)
            .padding(8)
            .background(.black.opacity(0.35), in: Circle())
        }
    }

    private var firstClipURL: URL? {
        model.collection(withID: controller.collectionID)?
            .entries.first
            .flatMap { model.blendMediaURL(for: $0.blendID) }
    }

    private var checklist: some View {
        let clipCount = model.collection(withID: controller.collectionID)?.entries.count ?? 0
        let stages: [(label: String, detail: String?)] = [
            ("Preparing clips", nil),
            ("Cropping & scaling", renderDetail),
            ("Combining \(clipCount) clip\(clipCount == 1 ? "" : "s")", nil),
            ("Saving to collection", nil)
        ]
        let current = phaseIndex
        return VStack(spacing: 0) {
            ForEach(Array(stages.enumerated()), id: \.offset) { index, stage in
                HStack(spacing: 12) {
                    if index < current {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.green)
                            .frame(width: 18)
                    } else if index == current {
                        Circle()
                            .fill(LL.amber)
                            .frame(width: 9, height: 9)
                            .frame(width: 18)
                    } else {
                        Circle()
                            .stroke(Color.secondary.opacity(0.5), lineWidth: 1.2)
                            .frame(width: 9, height: 9)
                            .frame(width: 18)
                    }

                    Text(stage.label)
                        .font(.system(size: 15, weight: index == current ? .semibold : .regular))
                        .foregroundStyle(index <= current ? Color.primary : Color.secondary.opacity(0.7))

                    Spacer()

                    if let detail = stage.detail, index == current {
                        Text(detail)
                            .font(.system(size: 13).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
            }
        }
        .padding(.vertical, 6)
        .llCard()
    }

    private var phaseIndex: Int {
        switch controller.phase {
        case .preparing: return 0
        case .rendering: return 1
        case .combining: return 2
        case .saving: return 3
        }
    }

    private var renderDetail: String? {
        if case .rendering(let clip, let of) = controller.phase, of > 1 {
            return "\(clip) / \(of)"
        }
        return nil
    }
}

// MARK: - Result

private struct CollectionExportResultView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var controller: CollectionExportController
    let url: URL
    var onDone: () -> Void

    @State private var player: AVPlayer?
    @State private var saveState: SaveState = .idle
    /// The exported file's own duration — the badge reports the render, not
    /// the timeline estimate.
    @State private var renderedSeconds: Double?

    private enum SaveState: Equatable {
        case idle, saving, saved
        case failed(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            playerCard
                .padding(.top, 24)

            successBanner
                .padding(.top, 16)

            HStack(spacing: 10) {
                #if os(iOS)
                saveButton
                #endif
                ShareLink(item: url) {
                    Text("Share")
                        .font(.system(size: 15.5, weight: .bold))
                }
                .buttonStyle(LLSecondaryButtonStyle())
            }
            .padding(.top, 14)

            Text("The render stays with the collection — exporting again is instant until you change clips, trims, or crops.")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .llCard()
                .padding(.top, 14)

            if case .failed(let message) = saveState {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .padding(.top, 8)
            }

            Spacer(minLength: 0)

            Button("Done", action: onDone)
                .buttonStyle(LLSecondaryButtonStyle(tint: .secondary))
                .padding(.bottom, 24)
        }
        .padding(.horizontal, 16)
        .onAppear { player = AVPlayer(url: url) }
        .onDisappear { player?.pause() }
        .task {
            if let seconds = try? await AVURLAsset(url: url).load(.duration).seconds,
               seconds.isFinite, seconds > 0 {
                renderedSeconds = seconds
            }
        }
    }

    private var playerCard: some View {
        ZStack {
            Color(red: 14 / 255, green: 18 / 255, blue: 24 / 255)
            if let player {
                VideoPlayer(player: player)
            }
        }
        .frame(height: 300)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(alignment: .topLeading) {
            MediaBadge(text: badgeText)
                .padding(12)
                .allowsHitTesting(false)
        }
    }

    /// "9:16 · 2160×3840 · 0:56" — duration from the file itself once probed.
    private var badgeText: String {
        guard let collection = model.collection(withID: controller.collectionID) else { return "" }
        var parts: [String] = []
        if let ratio = collection.ratio {
            parts.append(ratio.rawValue)
            parts.append(ratio.exportLabel)
        }
        parts.append(CollectionMath.timecode(renderedSeconds ?? model.collectionSeconds(collection)))
        return parts.joined(separator: " · ")
    }

    private var successBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.green)
            (Text("Exported — kept in ") + Text(collectionName).bold())
                .font(.system(size: 13.5))
                .lineLimit(1)
            Spacer(minLength: 0)
            Button("Open", action: onDone)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(LL.accent)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.green.opacity(0.35), lineWidth: 1)
        )
    }

    #if os(iOS)
    private var saveButton: some View {
        Button {
            save()
        } label: {
            switch saveState {
            case .idle, .failed:
                Text("Save to Photos")
            case .saving:
                ProgressView().tint(.white)
            case .saved:
                Label("Saved", systemImage: "checkmark")
            }
        }
        .buttonStyle(LLPrimaryButtonStyle())
        .disabled(saveState == .saving || saveState == .saved)
    }

    private func save() {
        saveState = .saving
        Task {
            do {
                try await model.saveSourceClip(at: url)
                saveState = .saved
            } catch {
                saveState = .failed(error.localizedDescription)
            }
        }
    }
    #endif

    private var collectionName: String {
        model.collection(withID: controller.collectionID)?.name ?? "collection"
    }
}
