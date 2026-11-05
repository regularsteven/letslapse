import SwiftUI
import LetsLapseKit

// Files dropped on the Gallery (the Mac, 2026-11-05).
//
// Photos and videos dragged from the Finder onto the grid become projects
// where they were dropped — one each — through `AppModel.importDropped`. The
// gesture's whole promise is that nothing else happens: no blend flow, no
// project screen, no other tab. The one question it can ask is the stills
// import's own sheet, and only when the photos could be an interval shoot.
//
// Three pieces, all the Gallery's: the drop target with its highlight, the
// strip under the header that says what an import is doing and what a drop
// brought in, and the alert for a drop that could not be taken.
//
// iPad and iPhone are not here yet (docs/TODO.md, "Gallery drag and drop on
// iPad and iPhone"): a drag from Photos carries picture data, not a file.

#if os(macOS)

/// Makes the Gallery's grid column a drop target for photos, videos and the
/// folders holding them.
struct GalleryDropTarget: ViewModifier {
    @EnvironmentObject var model: AppModel
    /// False while something other than the grid is in the column (the Auto
    /// rename & tag review list): a drop there is refused, with no highlight.
    var isEnabled: Bool

    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .dropDestination(for: URL.self) { urls, _ in
                guard isEnabled else { return false }
                return model.importDropped(urls)
            } isTargeted: { targeted in
                isTargeted = targeted && isEnabled
            }
            .overlay {
                if isTargeted { GalleryDropHighlight() }
            }
            .alert("Couldn't import",
                   isPresented: Binding(
                       get: { model.galleryImportFailure != nil },
                       set: { if !$0 { model.galleryImportFailure = nil } }
                   )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.galleryImportFailure ?? "")
            }
            #if DEBUG
            .onAppear { consumeDropHook() }
            #endif
    }

    #if DEBUG
    private static var dropHookConsumed = false

    /// `LL_GALLERY_DROP=target|<path>[:<path>…]` — with `LL_TAB=gallery`.
    /// `target` holds the drop highlight up for a screenshot; paths (files
    /// or folders) are handed to the drop's own handler a moment after the
    /// grid appears, as if they had been let go over it — the Finder drag no
    /// headless run can make. `LL_IMPORT_ANSWER=shoot|photos|cancel` answers
    /// the question when the photos raise it; without it the sheet stays up.
    private func consumeDropHook() {
        guard !Self.dropHookConsumed,
              let raw = ProcessInfo.processInfo.environment["LL_GALLERY_DROP"], !raw.isEmpty
        else { return }
        Self.dropHookConsumed = true
        if raw == "target" {
            isTargeted = true
            return
        }
        let urls = raw.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            model.importDropped(urls)
        }
    }
    #endif
}

/// The grid while files are held over it: the accent's dashed frame — the
/// same one Create draws for a dropped video — over a light wash, with the
/// one line that says what letting go will do.
private struct GalleryDropHighlight: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LL.accent.opacity(0.08))
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(LL.accent, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
            HStack(spacing: 8) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 14, weight: .semibold))
                Text("Drop to import")
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(LL.accent, in: Capsule())
        }
        .padding(12)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The strip under the Gallery's header: an import in flight — its caption,
/// its bar, its size — and, for a few seconds after a drop, what it brought
/// in. Draws nothing the rest of the time.
///
/// It shows any import of outside files, whichever tab started it: the
/// import is the library's, and the Gallery is where its projects appear.
struct GalleryImportStrip: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let progress = model.mediaImport {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: progress.name == nil ? "photo.stack" : "film")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LL.accent)
                    Text(progress.caption)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    // Drawn, as Create's card draws its own: the system
                    // linear bar fills in the control grey on the Mac
                    // whatever the tint says.
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.12))
                            Capsule()
                                .fill(LL.accent)
                                .frame(width: max(0, geometry.size.width * progress.fraction))
                        }
                    }
                    .frame(height: 5)
                    .frame(minWidth: 80)
                    .animation(.easeOut(duration: 0.25), value: progress.fraction)
                    if progress.totalBytes > 0 {
                        Text(LLFormat.bytes(progress.totalBytes))
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: 34)
                Divider()
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("gallery.import.progress")
        } else if let landing = model.galleryImportLanding {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LL.levelGood)
                    Text(landing.line)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .frame(height: 34)
                Divider()
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("gallery.import.done")
        }
    }
}

#endif
