import LetsLapseKit
import SwiftUI

// Duplicating an interval project as a DNG archive: the same shoot, every
// frame converted to a smaller DNG (camera-native, lossy JPEG XL, optionally
// resampled) the way Adobe DNG Converter would make it, with the grade, the
// sidecars, the notes and the overlays carried across. The conversion itself
// is the Kit's `DNGArchive.Converter` (docs/dng-archive-spike/); this file is
// the options, the job and the sheet.

/// What the sheet lets you choose. Defaults are Adobe's: the source size,
/// distance 0.5.
struct DNGArchiveOptions: Equatable {
    enum Size: String, CaseIterable, Identifiable {
        case keep, mp12, mp10, mp8, mp6
        var id: String { rawValue }
        var megapixels: Double? {
            switch self {
            case .keep: return nil
            case .mp12: return 12
            case .mp10: return 10
            case .mp8: return 8
            case .mp6: return 6
            }
        }
        func label(sourceMegapixels: Double?) -> String {
            switch self {
            case .keep:
                if let sourceMegapixels { return String(format: "Keep · %.1f MP", sourceMegapixels) }
                return "Keep"
            default: return "\(Int(megapixels!)) MP"
            }
        }
    }

    enum Quality: String, CaseIterable, Identifiable {
        /// Adobe's default lossy setting.
        case standard
        /// Half the file for about 4 dB.
        case compact
        /// JPEG XL lossless on the demosaiced frame — large, exact.
        case lossless
        /// The Bayer mosaic itself, lossless JPEG XL: 5–9% under the capture's
        /// own lossless JPEG, nothing changed, no resize possible.
        case losslessMosaic
        var id: String { rawValue }
        var title: String {
            switch self {
            case .standard: return "Lossy · standard"
            case .compact: return "Lossy · compact"
            case .lossless: return "Lossless"
            case .losslessMosaic: return "Lossless mosaic"
            }
        }
        var detail: String {
            switch self {
            case .standard: return "JPEG XL distance 0.5, Adobe's default. About 1.3 MB per 10 MP frame."
            case .compact: return "JPEG XL distance 1.0. About half the size, ~4 dB below standard."
            case .lossless: return "Demosaiced, JPEG XL lossless. Exact, but 25–40 MB a frame."
            case .losslessMosaic: return "Keeps the sensor mosaic exactly, in JPEG XL. Cannot be resized."
            }
        }
        var distance: Float {
            switch self {
            case .standard: return 0.5
            case .compact: return 1.0
            case .lossless, .losslessMosaic: return 0
            }
        }
    }

    var size: Size = .keep
    var quality: Quality = .standard

    var strategy: DNGArchive.Strategy {
        switch quality {
        case .losslessMosaic:
            return .losslessMosaic
        default:
            return .archive(megapixels: size.megapixels, distance: quality.distance)
        }
    }

    /// What the new project is called, after the original's title.
    var nameSuffix: String {
        var parts = ["DNG"]
        if quality != .losslessMosaic, let megapixels = size.megapixels { parts.append("\(Int(megapixels)) MP") }
        switch quality {
        case .standard: break
        case .compact: parts.append("compact")
        case .lossless: parts.append("lossless")
        case .losslessMosaic: parts.append("mosaic")
        }
        return parts.joined(separator: " · ")
    }
}

