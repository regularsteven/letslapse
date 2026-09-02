import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

/// One decoded master frame, in presentation order, with its presentation
/// time. Buffers are 32BGRA.
public struct TimeSliceFrame {
    public let pixelBuffer: CVPixelBuffer
    public let seconds: Double

    public init(pixelBuffer: CVPixelBuffer, seconds: Double) {
        self.pixelBuffer = pixelBuffer
        self.seconds = seconds
    }
}

/// An ordered source of decoded frames for the time-slicing pass. The v1
/// provider decodes a finished blended clip; the protocol is what lets the
/// parked "re-slice an existing blended clip" path reuse the pass unchanged —
/// any ordered frame source with a known count qualifies.
public protocol OrderedFrameProvider: AnyObject {
    /// Exact total frames, known before iteration — the sampler's trim and
    /// the poster ladder both need it exact, not estimated.
    var frameCount: Int { get }
    /// The master's display transform. Band geometry is computed in encoded
    /// pixel space; the requested display-space edge is mapped through this.
    var transform: CGAffineTransform { get }
    /// Nominal frame rate, for the encoder's bitrate policy only — sliced
    /// PTS are carried from the master, never re-derived from this.
    var nominalFPS: Double { get }
    /// The next frame in presentation order; nil at the end.
    func next() throws -> TimeSliceFrame?
}

/// Decodes a video file's frames in presentation order as 32BGRA. Counts the
/// frames exactly up front with a compressed (no-decode) pass, so the
/// renderer never works from a duration×fps estimate.
public final class AssetFrameProvider: OrderedFrameProvider {
    public let frameCount: Int
    public let transform: CGAffineTransform
    public let nominalFPS: Double

    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput

    public init(url: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw LapseError.noVideoTrack(url)
        }
        let (preferredTransform, fps) = try await track.load(.preferredTransform, .nominalFrameRate)
        transform = preferredTransform
        nominalFPS = fps > 0 ? Double(fps) : 30

        // Counting pass: nil output settings deliver the compressed samples,
        // so the count is exact and costs no decode.
        let counter = try AVAssetReader(asset: asset)
        let countOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        countOutput.alwaysCopiesSampleData = false
        guard counter.canAdd(countOutput) else {
            throw LapseError.readerFailed("cannot attach counting output")
        }
        counter.add(countOutput)
        guard counter.startReading() else {
            throw LapseError.readerFailed(counter.error?.localizedDescription ?? "could not start counting")
        }
        // Sum sample counts rather than counting buffers: the passthrough
        // output interleaves zero-sample marker buffers among the real
        // samples, and chunked passthrough can carry several per buffer.
        var count = 0
        while let sample = countOutput.copyNextSampleBuffer() {
            count += CMSampleBufferGetNumSamples(sample)
        }
        if counter.status == .failed {
            throw LapseError.readerFailed(counter.error?.localizedDescription ?? "counting failed")
        }
        frameCount = count

        reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw LapseError.readerFailed("cannot attach track output")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw LapseError.readerFailed(reader.error?.localizedDescription ?? "could not start decoding")
        }
    }

    public func next() throws -> TimeSliceFrame? {
        while true {
            guard let sample = output.copyNextSampleBuffer() else {
                if reader.status == .failed {
                    throw LapseError.readerFailed(reader.error?.localizedDescription ?? "decode error")
                }
                return nil
            }
            if let buffer = CMSampleBufferGetImageBuffer(sample) {
                let seconds = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                return TimeSliceFrame(pixelBuffer: buffer, seconds: seconds.isFinite ? seconds : 0)
            }
        }
    }

    deinit {
        if reader.status == .reading { reader.cancelReading() }
    }
}

public struct TimeSliceRenderResult: Sendable {
    public var masterFrames: Int
    public var outputFrames: Int
    public var width: Int
    public var height: Int
    public var wrotePoster: Bool
    /// Grid runs only: the geometry that was actually laid down — cell size,
    /// effective row count, edge crop. Documented in the output's metadata
    /// because the row count is derived, not asked for (§5.1).
    public var grid: TimeSliceGridLayout?
    /// The ladder's span in master frames — what the animation was trimmed by.
    public var maxLagFrames: Int

