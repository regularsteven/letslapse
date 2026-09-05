import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import Metal
import VideoToolbox

/// What this machine can encode and decode, for the archive-conversion
/// question: is there a JPEG XL encoder anywhere in the OS, is the JPEG
/// encoder hardware, which Metal family is the GPU. The same code runs in
/// the `dngspike probe` command on a Mac and behind the app's `LL_DNGPROBE`
/// launch hook on a device — the simulators are software-only and the Mac
/// lacks the codec the iPhone camera pipeline writes with, so the answer has
/// to come from real hardware.
public struct DNGCapabilityReport: Codable, Equatable {
    public struct VideoEncoder: Codable, Equatable {
        public var codec: String
        public var name: String
        public var hardware: Bool
        public var encoderID: String
    }

    public var date: String
    public var hardwareModel: String
    public var machine: String
    public var chip: String
    public var os: String
    public var processorCount: Int
    public var physicalMemoryGB: Double
    public var metalDevice: String
    public var metalFamilies: [String]
    public var imageIOEncoders: [String]
    public var imageIOEncoderCount: Int
    public var imageIODecodesJPEGXL: Bool
    public var imageIOEncodesJPEGXL: Bool
    public var videoEncoders: [VideoEncoder]
    public var hasVideoToolboxJPEGXL: Bool
    public var hasHardwareJPEG: Bool
    public var hasHardwareHEVC: Bool
    public var jpegXLSession: String
    public var thermalState: String
}

public enum DNGCapabilityProbe {

    /// FourCC `'jxlc'` — `kCMVideoCodecType_JPEG_XL`, spelled out so the
    /// probe builds against the Kit's iOS 16 / macOS 13 floor.
    public static let jxlc: CMVideoCodecType = 0x6A78_6C63

    public static func run(tryJPEGXLSession: Bool = true) -> DNGCapabilityReport {
        let encoders = videoEncoders()
        let destinationTypes = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        let sourceTypes = (CGImageSourceCopyTypeIdentifiers() as? [String]) ?? []
        let interesting = destinationTypes.filter {
            ["jxl", "jpeg-xl", "heic", "heif", "avif", "jpeg", "png", "tiff", "dng", "raw", "webp", "exr"].contains(where: $0.lowercased().contains)
        }
        let hasJXL = encoders.contains { $0.codec == "jxlc" }
        var session = "not attempted"
        if tryJPEGXLSession {
            session = jpegXLSessionAttempt(hasEncoder: hasJXL)
        }
        let device = MTLCreateSystemDefaultDevice()
        let formatter = ISO8601DateFormatter()
        return DNGCapabilityReport(
            date: formatter.string(from: Date()),
            hardwareModel: sysctl("hw.model"),
            machine: sysctl("hw.machine"),
            chip: chipName(),
            os: osVersion(),
            processorCount: ProcessInfo.processInfo.activeProcessorCount,
            physicalMemoryGB: (Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824 * 10).rounded() / 10,
            metalDevice: device?.name ?? "none",
            metalFamilies: device.map(metalFamilies) ?? [],
            imageIOEncoders: interesting.sorted(),
            imageIOEncoderCount: destinationTypes.count,
            imageIODecodesJPEGXL: sourceTypes.contains { $0.contains("jpeg-xl") || $0.contains("jxl") },
            imageIOEncodesJPEGXL: destinationTypes.contains { $0.contains("jpeg-xl") || $0.contains("jxl") },
            videoEncoders: encoders,
            hasVideoToolboxJPEGXL: hasJXL,
            hasHardwareJPEG: encoders.contains { $0.codec == "jpeg" && $0.hardware },
            hasHardwareHEVC: encoders.contains { $0.codec == "hvc1" && $0.hardware },
            jpegXLSession: session,
            thermalState: thermalState())
    }

    /// Human-readable table.
    public static func text(_ report: DNGCapabilityReport) -> String {
        var lines: [String] = []
        lines.append("DNG capability probe — \(report.date)")
        lines.append("  hardware      \(report.hardwareModel) / \(report.machine) · \(report.chip) · \(report.processorCount) cores · \(report.physicalMemoryGB) GB")
        lines.append("  os            \(report.os) · thermal \(report.thermalState)")
        lines.append("  metal         \(report.metalDevice) · \(report.metalFamilies.joined(separator: ", "))")
        lines.append("  imageio       \(report.imageIOEncoderCount) encoders · decodes JPEG XL: \(report.imageIODecodesJPEGXL) · encodes JPEG XL: \(report.imageIOEncodesJPEGXL)")
        lines.append("                \(report.imageIOEncoders.joined(separator: " "))")
        lines.append("  videotoolbox  \(report.videoEncoders.count) encoders · jxlc: \(report.hasVideoToolboxJPEGXL) · JPEG hw: \(report.hasHardwareJPEG) · HEVC hw: \(report.hasHardwareHEVC)")
        for encoder in report.videoEncoders {
            lines.append(String(format: "                %@  %-36@ hw=%@  %@", encoder.codec as NSString, encoder.name as NSString, encoder.hardware ? "yes" : "no ", encoder.encoderID as NSString))
        }
        lines.append("  jxlc session  \(report.jpegXLSession)")
        return lines.joined(separator: "\n")
    }

