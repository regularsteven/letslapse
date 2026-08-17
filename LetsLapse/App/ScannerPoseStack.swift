import Foundation
#if os(iOS)
import AVFoundation
import CoreGraphics
import CoreVideo
import LetsLapseKit

/// One pose's frames, averaged into the single image that pose is — the BLEND
/// dial, honoured inside a Scanner run.
///
/// **What BLEND means here, and why it is not the same thing it means in a
/// timelapse.** An Interval shoot averages a window of frames to make motion
/// blur: the scene moves *during* the window and the blur is the point. A
/// Scanner pose is the opposite — exposure, focus and white balance are locked
/// for the whole run and the object is deliberately holding still, so N frames
/// of a pose differ only by sensor noise. Averaging them is therefore a pure
/// signal-to-noise trade: noise falls by about √N, detail doesn't move. Ten
/// frames of a dim page is roughly a stop and a half of grain removed from a
/// document that will be read, OCR'd or reconstructed rather than glanced at.
///
/// **Why this is a small type and not a new pipeline.** Both averages already
/// existed in the Kit, one for each kind of frame a pose can land as, and each
/// is the *right* average for its data rather than a generic one:
///
/// | Frame | Averaged by | Where |
/// |---|---|---|
/// | Bayer RAW | `BayerAccumulator` → `DNGAuthor.writeBayerDNG` | mosaic, before demosaic |
/// | HEIC/JPEG | `ImageStacker` (GPU, linear light) | after decode, in linear light |
///
/// The RAW half is worth stating plainly: the mosaic is averaged **before**
/// anything is demosaiced, which is what keeps the output a real raw file — no
/// white balance, no tone curve and no colour matrix has been applied, so the
/// stacked DNG has exactly the latitude a single frame would have had. The tags
/// come from the pose's own first frame (`DNGDocument.parseReference`), so black
/// level, white level, CFA pattern and the camera's colour matrices are the
/// sensor's own rather than anything invented here.
///
/// **Nothing is ever lost to a failed stack.** Every path falls back to the
/// first frame of the pose, written exactly as the camera produced it — a pose
/// that stacks badly is still a pose. The fallbacks say so in the log and in the
/// returned counts rather than quietly claiming a depth that wasn't reached.
///
/// Not thread-safe by design: `BayerAccumulator` isn't either, and both are
/// driven from `CameraController`'s single stacking queue.
final class ScannerPoseStack {

    /// What one finished pose produced.
    struct Result {
        /// The DNG, when the run is shooting RAW.
        var raw: URL?
        /// The processed sibling (or the only file, on a JPEG run).
        var processed: URL?
        /// How many frames really went into each — the honest count, which is
        /// 1 when a stack fell back to the pose's first frame.
        var rawFrames = 0
        var processedFrames = 0
    }

    /// How many frames this pose is asking for. Only ever > 1: a depth-1 pose
    /// never builds a stack at all, it writes the camera's own bytes (see
    /// `CameraController.handleScannerPhoto`).
    let depth: Int

    /// Where the pose's processed parts are spooled while it is being taken.
    ///
    /// On disk rather than in memory, and that is not an optimisation: ten
    /// 48-megapixel frames is well over a gigabyte of decoded pixels, and
    /// `ImageStacker` streams a stack from URLs precisely so a deep window never
    /// has to hold more than one frame at a time.
    private let scratch: URL

    private let accumulator = BayerAccumulator()
    private var rawFrames = 0
    /// The pose's first RAW frame, kept whole: its tags describe every frame in
    /// the stack (one locked exposure, one sensor), and it is also the fallback
    /// if the average can't be written.
    private var rawReferenceData: Data?
    private var processedParts: [URL] = []
    private var notes: [String] = []

