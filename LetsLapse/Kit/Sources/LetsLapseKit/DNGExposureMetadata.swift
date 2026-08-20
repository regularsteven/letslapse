import Foundation
import ImageIO

/// Reading a capture's exposure out of the camera's own metadata, and putting
/// it back into a DNG that lost it.
///
/// Two different problems, one vocabulary:
///
/// - **Authored blends** never had the tags. A blended DNG is assembled from
///   decoded samples by `DNGAuthor`, so unless the exposure is threaded through
///   deliberately the file simply has no EXIF IFD — no ISO, no shutter, no
///   f-number, no brightness. That is fixed at authoring time by handing
///   `DNGAuthor.exifTags(_:)` to the writer.
/// - **Pass-through originals** normally carry Apple's own EXIF. When one turns
///   up without it, `repairing` rewrites the container through ImageIO and adds
///   the block. It is deliberately a repair rather than a routine step: an
///   untouched original is the ground truth the blend paths are compared
///   against, and a re-encode is not free.
extension DNGAuthor.DNGExposure {
    /// Pulls the four exposure facts out of an EXIF dictionary — the shape
    /// `AVCapturePhoto.metadata[kCGImagePropertyExifDictionary]` hands back, and
    /// the same shape `CGImageSourceCopyPropertiesAtIndex` produces.
    ///
    /// `ISOSpeedRatings` is an array in the spec and a bare number in some
    /// producers' output; both are accepted. Everything absent stays nil.
    public init(exifDictionary exif: [String: Any], capturedAt: Date? = nil) {
        func number(_ key: CFString) -> Double? {
            exif[key as String] as? Double ?? (exif[key as String] as? NSNumber)?.doubleValue
        }
        var iso = number(kCGImagePropertyExifISOSpeedRatings)
        if iso == nil,
           let ratings = exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber],
           let first = ratings.first {
            iso = first.doubleValue
        }
        self.init(
            iso: iso,
            exposureDuration: number(kCGImagePropertyExifExposureTime),
            aperture: number(kCGImagePropertyExifFNumber),
            brightness: number(kCGImagePropertyExifBrightnessValue),
            capturedAt: capturedAt)
    }

    /// The same read straight off a photo's full metadata dictionary, which
    /// nests EXIF under `kCGImagePropertyExifDictionary`.
    public init(photoMetadata metadata: [String: Any], capturedAt: Date? = nil) {
        let exif = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        self.init(exifDictionary: exif, capturedAt: capturedAt)
    }

    /// As an ImageIO property dictionary, for the CGImageDestination repair
    /// path. Keys are omitted rather than zeroed when the value is unknown.
    public var exifDictionary: [CFString: Any] {
        var exif: [CFString: Any] = [:]
        if let iso, iso > 0 { exif[kCGImagePropertyExifISOSpeedRatings] = [Int(iso.rounded())] }
        if let exposureDuration, exposureDuration > 0 {
            exif[kCGImagePropertyExifExposureTime] = exposureDuration
        }
        if let aperture, aperture > 0 { exif[kCGImagePropertyExifFNumber] = aperture }
        if let brightness { exif[kCGImagePropertyExifBrightnessValue] = brightness }
        if let capturedAt {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            exif[kCGImagePropertyExifDateTimeOriginal] = formatter.string(from: capturedAt)
        }
        return exif
    }
}

extension DNGAuthor {
    /// True when this encoded image already reports an ISO — the cheapest
    /// single question that separates "the camera's EXIF is here" from "this
    /// file has no exposure record".
    public static func hasExposureMetadata(in data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                  as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        else { return false }
        return exif[kCGImagePropertyExifISOSpeedRatings] != nil
    }

    /// Rewrites `data` through `CGImageDestination` with an EXIF dictionary
    /// added, keeping the encoded image itself (`CGImageDestinationCopyImageSource`
    /// copies the container rather than re-compressing the samples). Returns nil
    /// if the file can't be read or ImageIO refuses the rewrite, so callers fall
    /// back to the original bytes rather than losing a frame.
    public static func dngDataByInjectingEXIF(
        into data: Data, exposure: DNGExposure
    ) -> Data? {
        guard !exposure.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source),
              let output = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(output, type, 1, nil)
        else { return nil }
        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: exposure.exifDictionary
        ]
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(
            destination, source, properties as CFDictionary, &error) else { return nil }
        return output as Data
    }
}
