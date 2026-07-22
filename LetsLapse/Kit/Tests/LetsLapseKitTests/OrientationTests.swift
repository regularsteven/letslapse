import XCTest
import CoreGraphics
@testable import LetsLapseKit

/// Pins ImageStacker.oriented's EXIF handling with a 3x2 asymmetric grid:
///   10 20 30
///   40 50 60
final class OrientationTests: XCTestCase {
    private func grid() -> CGImage {
        makeGrayImage(width: 3, height: 2, values: [10, 20, 30, 40, 50, 60])
    }

    private func assertGray(_ image: CGImage, _ expected: [UInt8],
                            width: Int, height: Int,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(image.width, width, file: file, line: line)
        XCTAssertEqual(image.height, height, file: file, line: line)
        let values = grayValues(of: image)
        for (index, value) in expected.enumerated() {
            XCTAssertLessThanOrEqual(abs(Int(values[index]) - Int(value)), 1,
                "pixel \(index): got \(values[index]), expected \(value)", file: file, line: line)
        }
    }

    func testIdentity() {
        assertGray(ImageStacker.oriented(grid(), exifOrientation: 1),
                   [10, 20, 30, 40, 50, 60], width: 3, height: 2)
    }

    func testRotate180() {
        assertGray(ImageStacker.oriented(grid(), exifOrientation: 3),
                   [60, 50, 40, 30, 20, 10], width: 3, height: 2)
    }

    /// EXIF 6: stored image needs 90° clockwise for display.
    func testRotate90Clockwise() {
        assertGray(ImageStacker.oriented(grid(), exifOrientation: 6),
                   [40, 10, 50, 20, 60, 30], width: 2, height: 3)
    }

    /// EXIF 8: stored image needs 90° counter-clockwise for display.
    func testRotate90CounterClockwise() {
        assertGray(ImageStacker.oriented(grid(), exifOrientation: 8),
                   [30, 60, 20, 50, 10, 40], width: 2, height: 3)
    }

    func testMirrorHorizontal() {
        assertGray(ImageStacker.oriented(grid(), exifOrientation: 2),
                   [30, 20, 10, 60, 50, 40], width: 3, height: 2)
    }
}
