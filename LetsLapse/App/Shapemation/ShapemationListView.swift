import SwiftUI
import AVKit
import LetsLapseKit

/// "List Shape-mations": every finished video, newest first, with play,
/// share and delete.
struct ShapemationListView: View {
    @ObservedObject var store: ShapemationStore
    @State private var playing: ShapemationStore.Record?
    @State private var deleting: ShapemationStore.Record?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if store.records.isEmpty {
                    Text("No Shape-mations yet. Create a shape slideshow and it will appear here.")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .llCard(cornerRadius: 18)
                }
                ForEach(store.records) { record in
                    row(record)
                }
            }
            .padding(16)
        }
        .background(LL.screenBackground.ignoresSafeArea())
        .navigationTitle("Shape-mations")
        .sheet(item: $playing) { record in
            ShapemationPlayerSheet(record: record, store: store)
        }
        .confirmationDialog("Delete this Shape-mation?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let record = deleting { store.delete(record) }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("The video is removed from the library. The photos it was built from are untouched.")
        }
        .onAppear { store.load() }
    }

    private func row(_ record: ShapemationStore.Record) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button { playing = record } label: {
                ZStack {
                    ShapemationPosterView(record: record, store: store)
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.white.opacity(0.9))
                        .shadow(radius: 4)
                }
                .frame(width: 110, height: 82)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 4) {
                Text(record.title).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                Text(record.subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                Text("\(Int(record.seconds)) s").font(.system(size: 12)).foregroundStyle(.tertiary)
                HStack(spacing: 14) {
                    Button { playing = record } label: { Label("Play", systemImage: "play.fill") }
                    ShareLink(item: store.url(for: record)) { Label("Share", systemImage: "square.and.arrow.up") }
                    Button(role: .destructive) { deleting = record } label: { Label("Delete", systemImage: "trash") }
                }
                .font(.system(size: 13, weight: .medium))
                .labelStyle(.titleAndIcon)
                .buttonStyle(.borderless)
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .llCard(cornerRadius: 14)
        .contextMenu {
            Button { playing = record } label: { Label("Play", systemImage: "play.fill") }
            ShareLink(item: store.url(for: record)) { Label("Share", systemImage: "square.and.arrow.up") }
            Button(role: .destructive) { deleting = record } label: { Label("Delete", systemImage: "trash") }
        }
    }
}

/// The poster JPEG a render left beside its video.
struct ShapemationPosterView: View {
    let record: ShapemationStore.Record
    @ObservedObject var store: ShapemationStore
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Color.black)
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
            }
        }
        .task(id: record.id) {
            guard let url = store.posterURL(for: record) else { return }
            let loaded = await MediaWorkQueue.shared.run { ProjectThumbnailGenerator.imageThumbnail(for: url, maxPixelSize: 640) }
            if let loaded, let loaded { image = loaded }
        }
    }
}

/// Plays one Shape-mation in a sheet.
struct ShapemationPlayerSheet: View {
    let record: ShapemationStore.Record
    @ObservedObject var store: ShapemationStore
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let player {
                    VideoPlayer(player: player)
                        .aspectRatio(CGFloat(record.width) / CGFloat(max(record.height, 1)), contentMode: .fit)
                }
            }
            .navigationTitle(record.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .automatic) {
                    ShareLink(item: store.url(for: record)) { Image(systemName: "square.and.arrow.up") }
                }
            }
        }
        .onAppear {
            let p = AVPlayer(url: store.url(for: record))
            player = p
            p.play()
        }
        .onDisappear { player?.pause() }
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 480)
        #endif
    }
}
