import Foundation
import AVFoundation
import Vision
import Combine

/// The capture side of the monitor test rig (`tools/testcard/`).
///
/// The test card page renders a session QR (`LLTC1;<script>`) plus a live
/// time channel. When the capture screen is idle in Video mode, a sparse
/// video-data tap watches the preview for that card; seeing the session QR
/// AND the time channel advancing locks the rig, a visible countdown chip
/// offers a cancel, and then the declared script runs through the real
/// capture engine — base-rate video with timed bursts — and stops itself.
/// The card stamps display-side time into every captured frame, so
/// `tools/testcard_report.py` can measure what actually happened.
///
/// This ships in the normal build on purpose (testing must be no-fuss).
/// The guard rails are behavioural instead: the rig only ever arms on the
/// card's own `LLTC1;` payload with a live, advancing clock behind it, the
/// run starts behind a visible countdown with a tap-to-cancel, and a
/// finished run cools down before the same card can arm again.

// MARK: - Script

/// A parsed capture script: `i25x100,b100x5,i25x100` — segments of one video
/// ramp run. `i` segments roll at the base rate, `b` segments are timed
/// bursts at the ramp rate. All `i` share one fps, all `b` share another;
/// the run must open on an `i`.
struct TestCardScript: Equatable {
    struct Segment: Equatable {
        enum Kind: Equatable { case base, burst }
        let kind: Kind
        let fps: Int
        let seconds: Double
    }

    let raw: String
    let segments: [Segment]
    let baseFPS: Int
    let burstFPS: Int?

    var totalSeconds: Double { segments.reduce(0) { $0 + $1.seconds } }

    /// "i25x100,b100x5,i25x100" → script, nil when malformed or unsupported.
    static func parse(_ raw: String) -> TestCardScript? {
        var segments: [Segment] = []
        for part in raw.split(separator: ",") {
            let kind: Segment.Kind
            switch part.first {
            case "i": kind = .base
            case "b": kind = .burst
            default: return nil
            }
            let body = part.dropFirst().split(separator: "x")
            guard body.count == 2,
                  let fps = Int(body[0]), fps > 0,
                  let seconds = Double(body[1]), seconds > 0 else { return nil }
            segments.append(Segment(kind: kind, fps: fps, seconds: seconds))
        }
        guard let first = segments.first, first.kind == .base else { return nil }
        let baseFPS = first.fps
        let burstFPS = segments.first { $0.kind == .burst }?.fps
        // One base rate and one burst rate per run — that's what a ramp
        // recording can express.
        guard segments.allSatisfy({ $0.kind == .base ? $0.fps == baseFPS : $0.fps == burstFPS }),
              burstFPS.map({ $0 > baseFPS }) ?? true else { return nil }
        return TestCardScript(raw: String(raw), segments: segments,
                              baseFPS: baseFPS, burstFPS: burstFPS)
    }
}

// MARK: - Frame tap

/// Receives the sparse video-data frames CameraController taps off the
/// session while the rig is watching, throttles them to ~2/s, and hands
/// them to the rig on a private queue. Kept separate from the controller so
/// the session code stays free of Vision concerns.
final class TestCardFrameTap: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let queue = DispatchQueue(label: "letslapse.testcard.tap")
    var handler: ((CVPixelBuffer) -> Void)?
    private var lastForwarded = Date.distantPast

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let now = Date()
        guard now.timeIntervalSince(lastForwarded) >= 0.5,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastForwarded = now
        handler?(buffer)
    }
}

// MARK: - Rig controller

/// State machine behind the capture screen's test-card chip. Vision work
/// stays on `visionQueue`; every phase mutation happens on the main queue.
final class TestCardRigController: ObservableObject {

    enum Phase: Equatable {
        case idle
        /// Card locked; the run starts when the countdown lapses unless cancelled.
        case countdown(TestCardScript, endsAt: Date)
        case running(TestCardScript, startedAt: Date)
        /// Terminal banner (result or refusal); auto-clears back to idle.
        case finished(String)
    }

    @Published private(set) var phase: Phase = .idle

    weak var camera: CameraController?

    let tap = TestCardFrameTap()
    private let visionQueue = DispatchQueue(label: "letslapse.testcard.vision")
    private let request: VNDetectBarcodesRequest = {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        return request
    }()

    /// Sightings that build toward a lock. Main-queue confined.
    private var sightedScript: TestCardScript?
    private var sightedAt = Date.distantPast
    private var timeReads: [(ms: Int, at: Date)] = []
    /// No re-arm until this passes — a finished run's card is still on screen.
    private var cooldownUntil = Date.distantPast

    private var scheduled: [DispatchWorkItem] = []

    init() {
        tap.handler = { [weak self] buffer in self?.detect(in: buffer) }
    }

    /// Whether the preview tap should be feeding frames right now.
    var wantsFrames: Bool { phase == .idle }

    // MARK: Detection

