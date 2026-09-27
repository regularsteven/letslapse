import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension DNGArchive {

    /// Clone and compress's other two outputs (2026-09-27): every frame of a
    /// shoot rendered and written as HEIC or JPEG, optionally resized — the
    /// processed siblings of the DNG archive (`Converter`), which stays raw.
    ///
    /// With a `Renderer` (Clone and compress's *Apply edits*, 2026-09-27) a
    /// frame is the app's graded picture. Without one it is the file's own
    /// default rendering: a raw file through
    /// `LossyLinearDNG.rawFilter` (Apple's default rendering, the camera's
    /// orientation and the project's quarter turns applied), anything else
    /// through `OrientedDecode` (the file's own orientation and the turns).
    /// So the pixels come out upright and the clone carries no turns, the same
    /// as the DNG archive. The EXIF, TIFF, GPS and IPTC dictionaries travel;
    /// the orientation is written as up. Display P3, 8 bits.
    ///
    /// HEIC goes through the hardware HEVC encoder — the one video recording
    /// and the blend exports use. This runs from a project screen, never beside
    /// a capture, but an export encoding at the same time will share it.
    public final class StillsTranscoder: @unchecked Sendable {

        public enum Format: String, CaseIterable, Sendable {
            case heic, jpeg

            public var fileExtension: String { self == .heic ? "heic" : "jpg" }
            public var label: String { self == .heic ? "HEIC" : "JPEG" }
            var type: UTType { self == .heic ? .heic : .jpeg }

            /// Whether this machine can write it: ImageIO lists the HEIC
            /// encoder only where there is one.
            public var isAvailable: Bool {
                let types = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
                return types.contains(type.identifier)
            }
        }

        /// Renders one frame the way its project shows it — the app's grade
        /// engine, which the Kit cannot see — at no more than `maxLongEdge`
        /// pixels on the long edge (nil: full size), upright. Handed in by
        /// Clone and compress's *Apply edits*; without one a frame is the
        /// file's own default rendering. A closure rather than a flag so the
        /// finer bakes to come (white balance only, a flat grade for later
        /// editing) are just other closures.
        public typealias Renderer = @Sendable (_ input: URL, _ maxLongEdge: Int?) throws -> CGImage

        private let context = CIContext(options: [.cacheIntermediates: false])
        private let renderer: Renderer?

        public init(renderer: Renderer? = nil) {
            self.renderer = renderer
        }

        /// What the ledger and the bench call a run.
        public static func label(format: Format, megapixels: Double?, quality: Double) -> String {
            var parts = [format.rawValue, String(format: "q%.2f", quality)]
            if let megapixels { parts.append("\(Int(megapixels))MP") }
            return parts.joined(separator: " ")
        }

        /// One frame into `output`. `megapixels` only ever shrinks the
        /// picture; `quality` is ImageIO's lossy compression quality, 0…1.
        public func convert(_ input: URL, to output: URL, format: Format, megapixels: Double?, quality: Double) throws -> ConversionReport {
            let started = ProcessInfo.processInfo.systemUptime
            var mark = started
            var report = ConversionReport(input: input, output: output,
                                          strategy: Self.label(format: format, megapixels: megapixels, quality: quality))
            report.inputBytes = (try? input.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            func stage(_ name: String) {
                let now = ProcessInfo.processInfo.systemUptime
                report.stages.append((name, (now - mark) * 1000))
                mark = now
            }

            let rendered: CGImage
            if let renderer {
                var maxLongEdge: Int?
                if let megapixels, let size = Self.pixelSize(of: input) {
                    let scale = Self.scale(for: size, megapixels: megapixels)
                    if scale < 1 { maxLongEdge = Int((max(size.width, size.height) * scale).rounded()) }
                }
                rendered = try renderer(input, maxLongEdge)
                report.decodePath = "grade"
            } else {
                rendered = try decodeAndRender(input, megapixels: megapixels, report: &report)
            }
            stage("decode+render")

            var properties = Self.metadata(of: input, width: rendered.width, height: rendered.height)
            properties[kCGImageDestinationLossyCompressionQuality] = quality
            guard let destination = CGImageDestinationCreateWithURL(output as CFURL, format.type.identifier as CFString, 1, nil) else {
                throw ConversionError.encode("\(format.label) is not available on this device")
            }
            CGImageDestinationAddImage(destination, rendered, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                throw ConversionError.encode("\(output.lastPathComponent): the \(format.label) encoder failed")
            }
            stage("encode")

            report.width = rendered.width
            report.height = rendered.height
            report.outputBytes = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            report.totalMilliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1000
            return report
        }

        /// The file's own default rendering: a raw file through
        /// `LossyLinearDNG.rawFilter` (shrunk by the filter itself), anything
        /// else through `OrientedDecode` and a Lanczos scale — Display P3.
        private func decodeAndRender(_ input: URL, megapixels: Double?, report: inout ConversionReport) throws -> CGImage {
            var picture: CIImage
            if ImportedStills.isRaw(input) {
                guard let filter = LossyLinearDNG.rawFilter(for: input) else {
                    throw ConversionError.decode("\(input.lastPathComponent): no raw decoder")
                }
                if let megapixels, let native = filter.outputImage?.extent.size {
                    let scale = Self.scale(for: native, megapixels: megapixels)
                    if scale < 1 { filter.scaleFactor = Float(scale) }
                }
                guard let image = filter.outputImage else {
                    throw ConversionError.decode("\(input.lastPathComponent): the raw decoder gave no picture")
                }
                picture = image
                report.decodePath = "CIRAWFilter"
            } else {
                guard let image = OrientedDecode.ciImage(url: input, maxPixelSize: 1 << 16) else {
                    throw ConversionError.decode("\(input.lastPathComponent): ImageIO could not read it")
                }
                picture = image
                report.decodePath = "ImageIO"
                if let megapixels {
                    let scale = Self.scale(for: picture.extent.size, megapixels: megapixels)
                    if scale < 1 {
                        picture = picture.applyingFilter("CILanczosScaleTransform", parameters: [
                            kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0,
                        ])
                    }
                }
            }
            picture = picture.transformed(by: CGAffineTransform(translationX: -picture.extent.minX, y: -picture.extent.minY))
            let extent = CGRect(origin: .zero, size: CGSize(width: floor(picture.extent.width), height: floor(picture.extent.height)))
            guard extent.width > 0, extent.height > 0,
                  let colorSpace = CGColorSpace(name: CGColorSpace.displayP3),
                  let rendered = context.createCGImage(picture, from: extent, format: .RGBA8, colorSpace: colorSpace) else {
                throw ConversionError.decode("\(input.lastPathComponent): could not render")
            }
            return rendered
        }

        /// Converts `files` in order into `directory` (same base name, the
        /// format's extension), `inFlight` at a time — the shape of
        /// `Converter.convert(files:…)`, so the app's job and sheet read both.
        public func convert(
            files: [URL], to directory: URL, format: Format, megapixels: Double?, quality: Double, inFlight: Int = 2,
            shouldContinue: @escaping @Sendable () -> Bool = { true },
            progress: @escaping @Sendable (Converter.SequenceProgress) -> Void = { _ in }
        ) -> Converter.SequenceResult {
            let started = ProcessInfo.processInfo.systemUptime
            var reports = [ConversionReport?](repeating: nil, count: files.count)
            var failures: [(URL, String)] = []
            let lock = NSLock()
            var done = 0, inBytes = 0, outBytes = 0
            let semaphore = DispatchSemaphore(value: max(1, inFlight))
            let group = DispatchGroup()
            let queue = DispatchQueue(label: "letslapse.stills-transcode", qos: .userInitiated, attributes: .concurrent)
            for (index, input) in files.enumerated() {
                guard shouldContinue() else { break }
                semaphore.wait()
                group.enter()
                queue.async {
                    defer { semaphore.signal(); group.leave() }
                    let output = directory.appendingPathComponent(
                        input.deletingPathExtension().lastPathComponent + "." + format.fileExtension)
                    do {
                        let report = try autoreleasepool {
                            try self.convert(input, to: output, format: format, megapixels: megapixels, quality: quality)
                        }
                        lock.lock()
                        reports[index] = report
                        done += 1
                        inBytes += report.inputBytes
                        outBytes += report.outputBytes
                        let snapshot = Converter.SequenceProgress(
                            framesDone: done, framesTotal: files.count, inputBytes: inBytes, outputBytes: outBytes,
                            lastReport: report, elapsedSeconds: ProcessInfo.processInfo.systemUptime - started)
                        lock.unlock()
                        progress(snapshot)
                    } catch {
                        try? FileManager.default.removeItem(at: output)
                        lock.lock()
                        failures.append((input, "\(error)"))
                        done += 1
                        let snapshot = Converter.SequenceProgress(
                            framesDone: done, framesTotal: files.count, inputBytes: inBytes, outputBytes: outBytes,
                            lastReport: nil, elapsedSeconds: ProcessInfo.processInfo.systemUptime - started)
                        lock.unlock()
                        progress(snapshot)
                    }
                }
            }
            group.wait()
            return Converter.SequenceResult(reports: reports.compactMap { $0 }, failures: failures,
                                            elapsedSeconds: ProcessInfo.processInfo.systemUptime - started)
        }

        /// The linear scale that brings `size` down to `megapixels`; 1 or
        /// more means no shrink.
        /// The stored pixel size ImageIO reports, before orientation — the
        /// same count either way round, which is all the scale needs.
        static func pixelSize(of input: URL) -> CGSize? {
            guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else { return nil }
            return CGSize(width: width, height: height)
        }

        static func scale(for size: CGSize, megapixels: Double) -> Double {
            let pixels = Double(size.width * size.height)
            guard pixels > 0, megapixels > 0 else { return 1 }
            return min(1, (megapixels * 1_000_000 / pixels).squareRoot())
        }

        /// The source's descriptive metadata for the new file: EXIF, TIFF,
        /// GPS, IPTC and the EXIF auxiliary dictionary, with the orientation
        /// written as up (the pixels already are) and the pixel dimensions
        /// set to what was written. Raw-only dictionaries stay behind.
        static func metadata(of input: URL, width: Int, height: Int) -> [CFString: Any] {
            guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
                  let all = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
                return [kCGImagePropertyOrientation: 1]
            }
            var out: [CFString: Any] = [kCGImagePropertyOrientation: 1]
            for key in [kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary, kCGImagePropertyExifAuxDictionary] {
                if let value = all[key] { out[key] = value }
            }
            if var exif = all[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                exif[kCGImagePropertyExifPixelXDimension] = width
                exif[kCGImagePropertyExifPixelYDimension] = height
                out[kCGImagePropertyExifDictionary] = exif
            }
            if var tiff = all[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFOrientation] = 1
                out[kCGImagePropertyTIFFDictionary] = tiff
            }
            return out
        }
    }
}
