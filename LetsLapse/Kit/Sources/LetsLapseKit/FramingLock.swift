import Foundation
import CoreGraphics
#if canImport(CoreImage)
import CoreImage
#endif

/// A committed framing review, ready to apply: the per-photo shift that puts
/// the scene back on the reference framing, and the one crop margin every
/// photo shares. Built from a `FramingReview` whose plan has been committed
/// ("Stabilise photos"); nil otherwise, so a consumer that gets no lock
/// simply renders the photos as captured.
///
/// Geometry contract: the output has the SAME size as the input — the crop
/// is scaled back up, exactly as `FrameRotation` does — so overlays, masks,
/// canvas crops, reframe keys and the writer's pixel-buffer pool need no
/// knowledge of the lock. A photo the review never measured (added later,
/// or renamed) gets the shared crop and no shift, so the geometry stays
/// constant across the shoot even then.
public struct FramingLock: Equatable, Sendable {
    public let referenceX: Double
    public let referenceY: Double
    /// Margin kept on each side, source pixels.
    public let insetX: Double
    public let insetY: Double
    public let cropFraction: Double
    private let offsets: [String: Shift]

    private struct Shift: Equatable, Sendable {
        var dx: Double
        var dy: Double
    }

    /// `turnedBy`: quarter turns clockwise the picture has made since the
    /// review measured it (Rotate 90° as a record, 2026-09-24). A shift
    /// follows the scene — right becomes down, down becomes left — and the
    /// margins swap axes.
    public init?(review: FramingReview, turnedBy turns: Int = 0) {
        guard let stabilisation = review.stabilisation else { return nil }
        let quarter = QuarterTurns.normalized(turns)
        func turned(_ x: Double, _ y: Double) -> (Double, Double) {
            var point = (x, y)
            for _ in 0 ..< quarter { point = (-point.1, point.0) }
            return point
        }
        (referenceX, referenceY) = turned(stabilisation.referenceX, stabilisation.referenceY)
        (insetX, insetY) = quarter % 2 == 1
            ? (stabilisation.insetY, stabilisation.insetX) : (stabilisation.insetX, stabilisation.insetY)
        cropFraction = stabilisation.cropFraction
        var table: [String: Shift] = [:]
        table.reserveCapacity(review.frames.count)
        for frame in review.frames {
            let (dx, dy) = turned(frame.dx, frame.dy)
            table[frame.name] = Shift(dx: dx, dy: dy)
        }
        offsets = table
    }

    /// The lock beside `sourceFolder`'s frames, if the review there has been
    /// committed — turned by however far its project has turned since the
    /// photos were measured.
    public static func load(inSourceFolder folder: URL) -> FramingLock? {
        guard let review = FramingReview.load(inSourceFolder: folder) else { return nil }
        let now = ProjectOrientation.shared.turns(for: folder.appendingPathComponent(FramingReview.fileName))
        return FramingLock(review: review, turnedBy: now - (review.quarterTurns ?? 0))
    }

    public var inset: CGSize { CGSize(width: insetX, height: insetY) }

    public var frameCount: Int { offsets.count }

    public func isMeasured(_ name: String) -> Bool {
        offsets[name] != nil
    }

    /// How far this photo's content sits from the reference — the shift the
    /// lock undoes. Zero for an unmeasured photo.
    public func offset(forName name: String) -> CGVector {
        guard let shift = offsets[name] else { return .zero }
        return CGVector(dx: shift.dx - referenceX, dy: shift.dy - referenceY)
    }

    public func offset(for url: URL) -> CGVector {
        offset(forName: url.lastPathComponent)
    }

    /// The region of the photo the lock keeps, in the photo's own y-down
    /// pixels: the shared same-aspect crop, centred on the reference, which
    /// lands on the scene wherever the photo's content sits.
    public func cropRect(forName name: String, in size: CGSize) -> CGRect {
        let scale = FrameRotation.lockScale(width: size.width, height: size.height, inset: inset)
        let cropped = CGSize(width: size.width * scale, height: size.height * scale)
        let shift = offset(forName: name)
        return CGRect(
            x: (size.width - cropped.width) / 2 + shift.dx,
            y: (size.height - cropped.height) / 2 + shift.dy,
            width: cropped.width, height: cropped.height)
    }

    #if canImport(CoreImage)
    /// The photo locked (and levelled by `degrees`, when a rotation is on):
    /// one Core Image graph, output extent equal to input extent.
    public func levelled(_ image: CIImage, name: String, degrees: Double = 0) -> CIImage {
        FrameRotation.levelled(image, degrees: degrees, offset: offset(forName: name), lockInset: inset)
    }

    /// One shared context for the CGImage loader below — building one per
    /// frame would cost more than the resample.
    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// Wraps a still loader so every frame it hands back is locked. The
    /// shape `ImageStacker.stack(imageURLs:loadFrame:)` and
    /// `stackSequence(loadFrame:)` take.
    public func loader(
        base: @escaping (URL) throws -> CGImage, degrees: Double = 0
    ) -> (URL) throws -> CGImage {
        { url in
            let image = try base(url)
            let locked = self.levelled(CIImage(cgImage: image), name: url.lastPathComponent, degrees: degrees)
            let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
            let format: CIFormat = image.bitsPerComponent > 8 ? .RGBA16 : .RGBA8
            return Self.context.createCGImage(locked, from: locked.extent, format: format, colorSpace: space) ?? image
        }
    }
    #endif
}