    private func detect(in buffer: CVPixelBuffer) {
        visionQueue.async { [weak self] in
            guard let self else { return }
            let handler = VNImageRequestHandler(cvPixelBuffer: buffer, options: [:])
            try? handler.perform([self.request])
            let payloads = (self.request.results ?? []).compactMap(\.payloadStringValue)
            guard !payloads.isEmpty else { return }
            DispatchQueue.main.async { self.ingest(payloads) }
        }
    }

    private func ingest(_ payloads: [String]) {
        guard phase == .idle, Date() >= cooldownUntil else { return }
        let now = Date()
        // Sightings go stale together: a card that vanished mid-arm starts over.
        if now.timeIntervalSince(sightedAt) > 6 {
            sightedScript = nil
            timeReads = []
        }
        for payload in payloads {
            if payload.hasPrefix("LLTC1;") {
                if let script = TestCardScript.parse(String(payload.dropFirst(6))) {
                    sightedScript = script
                    sightedAt = now
                }
            } else if payload.hasPrefix("LLT;"), let ms = Int(payload.dropFirst(4)) {
                if timeReads.last?.ms != ms {
                    timeReads.append((ms, now))
                    timeReads.removeAll { now.timeIntervalSince($0.at) > 6 }
                    sightedAt = now
                }
            }
        }
        // Lock: the script QR plus proof the card is live (its clock advanced
        // across at least two reads) — a photo of a test card never arms.
        guard let script = sightedScript,
              timeReads.count >= 2,
              zip(timeReads, timeReads.dropFirst()).allSatisfy({ $0.ms < $1.ms })
        else { return }
        lock(script)
    }

    private func lock(_ script: TestCardScript) {
        LLog("testcard: locked on \(script.raw) — countdown")
        phase = .countdown(script, endsAt: Date().addingTimeInterval(3))
        let begin = DispatchWorkItem { [weak self] in self?.beginRun() }
        scheduled.append(begin)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: begin)
    }

    // MARK: Run

    private func beginRun() {
        guard case .countdown(let script, _) = phase, let camera else { return }
        guard !camera.isRecording else { return finish("test run skipped — already recording") }
        guard camera.availableFrameRates.contains(script.baseFPS) else {
            return finish("test run refused — \(script.baseFPS) fps not offered here")
        }
        camera.selectFrameRate(script.baseFPS)
        // The burst list is recomputed off the new base rate on the session
        // queue; give it a beat before validating the burst leg against it.
        let start = DispatchWorkItem { [weak self] in
            guard let self, case .countdown = self.phase else { return }
            self.startValidatedRun(script)
        }
        scheduled.append(start)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: start)
    }

    private func startValidatedRun(_ script: TestCardScript) {
        guard let camera else { return }
        if let burst = script.burstFPS {
            guard camera.availableBurstFrameRates.contains(burst) else {
                return finish("test run refused — \(burst) fps burst not reachable from \(script.baseFPS)")
            }
            camera.selectRampFrameRate(burst)
        }
        LLog("testcard: run start \(script.raw) (\(Int(script.totalSeconds))s total)")
        camera.startRecording(mode: .ramp)
        phase = .running(script, startedAt: Date())

        var offset: TimeInterval = 0
        for segment in script.segments {
            if segment.kind == .burst {
                let item = DispatchWorkItem { [weak camera] in
                    camera?.triggerTimedLiveMoment(duration: segment.seconds)
                }
                scheduled.append(item)
                DispatchQueue.main.asyncAfter(deadline: .now() + offset, execute: item)
            }
            offset += segment.seconds
        }
        let total = offset
        let stop = DispatchWorkItem { [weak self] in
            self?.camera?.stopRecording(source: .rig)
            self?.finish("test run complete — \(Int(total))s captured")
        }
        scheduled.append(stop)
        DispatchQueue.main.asyncAfter(deadline: .now() + total, execute: stop)
    }

    /// The chip's tap. Cancels the countdown, or stops (and keeps) a running take.
    func cancel() {
        switch phase {
        case .countdown:
            finish("test run cancelled")
        case .running:
            clearSchedule()
            camera?.stopRecording(source: .rig)
            finish("test run stopped — partial take kept")
        default:
            break
        }
    }

    private func finish(_ message: String) {
        LLog("testcard: \(message)")
        clearSchedule()
        sightedScript = nil
        timeReads = []
        cooldownUntil = Date().addingTimeInterval(20)
        phase = .finished(message)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, case .finished = self.phase else { return }
            self.phase = .idle
        }
    }

    private func clearSchedule() {
        scheduled.forEach { $0.cancel() }
        scheduled = []
    }

    /// LL_TESTRIG=chip — freeze a countdown chip for design screenshots.
    func seedDemoChip() {
        guard let script = TestCardScript.parse("i25x100,b100x5,i25x100") else { return }
        phase = .countdown(script, endsAt: .distantFuture)
    }
}