    public init(
        masterFrames: Int, outputFrames: Int, width: Int, height: Int,
        wrotePoster: Bool, grid: TimeSliceGridLayout? = nil, maxLagFrames: Int = 0
    ) {
        self.masterFrames = masterFrames
        self.outputFrames = outputFrames
        self.width = width
        self.height = height
        self.wrotePoster = wrotePoster
        self.grid = grid
        self.maxLagFrames = maxLagFrames
    }
}

/// The time-slicing pass — stage 1.5 of `docs/time-slicing.md`. Reads the
/// master in one sequential pass and recomposes each sliced frame from bands
/// of differently-lagged master frames; optionally composes the full-source
/// poster from the same pass. Runs as the LAST tail pass over the finished
/// blended clip, because only that file has uniform, final-geometry,
/// grade-baked frames on every engine path (plan §2).
///
/// Memory is flat by design: the animation's history lives in a band spool on
/// disk — one ring of `lag` records per band, Σ lag[j] ≈ maxLag/2 frames of
/// bytes total — because any in-RAM retention floors at half the spread in
/// full frames (plan §1). The poster needs no spool at all: each master frame
/// contributes at most one band to a single composite.
public final class TimeSliceRenderer {

    private let cancelLock = NSLock()
    private var cancelFlag = false

    public init() {}

    public func cancel() {
        cancelLock.lock()
        cancelFlag = true
        cancelLock.unlock()
    }

    private var isCancelled: Bool {
        cancelLock.lock()
        defer { cancelLock.unlock() }
        return cancelFlag
    }

