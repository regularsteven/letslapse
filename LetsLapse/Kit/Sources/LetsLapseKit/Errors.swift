import Foundation

/// An `AVAssetWriter` failure described so it can be diagnosed from a log.
///
/// `localizedDescription` alone is not enough: AVFoundation's strings are
/// short and ambiguous ("Cannot Encode" covers an unsupported profile, a
/// rejected frame size and a busy hardware encoder alike), and the domain and
/// code are the parts that separate them. A run that fails on a user's machine
/// leaves one line in the console, so that line has to carry the whole answer.
public func writerFailureDescription(_ error: Error?, fallback: String) -> String {
    guard let error else { return fallback }
    let nsError = error as NSError
    var text = "\(nsError.localizedDescription) [\(nsError.domain) \(nsError.code)]"
    if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
        text += " ← \(underlying.localizedDescription) [\(underlying.domain) \(underlying.code)]"
    }
    if let reason = nsError.localizedFailureReason { text += " — \(reason)" }
    return text
}

public enum LapseError: Error, LocalizedError {
    case metalUnavailable
    case kernelSourceMissing
    case gpuSetupFailed(String)
    case textureCreationFailed(String)
    case sizeMismatch(expectedWidth: Int, expectedHeight: Int, actualWidth: Int, actualHeight: Int)
    case noVideoTrack(URL)
    case readerFailed(String)
    case writerFailed(String)
    case noInputFrames
    case imageLoadFailed(URL)
    case imageEncodeFailed(String)
    case timeSliceInvalid(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .metalUnavailable:
            return "No Metal-capable GPU is available on this machine."
        case .kernelSourceMissing:
            return "The Metal kernel source could not be found in the LetsLapseKit bundle."
        case .gpuSetupFailed(let why):
            return "GPU setup failed: \(why)"
        case .textureCreationFailed(let why):
            return "Could not create a GPU texture: \(why)"
        case .sizeMismatch(let ew, let eh, let aw, let ah):
            return "Frame size mismatch: expected \(ew)x\(eh), got \(aw)x\(ah). All frames in a blend must share one size."
        case .noVideoTrack(let url):
            return "No video track found in \(url.lastPathComponent)."
        case .readerFailed(let why):
            return "Video decoding failed: \(why)"
        case .writerFailed(let why):
            return "Video encoding failed: \(why)"
        case .noInputFrames:
            return "No input frames were provided."
        case .imageLoadFailed(let url):
            return "Could not load image at \(url.path)."
        case .imageEncodeFailed(let why):
            return "Could not encode output image: \(why)"
        case .timeSliceInvalid(let why):
            return "Time slicing refused: \(why)"
        case .cancelled:
            return "The blend was cancelled."
        }
    }
}
