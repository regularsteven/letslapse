import SwiftUI
import CoreGraphics
import LetsLapseKit
#if os(iOS)
import Photos
#endif

@MainActor
final class AppModel: ObservableObject {
    enum Source: Equatable {
        case video(URL)
        case photos([URL])

        var summary: String {
            switch self {
            case .video(let url):
                return "Video · \(url.lastPathComponent)"
            case .photos(let urls):
                return "\(urls.count) photos"
            }
        }

        var isVideo: Bool {
            if case .video = self { return true }
            return false
        }
    }

    enum Stage {
        case home
        case configure
        case processing
        case done
    }

    @Published var stage: Stage = .home
    @Published var source: Source?
    @Published var errorMessage: String?

    // Blend options
    @Published var useRamp = true
    @Published var constantWindow = 15
    @Published var rampStart = 1
    @Published var rampEnd = 30
    @Published var curve: BlendCurve = .easeInOut
    @Published var outputFPS = 30
    @Published var linearLight = true

    // Progress / results
    @Published var progress: Double = 0
    @Published var resultVideoURL: URL?
    @Published var resultImage: CGImage?
    @Published var resultImageURL: URL?
    @Published var resultSummary: String?
    @Published var saveConfirmation: String?

    private var blendTask: Task<Void, Never>?

    func setSource(_ source: Source) {
        self.source = source
        errorMessage = nil
        stage = .configure
    }

    func reset() {
        blendTask?.cancel()
        blendTask = nil
        source = nil
        progress = 0
        resultVideoURL = nil
        resultImage = nil
        resultImageURL = nil
        resultSummary = nil
        saveConfirmation = nil
        errorMessage = nil
        stage = .home
    }

    func cancelProcessing() {
        blendTask?.cancel()
    }

    var ramp: BlendRamp {
        useRamp && source?.isVideo == true
            ? BlendRamp(startWindow: rampStart, endWindow: rampEnd, curve: curve)
            : .constant(constantWindow)
    }

    func startProcessing() {
        guard let source else { return }
        stage = .processing
        progress = 0
        errorMessage = nil
        let ramp = self.ramp
        let fps = Double(outputFPS)
        let linear = linearLight
        blendTask = Task { [weak self] in
            do {
                switch source {
                case .video(let url):
                    try await self?.blendVideo(url: url, ramp: ramp, fps: fps, linear: linear)
                case .photos(let urls):
                    try await self?.stackPhotos(urls: urls, linear: linear)
                }
                self?.stage = .done
            } catch is CancellationError {
                self?.stage = .configure
            } catch LapseError.cancelled {
                self?.stage = .configure
            } catch {
                self?.errorMessage = (error as? LapseError)?.errorDescription ?? error.localizedDescription
                self?.stage = .configure
            }
        }
    }

    private func blendVideo(url: URL, ramp: BlendRamp, fps: Double, linear: Bool) async throws {
        let core = try BlendCore()
        let blender = VideoBlender(core: core)
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("LetsLapse-\(Int(Date().timeIntervalSince1970)).mp4")
        let options = VideoBlendOptions(ramp: ramp, outputFPS: fps, codec: .h264, linearLight: linear)
        let result = try await blender.blend(input: url, to: output, options: options) { fraction in
            Task { @MainActor [weak self] in
                self?.progress = fraction
            }
        }
        resultVideoURL = result.outputURL
        resultSummary = "\(result.inputFrames) frames in → \(result.outputFrames) frames out · "
            + String(format: "%.1fs", result.outputDuration)
            + " · \(result.width)×\(result.height)"
    }

    private func stackPhotos(urls: [URL], linear: Bool) async throws {
        let image = try await Task.detached(priority: .userInitiated) { [weak self] () throws -> CGImage in
            let core = try BlendCore()
            let stacker = ImageStacker(core: core)
            return try stacker.stack(imageURLs: urls, linearLight: linear) { fraction in
                Task { @MainActor in
                    self?.progress = fraction
                }
            }
        }.value
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("LetsLapse-\(Int(Date().timeIntervalSince1970)).png")
        try ImageExporter.write(image, to: output, format: .png)
        resultImage = image
        resultImageURL = output
        resultSummary = "\(urls.count) photos stacked · \(image.width)×\(image.height)"
    }

    #if os(iOS)
    func saveResultToPhotos() {
        let videoURL = resultVideoURL
        let imageURL = resultImageURL
        guard videoURL != nil || imageURL != nil else { return }
        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                saveConfirmation = "Photos access was denied."
                return
            }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    if let videoURL {
                        PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: videoURL)
                    } else if let imageURL {
                        PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: imageURL)
                    }
                }
                saveConfirmation = "Saved to Photos."
            } catch {
                saveConfirmation = "Save failed: \(error.localizedDescription)"
            }
        }
    }
    #endif
}
