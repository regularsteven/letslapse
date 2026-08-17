import SwiftUI
import ImageIO
import LetsLapseKit

/// What the detail screen asks for when a page needs its corners re-placed.
struct ScanRecorrectRequest: Identifiable {
    let sessionID: UUID
    let page: ScanPage
    /// The session's stock, as the sheet's opening answer. The choice is
    /// per-page from here: one badly-shot sheet in an A4 set can go through as
    /// Auto without changing what the session claims.
    let paper: PerspectiveAspect

    var id: Int { page.number }
}

enum ScanRecorrectOutcome {
    case replaced(paper: PerspectiveAspect)
    case discarded
    case failed(String)
}

/// Drag the corners on the original, pick the stock, replace the page.
///
/// Every route into this sheet starts from the **photograph**, never from the
/// rectified page: corners measured on an already-rectified image would
/// rectify a rectification. That is also why the destructive row is safe to
/// offer — discarding a correction deletes a derived file and leaves the
/// original exactly where it has always been.
struct ScanRecorrectSheet: View {
    let request: ScanRecorrectRequest
    var onFinish: (ScanRecorrectOutcome) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var quad: NormalizedQuad
    @State private var paper: PerspectiveAspect
    @State private var image: CGImage?
    @State private var isWorking = false

    /// The corners as the detector left them, for Reset. Nil when it never
    /// found any — then Reset returns to the page's own inset.
    private let detected: NormalizedQuad?

    init(request: ScanRecorrectRequest, onFinish: @escaping (ScanRecorrectOutcome) -> Void) {
        self.request = request
        self.onFinish = onFinish
        self.detected = request.page.rectangle
        _quad = State(initialValue: request.page.rectangle ?? Self.defaultQuad)
        _paper = State(initialValue: request.paper)
    }

    /// Where the corners open when the detector found nothing: a generous
    /// inset, which is a page-shaped starting point rather than a claim.
    private static let defaultQuad = NormalizedQuad(
        topLeft: .init(x: 0.12, y: 0.88),
        topRight: .init(x: 0.88, y: 0.88),
        bottomLeft: .init(x: 0.12, y: 0.12),
        bottomRight: .init(x: 0.88, y: 0.12),
        confidence: 0)