/// One conversion run, observed by the sheet. Owned by the view that shows
/// the sheet so a dismissed sheet still finishes (or is cancelled) cleanly.
@MainActor
final class DNGArchiveJob: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var progress: DNGArchive.Converter.SequenceProgress?
    @Published private(set) var result: AppModel.CaptureProject?
    @Published private(set) var failure: String?
    @Published private(set) var summary: String?
    private var cancelled = false
    private var task: Task<Void, Never>?

    var fraction: Double {
        guard let progress, progress.framesTotal > 0 else { return 0 }
        return Double(progress.framesDone) / Double(progress.framesTotal)
    }

    func start(model: AppModel, capture: AppModel.CaptureProject, options: DNGArchiveOptions) {
        guard !isRunning else { return }
        isRunning = true
        cancelled = false
        progress = nil
        result = nil
        failure = nil
        summary = nil
        let strategy = options.strategy
        let suffix = options.nameSuffix
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let clone = try await model.duplicateAsDNGArchive(
                    capture, strategy: strategy, nameSuffix: suffix,
                    shouldContinue: { [weak self] in
                        // Read off the main actor by the converter's workers;
                        // a plain Bool flip is what it needs.
                        !(self?.cancelledFlag ?? true)
                    },
                    progress: { [weak self] snapshot in
                        self?.progress = snapshot
                    })
                self.result = clone
                if let progress = self.progress {
                    self.summary = String(
                        format: "%d frames · %@ → %@ · %@ · %.2f frames/s",
                        progress.framesDone, Self.bytes(progress.inputBytes), Self.bytes(progress.outputBytes),
                        Self.duration(progress.elapsedSeconds),
                        progress.elapsedSeconds > 0 ? Double(progress.framesDone) / progress.elapsedSeconds : 0)
                }
            } catch is CancellationError {
                self.failure = nil
            } catch {
                self.failure = error.localizedDescription
            }
            self.isRunning = false
        }
    }

    /// Read from the converter's worker threads; written on the main actor.
    nonisolated(unsafe) private var cancelledFlag = false

    func cancel() {
        cancelled = true
        cancelledFlag = true
    }

    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    static func duration(_ seconds: Double) -> String {
        seconds < 90 ? String(format: "%.0f s", seconds) : String(format: "%.1f min", seconds / 60)
    }
}

/// The sheet: two pickers, a Start button, a progress card, a Done line.
struct DNGArchiveSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let capture: AppModel.CaptureProject
    @ObservedObject var job: DNGArchiveJob
    @State private var options = DNGArchiveOptions()
    /// Opens the new project when the run finishes.
    var onFinished: (AppModel.CaptureProject) -> Void = { _ in }

    private var sourceMegapixels: Double? {
        guard let width = capture.sourceWidth, let height = capture.sourceHeight, width > 0, height > 0 else { return nil }
        return Double(width * height) / 1e6
    }

    private var frameCount: Int { model.sourceFrameURLs(for: capture).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Duplicate as DNG archive")
                    .font(.title2.weight(.semibold))
                Text("A new project with every frame of “\(capture.displayTitle)” converted to a smaller, still-raw DNG. The original is not touched.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if job.isRunning || job.result != nil || job.failure != nil {
                progressCard
            } else {
                optionsForm
            }

            HStack {
                if job.isRunning {
                    Button("Cancel") { job.cancel() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                } else if let result = job.result {
                    Spacer()
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Open new project") {
                        dismiss()
                        onFinished(result)
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(job.failure == nil ? "Start" : "Try again") {
                        job.start(model: model, capture: capture, options: options)
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(frameCount < 2)
                }
            }
        }
        .padding(24)
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 500)
        #endif
        .interactiveDismissDisabled(job.isRunning)
    }

    private var optionsForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            LabeledContent("Frames") {
                Text("\(frameCount)")
                    .foregroundStyle(.secondary)
            }
            Picker("Size", selection: $options.size) {
                ForEach(DNGArchiveOptions.Size.allCases) { size in
                    Text(size.label(sourceMegapixels: sourceMegapixels)).tag(size)
                }
            }
            .disabled(options.quality == .losslessMosaic)
            Picker("Quality", selection: $options.quality) {
                ForEach(DNGArchiveOptions.Quality.allCases) { quality in
                    Text(quality.title).tag(quality)
                }
            }
            Text(options.quality.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("New project: “\(capture.displayTitle) · \(options.nameSuffix)”")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let failure = job.failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(LL.amber)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let summary = job.summary {
                Label("Done", systemImage: "checkmark.circle")
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView(value: job.fraction)
                if let progress = job.progress {
                    HStack {
                        Text("Frame \(progress.framesDone) of \(progress.framesTotal)")
                        Spacer()
                        Text("\(DNGArchiveJob.bytes(progress.inputBytes)) → \(DNGArchiveJob.bytes(progress.outputBytes))")
                            .foregroundStyle(.secondary)
                    }
                    .font(.footnote)
                    if let last = progress.lastReport {
                        Text(String(format: "%@ · %dx%d · %.0f ms · %@", last.output.lastPathComponent, last.width, last.height,
                                    last.totalMilliseconds, DNGArchiveJob.bytes(last.outputBytes)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    Text("Starting…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .llCard(cornerRadius: 14)
    }
}
