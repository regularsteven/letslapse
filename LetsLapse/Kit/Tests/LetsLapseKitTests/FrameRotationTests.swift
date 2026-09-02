import XCTest
import CoreImage
import CoreGraphics
@testable import LetsLapseKit

/// The fine-rotation geometry: the inscribed crop, the point maps that keep
/// text pinned to the scene, and the Core Image transform that produces the
/// same-size, no-black-corner output every consumer relies on.
final class FrameRotationTests: XCTestCase {

    // MARK: Scale

    func testZeroDegreesIsIdentity() {
        XCTAssertEqual(FrameRotation.inscribedScale(width: 1920, height: 1080, degrees: 0), 1)
        XCTAssertFalse(FrameRotation.isActive(0))
        XCTAssertFalse(FrameRotation.isActive(0.001))
        XCTAssertTrue(FrameRotation.isActive(0.01))
        XCTAssertEqual(FrameRotation.clamped(0.001), 0)
        XCTAssertEqual(FrameRotation.clamped(14), 10)
        XCTAssertEqual(FrameRotation.clamped(-14), -10)
    }

    func testInscribedScaleMatchesClosedForm() {
        // 16:9 at 10°: s = 1 / (cos θ + (16/9) sin θ) = 0.7731.
        let s = FrameRotation.inscribedScale(width: 1920, height: 1080, degrees: 10)
        XCTAssertEqual(s, 0.7731, accuracy: 0.0005)
        // Symmetric in sign and in orientation.
        XCTAssertEqual(FrameRotation.inscribedScale(width: 1920, height: 1080, degrees: -10), s, accuracy: 1e-9)
        XCTAssertEqual(FrameRotation.inscribedScale(width: 1080, height: 1920, degrees: 10), s, accuracy: 1e-9)
        // Square: s = 1 / (cos θ + sin θ).
        let square = FrameRotation.inscribedScale(width: 1000, height: 1000, degrees: 10)
        XCTAssertEqual(square, 1 / (cos(10 * Double.pi / 180) + sin(10 * Double.pi / 180)), accuracy: 1e-9)
    }

    /// Every corner of the inscribed crop, rotated back into the source, must
    /// lie inside the source — that is what "no black corners" means.
    func testInscribedCropCornersStayInsideSource() {
        for (w, h) in [(1920.0, 1080.0), (4032.0, 3024.0), (1080.0, 1920.0), (1000.0, 1000.0)] {
            for degrees in stride(from: -10.0, through: 10.0, by: 2.5) {
                let s = FrameRotation.inscribedScale(width: w, height: h, degrees: degrees)
                let theta = degrees * .pi / 180
                for (cx, cy) in [(-1.0, -1.0), (1.0, -1.0), (-1.0, 1.0), (1.0, 1.0)] {
                    // Crop corner in centred output pixels, un-rotated into source.
                    let u = cx * w * s / 2, v = cy * h * s / 2
                    let su = u * cos(-theta) - v * sin(-theta)
                    let sv = u * sin(-theta) + v * cos(-theta)
                    XCTAssertLessThanOrEqual(abs(su), w / 2 + 1e-6, "\(w)x\(h) @ \(degrees)°")
                    XCTAssertLessThanOrEqual(abs(sv), h / 2 + 1e-6, "\(w)x\(h) @ \(degrees)°")
                }
                // And the crop is tight: at least one corner touches an edge.
                var touches = false
                for (cx, cy) in [(1.0, 1.0), (1.0, -1.0)] {
                    let u = cx * w * s / 2, v = cy * h * s / 2
                    let su = u * cos(-theta) - v * sin(-theta)
                    let sv = u * sin(-theta) + v * cos(-theta)
                    if abs(abs(su) - w / 2) < 1e-6 || abs(abs(sv) - h / 2) < 1e-6 { touches = true }
                }
                XCTAssertTrue(touches || !FrameRotation.isActive(degrees), "\(w)x\(h) @ \(degrees)° is not tight")
            }
        }
    }

    // MARK: Point maps

    func testCentreIsFixed() {
        let centre = CGPoint(x: 0.5, y: 0.5)
        let out = FrameRotation.sourceToOutput(centre, width: 1920, height: 1080, degrees: 7)
        XCTAssertEqual(out.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(out.y, 0.5, accuracy: 1e-9)
    }

    func testMapsRoundTrip() {
        for degrees in [-10.0, -3.3, 0.0, 4.0, 10.0] {
            for point in [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.8, y: 0.9), CGPoint(x: 0.5, y: 0.05)] {
                let out = FrameRotation.sourceToOutput(point, width: 4032, height: 3024, degrees: degrees)
                let back = FrameRotation.outputToSource(out, width: 4032, height: 3024, degrees: degrees)
                XCTAssertEqual(back.x, point.x, accuracy: 1e-9)
                XCTAssertEqual(back.y, point.y, accuracy: 1e-9)
            }
        }
    }