    /// Renders the sliced animation to `animationURL` and/or the full-source
    /// poster to `posterURL` (its format inferred from the extension, PNG by
    /// default). Sliced PTS are the master's own, so a capture-clock-timed
    /// interval blend keeps its pacing; the animation is `maxLag` frames
    /// shorter than the master — the trim policy (plan §4 Q2).
    public func render(
        provider: OrderedFrameProvider,
        settings: TimeSliceSettings,
        animationURL: URL?,
        posterURL: URL?,
        codec: OutputCodec = .h264,
        posterMetadata: [CFString: Any]? = nil,
        spoolDirectory: URL? = nil,
        progress: ((Double) -> Void)? = nil
    ) throws -> TimeSliceRenderResult {
        let masterFrames = provider.frameCount
        guard masterFrames >= 1 else { throw LapseError.noInputFrames }
        guard animationURL != nil || posterURL != nil else {
            throw LapseError.timeSliceInvalid("nothing to render — no animation or poster output was requested")
        }

        // The banded ladder is known before a single pixel is touched, so its
        // refusal comes first, exactly as it always has. A grid's ladder spans
        // a row count derived from the frame's own aspect, so the identical
        // check runs below, once the first frame has been peeked.
        if settings.grid == nil {
            let ladder = TimeSliceGeometry.lagLadder(
                segments: settings.segments, offsetFrames: settings.offsetFrames,
                distribution: settings.distribution)
            let maxLag = ladder.last ?? 0
            let animationFrames = TimeSliceGeometry.slicedFrameCount(masterFrames: masterFrames, maxLag: maxLag)
            if animationURL != nil, animationFrames < 1 {
                throw LapseError.timeSliceInvalid(
                    "the spread (\(maxLag) frames) consumes the whole clip (\(masterFrames) frames) — "
                    + "reduce segments or offset")
            }
        }

        // First-frame peek for the true dimensions before any geometry.
        guard let firstFrame = try provider.next() else { throw LapseError.noInputFrames }
        var pendingFrame: TimeSliceFrame? = firstFrame
        let width = CVPixelBufferGetWidth(firstFrame.pixelBuffer)
        let height = CVPixelBufferGetHeight(firstFrame.pixelBuffer)

        // Bands and cells are the same thing to the loop below — a rect and a
        // lag — so the two geometries meet here and the pass is one code path
        // from this line on.
        let plan = try Self.makePlan(
            settings: settings, width: width, height: height,
            transform: provider.transform, masterFrames: masterFrames,
            wantsPoster: posterURL != nil)
        let bandRects = plan.cellRects
        let bandLags = plan.cellLags
        let maxLag = plan.maxLag
        if animationURL != nil,
           TimeSliceGeometry.slicedFrameCount(masterFrames: masterFrames, maxLag: maxLag) < 1 {
            throw LapseError.timeSliceInvalid(
                "the spread (\(maxLag) frames) consumes the whole clip (\(masterFrames) frames) — "
                + "reduce segments or offset")
        }

        // Poster: master index → the bands it fills (short masters repeat).
        let posterBands = plan.posterCells
        var posterPixels: [UInt8] = []
        if posterURL != nil {
            posterPixels = [UInt8](repeating: 0, count: width * height * 4)
        }

        // Animation state: writer, PTS ring, and the disk spool.
        var writer: AVAssetWriter?
        var writerInput: AVAssetWriterInput?
        var adaptor: AVAssetWriterInputPixelBufferAdaptor?
        var spool: TimeSliceBandSpool?
        var ptsRing = [Double]()
        defer { spool?.removeFiles() }

        if let animationURL {
            try? FileManager.default.removeItem(at: animationURL)
            let assetWriter: AVAssetWriter
            do {
                assetWriter = try AVAssetWriter(outputURL: animationURL, fileType: codec.fileType)
            } catch {
                throw LapseError.writerFailed(error.localizedDescription)
            }
            let videoSettings: [String: Any]
            switch codec {
            case .h264, .hevc:
                let policy = VideoEncodePolicy(
                    profile: codec == .hevc ? .hevcMain10 : .h264High8Bit,
                    width: width, height: height, fps: provider.nominalFPS)
                videoSettings = policy.videoSettings
            case .prores:
                videoSettings = [
                    AVVideoCodecKey: codec.avCodec,
                    AVVideoWidthKey: width,
                    AVVideoHeightKey: height,
                    AVVideoColorPropertiesKey: VideoEncodePolicy.colorProperties,
                ]
            case .jpeg:
                videoSettings = [
                    AVVideoCodecKey: codec.avCodec,
                    AVVideoWidthKey: width,
                    AVVideoHeightKey: height,
                    AVVideoCompressionPropertiesKey: [AVVideoQualityKey: 0.95],
                ]
            }
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            input.expectsMediaDataInRealTime = false
            input.transform = provider.transform
            let bufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height,
                ])
            guard assetWriter.canAdd(input) else { throw LapseError.writerFailed("cannot attach video input") }
            assetWriter.add(input)
            guard assetWriter.startWriting() else {
                throw LapseError.writerFailed(assetWriter.error?.localizedDescription ?? "could not start encoding")
            }
            assetWriter.startSession(atSourceTime: .zero)
            writer = assetWriter
            writerInput = input
            adaptor = bufferAdaptor
            ptsRing = [Double](repeating: 0, count: maxLag + 1)
            spool = try TimeSliceBandSpool(
                directory: spoolDirectory ?? FileManager.default.temporaryDirectory,
                bandRects: bandRects, bandLags: bandLags)
        }
        defer {
            if let writer, writer.status == .writing { writer.cancelWriting() }
        }

        // Packed scratch for one band record on its way out of the spool.
        let largestRecord = bandRects.map(\.packedBytes).max() ?? 0
        var recordScratch = [UInt8](repeating: 0, count: largestRecord)
        var outputFrames = 0

        for master in 0..<masterFrames {
            if isCancelled || Task.isCancelled { throw LapseError.cancelled }
            // The pool is load-bearing, not hygiene: decoded sample buffers
            // and every FileHandle read are autoreleased, and this loop reads
            // a frame's worth of spool bytes per iteration — without the pool,
            // memory tracks bytes read 1:1 until the process is killed (the
            // same trap the project-transfer pump hit).
            try autoreleasepool {
            let frame: TimeSliceFrame
            if let pending = pendingFrame {
                frame = pending
                pendingFrame = nil
            } else if let next = try provider.next() {
                frame = next
            } else {
                throw LapseError.readerFailed("master ended early at frame \(master) of \(masterFrames)")
            }
            let buffer = frame.pixelBuffer
            let actualWidth = CVPixelBufferGetWidth(buffer)
            let actualHeight = CVPixelBufferGetHeight(buffer)
            guard actualWidth == width, actualHeight == height else {
                throw LapseError.sizeMismatch(
                    expectedWidth: width, expectedHeight: height,
                    actualWidth: actualWidth, actualHeight: actualHeight)
            }

            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else {
                throw LapseError.readerFailed("frame \(master) has no base address")
            }
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)

            if !posterBands.isEmpty, let bands = posterBands[master] {
                for band in bands {
                    let rect = bandRects[band]
                    posterPixels.withUnsafeMutableBytes { poster in
                        Self.copyBandDirect(
                            from: base, sourceBytesPerRow: bytesPerRow,
                            to: poster.baseAddress!, destBytesPerRow: width * 4, rect: rect)
                    }
                }
            }

            if let adaptor, let writerInput, let writer, let spool {
                ptsRing[master % ptsRing.count] = frame.seconds
                let outputIndex = master - maxLag
                if outputIndex >= 0 {
                    while !writerInput.isReadyForMoreMediaData {
                        if writer.status == .failed {
                            throw LapseError.writerFailed(writer.error?.localizedDescription ?? "encoder failed")
                        }
                        usleep(1000)
                    }
                    guard let pool = adaptor.pixelBufferPool else {
                        throw LapseError.writerFailed("no pixel buffer pool")
                    }
                    var outBuffer: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &outBuffer)
                    guard let outBuffer else { throw LapseError.writerFailed("buffer allocation failed") }
                    CVPixelBufferLockBaseAddress(outBuffer, [])
                    guard let outBase = CVPixelBufferGetBaseAddress(outBuffer) else {
                        CVPixelBufferUnlockBaseAddress(outBuffer, [])
                        throw LapseError.writerFailed("output buffer has no base address")
                    }
                    let outBytesPerRow = CVPixelBufferGetBytesPerRow(outBuffer)
                    for (band, rect) in bandRects.enumerated() {
                        let lag = bandLags[band]
                        if lag == 0 {
                            Self.copyBandDirect(
                                from: base, sourceBytesPerRow: bytesPerRow,
                                to: outBase, destBytesPerRow: outBytesPerRow, rect: rect)
                        } else {
                            try recordScratch.withUnsafeMutableBytes { scratch in
                                try spool.read(band: band, masterIndex: master - lag, into: scratch.baseAddress!)
                                Self.pasteBand(
                                    fromPacked: scratch.baseAddress!, rect: rect,
                                    to: outBase, destBytesPerRow: outBytesPerRow)
                            }
                        }
                    }
                    CVPixelBufferUnlockBaseAddress(outBuffer, [])
                    VideoEncodePolicy.tagColor(outBuffer)
                    let seconds = ptsRing[outputIndex % ptsRing.count]
                    let time = CMTime(value: Int64((seconds * 60000).rounded()), timescale: 60000)
                    guard adaptor.append(outBuffer, withPresentationTime: time) else {
                        throw LapseError.writerFailed(writer.error?.localizedDescription ?? "frame append failed")
                    }
                    outputFrames += 1
                }
                // Spool this frame's bands for the emits that still need them
                // — after the read above, so each ring slot is dead before it
                // is overwritten.
                for (band, rect) in bandRects.enumerated() {
                    let lag = bandLags[band]
                    guard lag > 0, master + lag < masterFrames else { continue }
                    try recordScratch.withUnsafeMutableBytes { scratch in
                        Self.packBand(
                            from: base, sourceBytesPerRow: bytesPerRow, rect: rect,
                            intoPacked: scratch.baseAddress!)
                        try spool.write(band: band, masterIndex: master, from: scratch.baseAddress!)
                    }
                }
            }

            progress?(Double(master + 1) / Double(masterFrames))
            }
        }

        if let writer, let writerInput {
            writerInput.markAsFinished()
            let finished = DispatchSemaphore(value: 0)
            writer.finishWriting { finished.signal() }
            finished.wait()
            guard writer.status == .completed else {
                throw LapseError.writerFailed(writer.error?.localizedDescription ?? "could not finalize file")
            }
        }

        var wrotePoster = false
        if let posterURL {
            let image = try Self.makeImage(fromBGRA: posterPixels, width: width, height: height)
            let oriented = try Self.displayOriented(image, transform: provider.transform)
            let format = ImageFormat.infer(from: posterURL) ?? .png
            try ImageExporter.write(oriented, to: posterURL, format: format, metadata: posterMetadata)
            wrotePoster = true
        }

        return TimeSliceRenderResult(
            masterFrames: masterFrames, outputFrames: outputFrames,
            width: width, height: height, wrotePoster: wrotePoster,
            grid: plan.gridLayout, maxLagFrames: maxLag)
    }

    // MARK: - The plan

    /// What the pass executes: a rect and a lag per cell, and which cells each
    /// master frame fills in the poster. Bands are cells that happen to span
    /// the whole of the other axis.
    struct SlicePlan {
        let cellRects: [BandRect]
        let cellLags: [Int]
        let posterCells: [Int: [Int]]
        let maxLag: Int
        let gridLayout: TimeSliceGridLayout?
    }

    /// Builds the plan for either geometry.
    ///
    /// The two geometries stay separate **by decision** (brief §5.3). A grid
    /// is not a superset of a band on this code's terms: bands distribute
    /// their division remainder Bresenham-style across every band, while the
    /// grid's square-cell rule fixes an integer cell and crops the outer
    /// row/column instead. Those produce different boundaries for the same
    /// count, and the banded distribution is the shipped, measured behaviour —
    /// so it is reproduced here verbatim rather than re-derived. What IS
    /// shared, and is where the cost lives, is everything downstream of this
    /// function: one decode pass, one spool, one composite loop, one encoder.
    static func makePlan(
        settings: TimeSliceSettings, width: Int, height: Int,
        transform: CGAffineTransform, masterFrames: Int, wantsPoster: Bool
    ) throws -> SlicePlan {
        if let grid = settings.grid {
            return try gridPlan(
                settings: settings, grid: grid, width: width, height: height,
                transform: transform, masterFrames: masterFrames, wantsPoster: wantsPoster)
        }
        return try bandedPlan(
            settings: settings, width: width, height: height,
            transform: transform, masterFrames: masterFrames, wantsPoster: wantsPoster)
    }

    private static func bandedPlan(
        settings: TimeSliceSettings, width: Int, height: Int,
        transform: CGAffineTransform, masterFrames: Int, wantsPoster: Bool
    ) throws -> SlicePlan {
        let ladder = TimeSliceGeometry.lagLadder(
            segments: settings.segments, offsetFrames: settings.offsetFrames,
            distribution: settings.distribution)
        // The user's edge is display-space; geometry runs in encoded pixel
        // space, so a rotated master (portrait video shoots) maps its edge
        // through the transform.
        let newestEdge = Self.encodedEdge(displayEdge: settings.newestEdge, transform: transform)
        let axisLength = newestEdge.axis == .vertical ? width : height
        guard let ranges = TimeSliceGeometry.bandRanges(axisLength: axisLength, segments: settings.segments) else {
            throw LapseError.timeSliceInvalid(
                "\(settings.segments) segments across \(axisLength) px makes bands thinner than "
                + "\(TimeSliceGeometry.minimumBandPixels) px")
        }
        let bandRects: [BandRect] = ranges.map { range in
            newestEdge.axis == .vertical
                ? BandRect(x: range.lowerBound, y: 0, width: range.count, height: height)
                : BandRect(x: 0, y: range.lowerBound, width: width, height: range.count)
        }
        let bandLags = TimeSliceGeometry.bandLags(ladder: ladder, newestEdge: newestEdge)

        var posterBands: [Int: [Int]] = [:]
        if wantsPoster {
            guard let posterIndices = TimeSliceGeometry.posterIndices(
                masterFrames: masterFrames, segments: settings.segments) else {
                throw LapseError.timeSliceInvalid("a poster needs at least 2 segments")
            }
            let geometric = newestEdge.newestLeadsGeometry ? posterIndices : posterIndices.reversed()
            for (band, master) in geometric.enumerated() {
                posterBands[master, default: []].append(band)
            }
        }
        return SlicePlan(
            cellRects: bandRects, cellLags: bandLags, posterCells: posterBands,
            maxLag: ladder.last ?? 0, gridLayout: nil)
    }

    private static func gridPlan(
        settings: TimeSliceSettings, grid: TimeSliceGrid, width: Int, height: Int,
        transform: CGAffineTransform, masterFrames: Int, wantsPoster: Bool
    ) throws -> SlicePlan {
        // Columns are counted along the axis the VIEWER sees as horizontal
        // (§5.1), which on a rotated master is not the encoded X axis. Both
        // display axes are mapped into encoded space the same way a banded
        // edge is, and the layout is resolved in display lengths so the cells
        // come out square on screen rather than in the file.
        var columnAxis = Self.encodedAxis(displayEdge: .left, transform: transform)
        var rowAxis = Self.encodedAxis(displayEdge: .top, transform: transform)
        if columnAxis.isX == rowAxis.isX {
            // A transform that collapses both display axes onto one encoded
            // axis is not a rotation or a flip; fall back to identity rather
            // than build a degenerate grid.
            columnAxis = EncodedAxis(isX: true, reversed: false)
            rowAxis = EncodedAxis(isX: false, reversed: false)
        }
        let displayWidth = columnAxis.isX ? width : height
        let displayHeight = rowAxis.isX ? width : height
        guard let layout = TimeSliceGridGeometry.layout(
            width: displayWidth, height: displayHeight, columns: settings.segments) else {
            throw LapseError.timeSliceInvalid(
                "\(settings.segments) columns across \(displayWidth) px makes grid cells thinner than "
                + "\(TimeSliceGridGeometry.minimumCellPixels) px, or leaves fewer than two rows")
        }

        var rects: [BandRect] = []
        rects.reserveCapacity(layout.cellCount)
        for row in 0..<layout.rows {
            for column in 0..<layout.columns {
                let columnRange = layout.columnRanges[
                    columnAxis.reversed ? layout.columns - 1 - column : column]
                let rowRange = layout.rowRanges[rowAxis.reversed ? layout.rows - 1 - row : row]
                let xRange = columnAxis.isX ? columnRange : rowRange
                let yRange = columnAxis.isX ? rowRange : columnRange
                rects.append(BandRect(
                    x: xRange.lowerBound, y: yRange.lowerBound,
                    width: xRange.count, height: yRange.count))
            }
        }

        let lags = TimeSliceGridGeometry.lagLadder(
            columns: layout.columns, rows: layout.rows, origin: grid.origin,
            metric: grid.metric, offsetFrames: settings.offsetFrames)

        var posterCells: [Int: [Int]] = [:]
        if wantsPoster {
            guard let indices = TimeSliceGridGeometry.posterIndices(
                masterFrames: masterFrames, columns: layout.columns, rows: layout.rows,
                origin: grid.origin, metric: grid.metric) else {
                throw LapseError.timeSliceInvalid("a grid poster needs at least 2 columns")
            }
            for (cell, master) in indices.enumerated() {
                posterCells[master, default: []].append(cell)
            }
        }
        return SlicePlan(
            cellRects: rects, cellLags: lags, posterCells: posterCells,
            maxLag: lags.max() ?? 0, gridLayout: layout)
    }

    // MARK: - Edge mapping

    /// Maps a display-space edge to the encoded-space edge that feeds it: the
    /// inverse of the master's transform applied to the edge's outward
    /// normal, dominant component wins. Identity transforms map every edge to
    /// itself; a 90° portrait transform maps display-left to encoded-bottom.
    static func encodedEdge(displayEdge: TimeSliceEdge, transform: CGAffineTransform) -> TimeSliceEdge {
        guard transform != .identity else { return displayEdge }
        let normal: (dx: CGFloat, dy: CGFloat)
        switch displayEdge {
        case .left: normal = (-1, 0)
        case .right: normal = (1, 0)
        case .top: normal = (0, -1)
        case .bottom: normal = (0, 1)
        }
        let inverse = transform.inverted()
        let dx = inverse.a * normal.dx + inverse.c * normal.dy
        let dy = inverse.b * normal.dx + inverse.d * normal.dy
        if abs(dx) >= abs(dy) {
            return dx < 0 ? .left : .right
        }
        return dy < 0 ? .top : .bottom
    }

    /// Where one display axis lands in encoded space: which encoded axis
    /// carries it, and whether its index order is reversed. The grid needs
    /// both display axes at once, so it asks in these terms rather than in
    /// edges.
    struct EncodedAxis {
        let isX: Bool
        let reversed: Bool
    }

    static func encodedAxis(displayEdge: TimeSliceEdge, transform: CGAffineTransform) -> EncodedAxis {
        switch encodedEdge(displayEdge: displayEdge, transform: transform) {
        case .left: return EncodedAxis(isX: true, reversed: false)
        case .right: return EncodedAxis(isX: true, reversed: true)
        case .top: return EncodedAxis(isX: false, reversed: false)
        case .bottom: return EncodedAxis(isX: false, reversed: true)
        }
    }

    // MARK: - Band copies

    struct BandRect {
        let x: Int, y: Int, width: Int, height: Int
        /// The band packed tight: `width × 4` bytes per row.
        var packedBytes: Int { width * height * 4 }
    }

    /// Band → packed record (spool writes): tight rows of `width × 4` bytes.
    private static func packBand(
        from source: UnsafeRawPointer, sourceBytesPerRow: Int, rect: BandRect,
        intoPacked dest: UnsafeMutableRawPointer
    ) {
        let rowBytes = rect.width * 4
        for row in 0..<rect.height {
            let src = source + (rect.y + row) * sourceBytesPerRow + rect.x * 4
            memcpy(dest + row * rowBytes, src, rowBytes)
        }
    }

    /// Packed record → band of a pixel buffer (spool reads).
    private static func pasteBand(
        fromPacked source: UnsafeRawPointer, rect: BandRect,
        to dest: UnsafeMutableRawPointer, destBytesPerRow: Int
    ) {
        let rowBytes = rect.width * 4
        for row in 0..<rect.height {
            let src = source + row * rowBytes
            let dst = dest + (rect.y + row) * destBytesPerRow + rect.x * 4
            memcpy(dst, src, rowBytes)
        }
    }

    /// Band → band, buffer to buffer (the lag-0 band comes straight from the
    /// current frame, never through the spool).
    private static func copyBandDirect(
        from source: UnsafeRawPointer, sourceBytesPerRow: Int,
        to dest: UnsafeMutableRawPointer, destBytesPerRow: Int, rect: BandRect
    ) {
        let rowBytes = rect.width * 4
        for row in 0..<rect.height {
            let src = source + (rect.y + row) * sourceBytesPerRow + rect.x * 4
            let dst = dest + (rect.y + row) * destBytesPerRow + rect.x * 4
            memcpy(dst, src, rowBytes)
        }
    }

    // MARK: - Poster image

    private static func makeImage(fromBGRA pixels: [UInt8], width: Int, height: Int) throws -> CGImage {
        let data = Data(pixels)
        guard let providerRef = CGDataProvider(data: data as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: providerRef, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent)
        else {
            throw LapseError.imageEncodeFailed("could not build the poster image")
        }
        return image
    }

    /// Bakes the master's display transform into the poster pixels — a PNG
    /// carries no transform. Video transforms live in y-down space and CG
    /// draws y-up, so the transform is conjugated by vertical flips on both
    /// sides. Verify against a real portrait project on the Mac before
    /// trusting rotated posters (plan §7 stage 6).
    private static func displayOriented(_ image: CGImage, transform: CGAffineTransform) throws -> CGImage {
        guard transform != .identity else { return image }
        let sourceRect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let bounds = sourceRect.applying(transform)
        let outWidth = Int(bounds.width.rounded())
        let outHeight = Int(bounds.height.rounded())
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: outWidth, height: outHeight, bitsPerComponent: 8,
                bytesPerRow: 0, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue)
        else {
            throw LapseError.imageEncodeFailed("could not build the poster context")
        }
        context.interpolationQuality = .none
        context.translateBy(x: 0, y: CGFloat(outHeight))
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        context.concatenate(transform)
        context.translateBy(x: 0, y: sourceRect.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: sourceRect)
        guard let oriented = context.makeImage() else {
            throw LapseError.imageEncodeFailed("could not orient the poster")
        }
        return oriented
    }
}

