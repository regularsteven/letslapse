import SwiftUI

/// The in/out editor for one clip on a collection's timeline — a dark
/// fullscreen surface: preview up top, IN / kept / OUT readouts, and a
/// filmstrip whose amber handles set the kept range. Trimming retimes the
/// whole collection — the clips after this one pull in, never leaving gaps.
///
/// In/out points live as fractions of the clip; Done commits them to the
/// collection entry, Cancel walks away, Reset clears both.
struct CollectionTrimView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let collectionID: UUID
    let blendID: UUID
    /// The toast the detail screen shows after a commit.
    var onDone: (String?) -> Void

    @State private var inPoint: Double = 0
    @State private var outPoint: Double = 1

    /// The smallest range the handles can close to — 6% of the clip.
    private let minimumGap = 0.06
    private let handleWidth: CGFloat = 22

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.top, 18)

            preview
                .padding(.top, 24)

            readouts
                .padding(.horizontal, 26)
                .padding(.top, 34)

            filmstrip
                .frame(height: 56)
                .padding(.horizontal, 24)
                .padding(.top, 16)

            Text("Trimming retimes the whole collection — the clips after this one pull in. No gaps, ever.")
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.horizontal, 44)
                .padding(.top, 22)

            Button("Reset trim") {
                inPoint = 0
                outPoint = 1
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(LL.amber)
            .buttonStyle(.plain)
            .padding(.top, 14)

            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear {
            if let entry = model.collection(withID: collectionID)?.entry(for: blendID) {
                inPoint = entry.inPoint
                outPoint = entry.outPoint
            }
        }
        .task {
            if let blend { await model.probeBlendMediaIfNeeded(blend) }
        }
    }

    private var topBar: some View {
        ZStack {
            HStack {
                Button("Cancel") { dismiss() }
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.7))
                    .buttonStyle(.plain)
                Spacer()
                Button("Done") { commit() }
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(LL.amber)
                    .buttonStyle(.plain)
            }
            VStack(spacing: 1) {
                Text("Trim")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Text(clipLabel)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 20)
    }

    private var preview: some View {
        let aspect = blend.map(model.blendAspect) ?? 16.0 / 9.0
        let size = CollectionMath.fit(aspect: aspect, maxWidth: 345, maxHeight: 240)
        return ZStack {
            ProjectThumbnailView(url: blend.map(model.mediaURL(for:)), kind: .video)
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Image(systemName: "play.fill")
                .font(.system(size: 20))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(.black.opacity(0.45), in: Circle())
        }
        .frame(height: size.height)
    }

    private var readouts: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text("IN")
                    .font(.system(size: 10, weight: .bold))
                    .kerning(1)
                    .foregroundStyle(.white.opacity(0.45))
                Text(seconds(at: inPoint))
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
            }
            Spacer()
            VStack(spacing: 1) {
                Text(SpeedMath.clipLengthCompact(keptSeconds))
                    .font(.system(size: 24, weight: .bold).monospacedDigit())
                    .foregroundStyle(LL.amber)
                Text("kept of \(SpeedMath.clipLengthCompact(fullSeconds))")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("OUT")
                    .font(.system(size: 10, weight: .bold))
                    .kerning(1)
                    .foregroundStyle(.white.opacity(0.45))
                Text(seconds(at: outPoint))
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
            }
        }
    }

    // MARK: - Filmstrip

    private var filmstrip: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                // The strip — the clip's own look sliced into frames — with
                // the dropped head and tail dimmed. Clipped as one layer so
                // the handles can overhang the bar without being cut.
                ZStack(alignment: .leading) {
                    ZStack {
                        ProjectThumbnailView(url: blend.map(model.mediaURL(for:)), kind: .video)
                            .frame(width: width, height: 56)
                        Canvas { context, size in
                            var x: CGFloat = 42
                            while x < size.width {
                                context.fill(
                                    Path(CGRect(x: x, y: 0, width: 2, height: size.height)),
                                    with: .color(.black.opacity(0.35)))
                                x += 44
                            }
                        }
                    }
                    Rectangle()
                        .fill(.black.opacity(0.62))
                        .frame(width: max(0, inPoint * width), height: 56)
                    Rectangle()
                        .fill(.black.opacity(0.62))
                        .frame(width: max(0, (1 - outPoint) * width), height: 56)
                        .offset(x: outPoint * width)
                }
                .frame(width: width, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                // The kept range.
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(LL.amber, lineWidth: 2.5)
                    .frame(width: max(0, (outPoint - inPoint) * width), height: 56)
                    .offset(x: inPoint * width)
                    .allowsHitTesting(false)

                handle(chevron: "chevron.left", fraction: inPoint, width: width) { f in
                    inPoint = min(max(0, f), outPoint - minimumGap)
                }
                handle(chevron: "chevron.right", fraction: outPoint, width: width) { f in
                    outPoint = max(min(1, f), inPoint + minimumGap)
                }
            }
            .coordinateSpace(name: "filmstrip")
        }
    }

    private func handle(
        chevron: String, fraction: Double, width: CGFloat, onDrag: @escaping (Double) -> Void
    ) -> some View {
        Image(systemName: chevron)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(LL.ink)
            .frame(width: handleWidth, height: 66)
            .background(LL.amber, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .offset(x: fraction * width - handleWidth / 2)
            .highPriorityGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("filmstrip"))
                    .onChanged { gesture in
                        onDrag(Double(gesture.location.x / width))
                    }
            )
    }

    // MARK: - Values

    private var blend: AppModel.BlendProject? {
        model.blends.first { $0.id == blendID }
    }

    private var clipLabel: String {
        guard let blend else { return "" }
        let project = model.capture(for: blend)?.displayTitle ?? "Blended clip"
        return "\(project) · \(blend.speedLabel)"
    }

    private var fullSeconds: Double {
        blend.flatMap(model.blendDuration(for:)) ?? 0
    }

    private var keptSeconds: Double {
        max(0, outPoint - inPoint) * fullSeconds
    }

    private func seconds(at fraction: Double) -> String {
        String(format: "%.1fs", fraction * fullSeconds)
    }

    private func commit() {
        model.updateTrim(blendID: blendID, in: collectionID, inPoint: inPoint, outPoint: outPoint)
        let total = model.collection(withID: collectionID).map(model.collectionSeconds) ?? 0
        dismiss()
        onDone("Collection retimed — now \(CollectionMath.timecode(total))")
    }
}