    init(depth: Int, scratch: URL) {
        self.depth = max(2, depth)
        self.scratch = scratch
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    // MARK: - Collecting

    /// One RAW part. `dngData` is passed for the pose's first frame only — it
    /// is tens of megabytes and only the first is needed, since a locked run's
    /// frames all carry the same tags.
    func addRaw(_ pixelBuffer: CVPixelBuffer?, dngData: Data?) {
        if let dngData, rawReferenceData == nil {
            rawReferenceData = dngData
        }
        guard let pixelBuffer else {
            // Nothing to average. The pose still lands — as its first frame —
            // and the count in `Result` reports what really happened.
            note("no RAW pixel buffer on this frame")
            return
        }
        do {
            try accumulator.accumulate(pixelBuffer)
            rawFrames += 1
        } catch {
            note("RAW accumulate failed — \(error.localizedDescription)")
        }
    }

    /// One processed part, spooled to scratch.
    func addProcessed(_ data: Data, fileExtension: String) {
        let url = scratch.appendingPathComponent(
            String(format: "part-%02d.%@", processedParts.count, fileExtension))
        do {
            try data.write(to: url, options: .atomic)
            processedParts.append(url)
        } catch {
            note("could not spool a processed frame — \(error.localizedDescription)")
        }
    }

    // MARK: - Finishing

    /// Averages what arrived and writes the pose's files into `directory`,
    /// named exactly as an unstacked pose's would be.
    func finalize(directory: URL, index: Int, wantsRAW: Bool) -> Result {
        defer { try? FileManager.default.removeItem(at: scratch) }
        var result = Result()

        // The processed sibling first: on a RAW pose its stacked pixels also
        // become the DNG's embedded preview, so a stacked raw file previews as
        // the stack rather than as one noisy frame of it.
        var preview: DNGAuthor.Preview?
        if !processedParts.isEmpty {
            let processedName = String(format: "frame-%05d.%@", index + 1, wantsRAW ? "heic" : "jpg")
            let destination = directory.appendingPathComponent(processedName)
            let format: ImageFormat = wantsRAW ? .heic : .jpeg
            if processedParts.count > 1, let stacked = stackProcessed() {
                do {
                    // Orientation is baked into the stacked pixels by
                    // `ImageStacker.loadImage`, and `carryoverMetadata` drops the
                    // tag to match — so the file is upright and says so, where an
                    // unstacked pose is sideways with a tag. Both are correct and
                    // both rectify from the same corners, because
                    // `PerspectiveCorrector` uprights before it applies them.
                    try ImageExporter.write(
                        stacked, to: destination, format: format,
                        metadata: ImageExporter.carryoverMetadata(from: processedParts[0]))
                    result.processed = destination
                    result.processedFrames = processedParts.count
                    preview = LiveBlendRawController.makePreview(from: stacked)
                } catch {
                    note("processed stack write failed — \(error.localizedDescription)")
                }
            }
            if result.processed == nil, let first = processedParts.first {
                // Fallback: the pose's first frame, byte for byte.
                try? FileManager.default.removeItem(at: destination)
                if (try? FileManager.default.copyItem(at: first, to: destination)) != nil {
                    result.processed = destination
                    result.processedFrames = 1
                }
            }
        }

        guard wantsRAW else {
            logNotes(index: index, result: result)
            return result
        }

        let rawDestination = directory.appendingPathComponent(String(format: "frame-%05d.dng", index + 1))
        if rawFrames > 1, let referenceData = rawReferenceData {
            do {
                let reference = try DNGDocument.parseReference(referenceData)
                let width = accumulator.width
                let height = accumulator.height
                let mosaic = try accumulator.finalizeMosaic()
                try DNGAuthor.writeBayerDNG(
                    mosaic: mosaic, width: width, height: height,
                    reference: reference, preview: preview, to: rawDestination)
                result.raw = rawDestination
                result.rawFrames = rawFrames
            } catch {
                note("RAW stack failed — \(error.localizedDescription)")
            }
        }
        if result.raw == nil, let referenceData = rawReferenceData {
            accumulator.discardWindow()
            if (try? referenceData.write(to: rawDestination, options: .atomic)) != nil {
                result.raw = rawDestination
                result.rawFrames = 1
            }
        }
        logNotes(index: index, result: result)
        return result
    }

    /// The GPU average of the pose's processed frames, streamed from scratch.
    private func stackProcessed() -> CGImage? {
        do {
            let core = try BlendCore()
            return try ImageStacker(core: core).stack(imageURLs: processedParts)
        } catch {
            note("processed stack failed — \(error.localizedDescription)")
            return nil
        }
    }

    private func note(_ message: String) {
        notes.append(message)
    }

    /// One line per pose, and it always names what was actually achieved: a
    /// stack that silently fell back to one frame is the failure most worth
    /// being able to find afterwards, because the files look fine.
    private func logNotes(index: Int, result: Result) {
        var line = "scanner: pose \(index + 1) stacked raw=\(result.rawFrames)"
            + " processed=\(result.processedFrames) of \(depth)"
        if !notes.isEmpty {
            line += " · " + notes.joined(separator: "; ")
        }
        LLog(line)
    }
}

#endif