    public static func json(_ report: DNGCapabilityReport) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(report)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    // MARK: - Pieces

    public static func videoEncoders() -> [DNGCapabilityReport.VideoEncoder] {
        var list: CFArray?
        VTCopyVideoEncoderList(nil, &list)
        let entries = (list as? [[String: Any]]) ?? []
        return entries.map { entry in
            let codec = (entry[kVTVideoEncoderList_CodecType as String] as? NSNumber)?.int32Value ?? 0
            return DNGCapabilityReport.VideoEncoder(
                codec: fourCC(UInt32(bitPattern: codec)),
                name: entry[kVTVideoEncoderList_EncoderName as String] as? String ?? "?",
                hardware: (entry[kVTVideoEncoderList_IsHardwareAccelerated as String] as? NSNumber)?.boolValue ?? false,
                encoderID: entry[kVTVideoEncoderList_EncoderID as String] as? String ?? "?")
        }
    }

    /// Tries to open a VideoToolbox compression session for `'jxlc'` and
    /// push one frame through it. Reports the OSStatus of each step and, on
    /// success, whether the bytes that came out start with the bare JPEG XL
    /// codestream signature `FF 0A`.
    public static func jpegXLSessionAttempt(hasEncoder: Bool) -> String {
        var session: VTCompressionSession?
        let width: Int32 = 256, height: Int32 = 256
        let status = VTCompressionSessionCreate(
            allocator: nil, width: width, height: height, codecType: jxlc,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else {
            return "VTCompressionSessionCreate(jxlc) → \(status)\(hasEncoder ? "" : " (no jxlc encoder listed)")"
        }
        defer { VTCompressionSessionInvalidate(session) }
        var pixelBuffer: CVPixelBuffer?
        // A 16-bit RGB buffer first (the shape a raw archive needs), then the
        // ordinary 8-bit BGRA so a refusal of 16-bit is reported as such.
        var attempts: [String] = []
        for (label, format) in [("64RGBALE", kCVPixelFormatType_64RGBALE), ("32BGRA", kCVPixelFormatType_32BGRA)] {
            let created = CVPixelBufferCreate(nil, Int(width), Int(height), format, nil, &pixelBuffer)
            guard created == kCVReturnSuccess, let buffer = pixelBuffer else {
                attempts.append("\(label): CVPixelBufferCreate → \(created)")
                continue
            }
            var outStatus = noErr
            var outBytes = 0
            var signature = "none"
            let semaphore = DispatchSemaphore(value: 0)
            let encode = VTCompressionSessionEncodeFrame(
                session, imageBuffer: buffer, presentationTimeStamp: CMTime(value: 0, timescale: 30),
                duration: .invalid, frameProperties: nil, infoFlagsOut: nil
            ) { encodeStatus, _, sampleBuffer in
                outStatus = encodeStatus
                if let sampleBuffer, let block = CMSampleBufferGetDataBuffer(sampleBuffer) {
                    outBytes = CMBlockBufferGetDataLength(block)
                    var head = [UInt8](repeating: 0, count: 2)
                    if CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: 2, destination: &head) == noErr {
                        signature = String(format: "%02X %02X", head[0], head[1])
                    }
                }
                semaphore.signal()
            }
            if encode != noErr {
                attempts.append("\(label): EncodeFrame → \(encode)")
                continue
            }
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            _ = semaphore.wait(timeout: .now() + 5)
            attempts.append("\(label): encoded status \(outStatus), \(outBytes) bytes, head \(signature)")
        }
        return "session created; " + attempts.joined(separator: "; ")
    }

    public static func metalFamilies(_ device: MTLDevice) -> [String] {
        var families: [String] = []
        let apple: [(MTLGPUFamily, String)] = [
            (.apple9, "apple9"), (.apple8, "apple8"), (.apple7, "apple7"), (.apple6, "apple6"), (.apple5, "apple5"),
        ]
        for (family, name) in apple where device.supportsFamily(family) {
            families.append(name)
            break
        }
        if device.supportsFamily(.metal3) { families.append("metal3") }
        if device.supportsFamily(.common3) { families.append("common3") }
        return families
    }

    public static func sysctl(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "?" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "?" }
        return String(cString: buffer)
    }

    static func chipName() -> String {
        let brand = sysctl("machdep.cpu.brand_string")
        if brand != "?" { return brand }
        // iOS has no brand string; the machine identifier is the honest answer.
        return sysctl("hw.machine")
    }

    static func osVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        #if os(iOS)
        let name = "iOS"
        #elseif os(macOS)
        let name = "macOS"
        #elseif os(watchOS)
        let name = "watchOS"
        #else
        let name = "OS"
        #endif
        return "\(name) \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    static func thermalState() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    static func fourCC(_ value: UInt32) -> String {
        let bytes = [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
            return String(bytes: bytes, encoding: .ascii) ?? String(value)
        }
        return String(format: "0x%08X", value)
    }
}