/// The animation's history on disk: one ring of `lag` fixed-size records per
/// band, in a single preallocated file. Both sides are sequential per band —
/// the record for master frame `m` lives in slot `m mod lag`, written the
/// iteration `m` decodes and read exactly `lag` iterations later, just before
/// its slot is overwritten. Total size is Σ lag[band] × bandBytes ≈
/// maxLag/2 × frameBytes, independent of clip length.
final class TimeSliceBandSpool {
    private let handle: FileHandle
    private let url: URL
    /// Per band: byte offset of its ring region, record size, ring capacity.
    private let regions: [(offset: UInt64, recordBytes: Int, capacity: Int)]

    init(directory: URL, bandRects: [TimeSliceRenderer.BandRect], bandLags: [Int]) throws {
        var regions: [(offset: UInt64, recordBytes: Int, capacity: Int)] = []
        var offset: UInt64 = 0
        for (band, rect) in bandRects.enumerated() {
            let capacity = bandLags[band]
            regions.append((offset: offset, recordBytes: rect.packedBytes, capacity: capacity))
            offset += UInt64(rect.packedBytes * capacity)
        }
        self.regions = regions

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let free = values?.volumeAvailableCapacityForImportantUsage, offset > 0,
           UInt64(max(0, free)) < offset + 64_000_000 {
            throw LapseError.timeSliceInvalid(
                "the band spool needs \(ByteCountFormatter.string(fromByteCount: Int64(offset), countStyle: .file)) "
                + "of scratch and the disk is nearly full")
        }
        url = directory.appendingPathComponent("timeslice-spool-\(UUID().uuidString).bin")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forUpdating: url)
        if offset > 0 {
            try handle.truncate(atOffset: offset)
        }
    }

    func write(band: Int, masterIndex: Int, from bytes: UnsafeRawPointer) throws {
        let region = regions[band]
        guard region.capacity > 0 else { return }
        let slot = masterIndex % region.capacity
        try handle.seek(toOffset: region.offset + UInt64(slot * region.recordBytes))
        try handle.write(contentsOf: Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: bytes),
                                          count: region.recordBytes, deallocator: .none))
    }

    func read(band: Int, masterIndex: Int, into bytes: UnsafeMutableRawPointer) throws {
        let region = regions[band]
        guard region.capacity > 0 else {
            throw LapseError.timeSliceInvalid("read from a band with no spool ring")
        }
        let slot = masterIndex % region.capacity
        try handle.seek(toOffset: region.offset + UInt64(slot * region.recordBytes))
        guard let data = try handle.read(upToCount: region.recordBytes), data.count == region.recordBytes else {
            throw LapseError.readerFailed("band spool record missing (band \(band), frame \(masterIndex))")
        }
        data.withUnsafeBytes { raw in
            memcpy(bytes, raw.baseAddress!, region.recordBytes)
        }
    }

    func removeFiles() {
        try? handle.close()
        try? FileManager.default.removeItem(at: url)
    }
}