    var body: some View {
        VStack(spacing: 0) {
            header
            canvas
            controls
        }
        .background(Color(red: 11 / 255, green: 11 / 255, blue: 12 / 255).ignoresSafeArea())
        .task { await loadImage() }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 700)
        #endif
    }

    private var header: some View {
        ZStack {
            Text("Re-correct page \(request.page.number)")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
            HStack {
                Button("Cancel") { dismiss() }
                    .font(.system(size: 15.5))
                    .foregroundStyle(.white.opacity(0.8))
                    .buttonStyle(.plain)
                Spacer()
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
    }

    // MARK: - Corner canvas

    private var canvas: some View {
        GeometryReader { proxy in
            let rect = Self.fittedRect(imageSize: imageSize, in: proxy.size)
            // Centred, because `fittedRect` centres: the corners are placed in
            // the container's own coordinates, so an image aligned anywhere
            // else puts every handle beside the page instead of on it.
            ZStack {
                Color.black
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .opacity(0.92)
                }
                quadOverlay(in: rect)
                cornerHandles(in: rect)
                VStack {
                    HStack {
                        detectionChip
                        Spacer(minLength: 0)
                    }
                    Spacer(minLength: 0)
                }
                .padding(16)
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button("Reset corners") {
                            withAnimation(.easeOut(duration: 0.2)) {
                                quad = detected ?? Self.defaultQuad
                            }
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(.white.opacity(0.16), in: Capsule())
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
        }
        .frame(maxWidth: .infinity)
        .layoutPriority(1)
    }

    private func quadOverlay(in rect: CGRect) -> some View {
        Path { path in
            let corners = [quad.topLeft, quad.topRight, quad.bottomRight, quad.bottomLeft]
                .map { point($0, in: rect) }
            path.move(to: corners[0])
            corners.dropFirst().forEach { path.addLine(to: $0) }
            path.closeSubpath()
        }
        .fill(LL.amber.opacity(0.14))
        .overlay {
            Path { path in
                let corners = [quad.topLeft, quad.topRight, quad.bottomRight, quad.bottomLeft]
                    .map { point($0, in: rect) }
                path.move(to: corners[0])
                corners.dropFirst().forEach { path.addLine(to: $0) }
                path.closeSubpath()
            }
            .stroke(LL.amber, lineWidth: 2)
        }
        .allowsHitTesting(false)
    }

    private func cornerHandles(in rect: CGRect) -> some View {
        ForEach(Corner.allCases, id: \.self) { corner in
            Circle()
                .fill(LL.amber)
                .overlay(Circle().strokeBorder(LL.ink, lineWidth: 1.5))
                .frame(width: 18, height: 18)
                // A 44pt target around an 18pt dot: the corner is dragged with
                // a fingertip that hides it.
                .contentShape(Circle().size(width: 44, height: 44).offset(x: -13, y: -13))
                .position(point(value(of: corner), in: rect))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            guard rect.width > 1, rect.height > 1 else { return }
                            set(corner, to: normalized(drag.location, in: rect))
                        })
                .accessibilityLabel("\(corner.label) corner")
        }
    }

    private var detectionChip: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(detected == nil ? Color.white.opacity(0.5) : LL.amber)
                .frame(width: 7, height: 7)
            Text(detected == nil
                ? "No rectangle found · place the corners"
                : "Detected at capture · drag to adjust")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 11)
        .frame(height: 26)
        .background(.black.opacity(0.55), in: Capsule())
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("PAPER")
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.5)
                .foregroundStyle(.white.opacity(0.45))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(PerspectiveAspect.allCases, id: \.self) { option in
                        Button {
                            paper = option
                        } label: {
                            Text(option.label)
                                .font(.system(size: 12.5, weight: paper == option ? .bold : .semibold))
                                .foregroundStyle(paper == option ? LL.ink : .white.opacity(0.85))
                                .padding(.horizontal, 13)
                                .frame(height: 32)
                                .background(
                                    paper == option
                                        ? AnyShapeStyle(LL.amber)
                                        : AnyShapeStyle(Color.white.opacity(0.14)),
                                    in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(paper == option ? .isSelected : [])
                    }
                }
            }
            .padding(.top, 10)

            Text("Writes a new corrected page beside the original and replaces the old one. **The original photograph is never modified or deleted.**")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.62))
                // The canvas above takes the slack, so without this the
                // promise the sheet exists to make truncates to one line.
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    .white.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.top, 16)

            Button {
                replace()
            } label: {
                Text(primaryLabel)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(LLPrimaryButtonStyle())
            .disabled(isWorking || image == nil)
            .padding(.top, 14)

            if request.page.isCorrected {
                Button("Discard correction, keep original only") { discard() }
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color(red: 1, green: 107 / 255, blue: 107 / 255))
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 10)
                    .disabled(isWorking)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 20)
    }

    private var primaryLabel: String {
        if isWorking { return "Correcting…" }
        return request.page.isCorrected ? "Replace corrected page" : "Correct this page"
    }

    // MARK: - Geometry

    private enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight

        var label: String {
            switch self {
            case .topLeft: return "Top left"
            case .topRight: return "Top right"
            case .bottomLeft: return "Bottom left"
            case .bottomRight: return "Bottom right"
            }
        }
    }

    private func value(of corner: Corner) -> NormalizedQuad.Point {
        switch corner {
        case .topLeft: return quad.topLeft
        case .topRight: return quad.topRight
        case .bottomLeft: return quad.bottomLeft
        case .bottomRight: return quad.bottomRight
        }
    }

    private func set(_ corner: Corner, to value: NormalizedQuad.Point) {
        switch corner {
        case .topLeft: quad.topLeft = value
        case .topRight: quad.topRight = value
        case .bottomLeft: quad.bottomLeft = value
        case .bottomRight: quad.bottomRight = value
        }
    }

    private var imageSize: CGSize {
        guard let image else { return CGSize(width: 3, height: 4) }
        return CGSize(width: image.width, height: image.height)
    }

    /// Where the aspect-fitted image actually lands inside its container —
    /// the only rect the corners may be measured against, since everything in
    /// `NormalizedQuad` is a fraction of the *image*, not of the view.
    static func fittedRect(imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height)
    }

    /// Normalised (bottom-left origin) → view point. The one y flip in the
    /// chain, exactly as `NormalizedQuad` documents.
    private func point(_ corner: NormalizedQuad.Point, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: rect.minX + CGFloat(corner.x) * rect.width,
            y: rect.minY + CGFloat(1 - corner.y) * rect.height)
    }

    private func normalized(_ point: CGPoint, in rect: CGRect) -> NormalizedQuad.Point {
        NormalizedQuad.Point(
            x: min(max(Double((point.x - rect.minX) / rect.width), 0), 1),
            y: min(max(Double(1 - (point.y - rect.minY) / rect.height), 0), 1))
    }

    // MARK: - Work

    /// Decoded **with** its orientation applied: the sidecar's corners were
    /// measured in the capture's oriented space, so an overlay drawn over the
    /// raw sensor read-out would sit beside the page rather than on it.
    private func loadImage() async {
        let url = request.page.original
        image = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1600,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
    }

    private func replace() {
        guard !isWorking else { return }
        isWorking = true
        let source = request.page.original
        let quad = quad
        let aspect = paper
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<URL, Error> in
                do {
                    return .success(
                        try PerspectiveCorrector.writeCorrected(
                            from: source, quad: quad, aspect: aspect))
                } catch {
                    return .failure(error)
                }
            }.value
            isWorking = false
            switch result {
            case .success(let url):
                // A re-correction overwrites the SAME corrected file, so the
                // tile's URL doesn't change and nothing else would ever ask for
                // a fresh decode — unlike a first correction, which writes a
                // file nobody has cached yet.
                ProjectThumbnailCache.shared.invalidate(urls: [url])
                onFinish(.replaced(paper: aspect))
                dismiss()
            case .failure(let error):
                onFinish(.failed("Couldn't correct this page: \(error.localizedDescription)"))
                dismiss()
            }
        }
    }

    private func discard() {
        let corrected = PerspectiveCorrector.correctedURL(for: request.page.original)
        try? FileManager.default.removeItem(at: corrected)
        ProjectThumbnailCache.shared.invalidate(urls: [corrected])
        onFinish(.discarded)
        dismiss()
    }
}