    /// Positive degrees are CLOCKWISE on screen: a point on the right of the
    /// frame moves DOWN (top-left origin), a point above the centre moves right.
    func testPositiveIsClockwiseOnScreen() {
        let right = FrameRotation.sourceToOutput(
            CGPoint(x: 0.9, y: 0.5), width: 1000, height: 1000, degrees: 5)
        XCTAssertGreaterThan(right.y, 0.5)
        let top = FrameRotation.sourceToOutput(
            CGPoint(x: 0.5, y: 0.1), width: 1000, height: 1000, degrees: 5)
        XCTAssertGreaterThan(top.x, 0.5)
    }

    func testRemapComposesExactly() {
        let p = CGPoint(x: 0.3, y: 0.7)
        let a = FrameRotation.remap(p, width: 1920, height: 1080, from: 0, to: 4)
        let b = FrameRotation.remap(a, width: 1920, height: 1080, from: 4, to: -6)
        let c = FrameRotation.remap(b, width: 1920, height: 1080, from: -6, to: 0)
        XCTAssertEqual(c.x, p.x, accuracy: 1e-9)
        XCTAssertEqual(c.y, p.y, accuracy: 1e-9)
        XCTAssertEqual(FrameRotation.lengthScale(width: 1920, height: 1080, from: 3, to: 3), 1)
        XCTAssertGreaterThan(FrameRotation.lengthScale(width: 1920, height: 1080, from: 0, to: 10), 1.29)
    }

    // MARK: Core Image

    private let context = CIContext(options: [.useSoftwareRenderer: false])

    private func pixel(_ image: CIImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        var bytes = [UInt8](repeating: 0, count: 4)
        context.render(
            image, toBitmap: &bytes, rowBytes: 4,
            bounds: CGRect(x: x, y: y, width: 1, height: 1),
            format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return (bytes[0], bytes[1], bytes[2], bytes[3])
    }

    /// A gray frame with a red band along its top edge: after rotation and
    /// crop the extent is unchanged, every corner is still opaque picture
    /// (no black, no transparency), and the red band has tilted — the row
    /// that was uniformly red now differs between its left and right ends.
    func testRotatedKeepsExtentAndFillsCorners() throws {
        let size = CGSize(width: 640, height: 360)
        let gray = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
            .cropped(to: CGRect(origin: .zero, size: size))
        let band = CIImage(color: CIColor(red: 1, green: 0, blue: 0))
            .cropped(to: CGRect(x: 0, y: size.height - 40, width: size.width, height: 40))
        let source = band.composited(over: gray)

        let rotated = FrameRotation.rotated(source, degrees: 6)
        XCTAssertEqual(rotated.extent, CGRect(origin: .zero, size: size))

        for (x, y) in [(1, 1), (Int(size.width) - 2, 1), (1, Int(size.height) - 2),
                       (Int(size.width) - 2, Int(size.height) - 2)] {
            let p = pixel(rotated, x: x, y: y)
            XCTAssertEqual(p.a, 255, "corner (\(x),\(y)) is not opaque")
            XCTAssertGreaterThan(Int(p.r) + Int(p.g) + Int(p.b), 200, "corner (\(x),\(y)) went black")
        }
        // The picture and the point map must agree: for a spread of output
        // pixels, the source point `outputToSource` names is red exactly when
        // the rendered pixel is red. A clockwise turn drops the band's right
        // end, so the top-right output stays red and the top-left goes gray.
        for (x, y) in [(40, 12), (600, 12), (320, 12), (40, 200), (600, 348)] {
            let out = CGPoint(x: Double(x) / size.width, y: Double(y) / size.height)
            let src = FrameRotation.outputToSource(
                out, width: size.width, height: size.height, degrees: 6)
            let sourceY = src.y * size.height
            // Skip samples within a couple of pixels of the band's edge —
            // the Lanczos kernel blends there, and that is not the question.
            guard abs(sourceY - 40) > 2 else { continue }
            let inBand = sourceY < 40
            let p = pixel(rotated, x: x, y: Int(size.height) - 1 - y)
            if inBand {
                XCTAssertGreaterThan(p.r, 200, "output (\(x),\(y)) should be red")
                XCTAssertLessThan(p.g, 60, "output (\(x),\(y)) should be red")
            } else {
                XCTAssertLessThan(p.r, 160, "output (\(x),\(y)) should be gray")
            }
        }
        let topLeft = pixel(rotated, x: 40, y: Int(size.height) - 1 - 12)
        let topRight = pixel(rotated, x: 600, y: Int(size.height) - 1 - 12)
        XCTAssertLessThan(topLeft.r, 160, "top-left rotated out of the band")
        XCTAssertGreaterThan(topRight.r, 200, "top-right stays inside the band")
        XCTAssertEqual(FrameRotation.rotated(source, degrees: 0).extent, source.extent)
    }
}
