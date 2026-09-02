import Foundation
import ImageIO

/// Reading a shoot the app did not take.
///
/// An interval capture made here arrives with its own record: `frames.timestamps`
/// says when every frame fired and what it was exposed at, `capture_log.json`
/// says what the session as a whole was, and everything downstream — the warp
/// axis, the exposure trail, the project's format line — is built on those.
/// A folder of files off a camera arrives with none of it.
///
/// It is not, however, arriving with *nothing*. The camera wrote most of the
/// same facts into every frame's EXIF as it shot: shutter, aperture, ISO, the
/// moment the shutter fired (to the millisecond, via SubSecTimeOriginal), the
/// body, the lens, the pixel size, sometimes a fix. This file reads those out
/// and rebuilds the sidecars from them, so an imported shoot lands in the same
/// shape as a captured one rather than as a bare pile of frames.
///
/// **What is inferred is inferred, and what is missing stays missing.** Every
/// field here is optional and nothing is defaulted into existence: a frame
/// whose EXIF has no ISO gets no ISO, not a zero, because the whole value of
/// the record is that a reader can tell "the camera didn't say" from "the
/// camera said this". The one thing this file computes rather than reads is
/// the interval, which is a measurement of the timestamps and is labelled as
/// such.
public enum ImportedStills {

    /// Where a frame was taken, when the file says.
    public struct Location: Equatable, Sendable {
        public var latitude: Double
        public var longitude: Double
        public var altitude: Double?

        public init(latitude: Double, longitude: Double, altitude: Double? = nil) {
            self.latitude = latitude
            self.longitude = longitude
            self.altitude = altitude
        }
    }

    /// One imported file, as its own metadata describes it.
    public struct Frame: Equatable, Sendable {
        public var url: URL
        /// When the shutter fired, to whatever precision the file carries —
        /// see `Self.captureDate(from:)` for how the second and the sub-second
        /// tags are put back together.
        public var capturedAt: Date?
        public var exposure: DNGAuthor.DNGExposure
        public var pixelWidth: Int?
        public var pixelHeight: Int?
        /// EXIF orientation 1–8, as stored. Not applied to anything here; the
        /// decoders bake it when they read the frame.
        public var orientation: Int?
        public var focalLength: Double?
        public var focalLength35mm: Double?
        public var lensModel: String?
        public var cameraMake: String?
        public var cameraModel: String?
        public var software: String?
        public var location: Location?
        /// File size in bytes, so the session log can carry the same
        /// `fileBytes` a captured run records per frame.
        public var byteCount: Int?

        public init(
            url: URL,
            capturedAt: Date? = nil,
            exposure: DNGAuthor.DNGExposure = .init(),
            pixelWidth: Int? = nil,
            pixelHeight: Int? = nil,
            orientation: Int? = nil,
            focalLength: Double? = nil,
            focalLength35mm: Double? = nil,
            lensModel: String? = nil,
            cameraMake: String? = nil,
            cameraModel: String? = nil,
            software: String? = nil,
            location: Location? = nil,
            byteCount: Int? = nil
        ) {
            self.url = url
            self.capturedAt = capturedAt
            self.exposure = exposure
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
            self.orientation = orientation
            self.focalLength = focalLength
            self.focalLength35mm = focalLength35mm
            self.lensModel = lensModel
            self.cameraMake = cameraMake
            self.cameraModel = cameraModel
            self.software = software
            self.location = location
            self.byteCount = byteCount
        }
    }

    /// A whole imported set, in capture order, with the facts that are
    /// properties of the shoot rather than of any one frame.
    public struct Sequence: Equatable, Sendable {
        /// Capture order — see `probe(urls:)` for how it is decided.
        public var frames: [Frame]

        public init(frames: [Frame]) {
            self.frames = frames
        }

        public var isEmpty: Bool { frames.isEmpty }
        public var count: Int { frames.count }

        /// Every frame's capture time, in order, when **every** frame has one.
        /// All-or-nothing on purpose: a half-timed sequence would lay some
        /// frames on the real clock and the rest on nothing, which is worse
        /// than laying all of them out evenly.
        public var captureTimes: [Date]? {
            let times = frames.compactMap(\.capturedAt)
            return times.count == frames.count ? times : nil
        }

        public var startedAt: Date? { captureTimes?.first }
        public var endedAt: Date? { captureTimes?.last }

        /// Wall-clock span of the shoot, first shutter to last.
        public var elapsedSeconds: Double? {
            guard let times = captureTimes, let first = times.first, let last = times.last
            else { return nil }
            let span = last.timeIntervalSince(first)
            return span > 0 ? span : nil
        }

        /// The shoot's interval, as the **median** gap between consecutive
        /// frames.
        ///
        /// Median rather than mean because a real shoot has holes in it — a
        /// battery change, a card swap, the photographer stopping to reframe —
        /// and one ten-minute hole drags a mean interval far away from the
        /// number that describes every other frame in the set. The median is
        /// what the intervalometer was actually set to.
        public var intervalSeconds: Double? {
            guard let times = captureTimes, times.count >= 2 else { return nil }
            let gaps = zip(times.dropFirst(), times).map { $0.timeIntervalSince($1) }
                .filter { $0 > 0 }
                .sorted()
            guard !gaps.isEmpty else { return nil }
            let middle = gaps.count / 2
            return gaps.count.isMultiple(of: 2)
                ? (gaps[middle - 1] + gaps[middle]) / 2
                : gaps[middle]
        }

        /// Whether the capture times ascend along the order the set was
        /// given in. False means the files were handed over in an order their
        /// own EXIF disagrees with — worth saying out loud, never worth
        /// silently correcting (see `probe(urls:)`).
        public var captureTimesFollowOrder: Bool {
            guard let times = captureTimes else { return true }
            return zip(times.dropFirst(), times).allSatisfy { $0 >= $1 }
        }

        /// Gaps materially longer than the interval — where the shoot paused.
        /// `factor` is how many intervals a gap has to reach before it counts
        /// as one; 3 keeps ordinary jitter (and a camera that missed a beat)
        /// out of the list.
        public func gaps(factor: Double = 3) -> [(afterIndex: Int, seconds: Double)] {
            guard let times = captureTimes, let interval = intervalSeconds, interval > 0
            else { return [] }
            var found: [(Int, Double)] = []
            for index in 1..<max(times.count, 1) {
                let gap = times[index].timeIntervalSince(times[index - 1])
                if gap > interval * factor { found.append((index - 1, gap)) }
            }
            return found
        }

        /// The pixel size the set was shot at — the first frame that states
        /// one. Mixed-size imports keep their own per-frame values; this is
        /// the project-level answer, matching what `sourceWidth`/`sourceHeight`
        /// mean for a capture.
        public var pixelSize: (width: Int, height: Int)? {
            for frame in frames {
                if let width = frame.pixelWidth, let height = frame.pixelHeight,
                   width > 0, height > 0 {
                    return (width, height)
                }
            }
            return nil
        }

        /// The camera, as one readable name: "SONY ILCE-7M4", or just the
        /// model when it already carries the maker ("Canon EOS R5"), or the
        /// maker alone when that is all there is.
        public var cameraName: String? {
            let make = frames.compactMap(\.cameraMake).first?
                .trimmingCharacters(in: .whitespaces)
            let model = frames.compactMap(\.cameraModel).first?
                .trimmingCharacters(in: .whitespaces)
            switch (make?.nilIfEmpty, model?.nilIfEmpty) {
            case let (make?, model?):
                // Canon writes "Canon EOS R5" into Model; Sony writes
                // "ILCE-7M4" and leaves the make to the make tag. Prefixing
                // blindly gives "Canon Canon EOS R5".
                if model.lowercased().hasPrefix(make.lowercased()) { return model }
                return "\(make) \(model)"
            case let (make?, nil): return make
            case let (nil, model?): return model
            default: return nil
            }
        }

        public var lensName: String? {
            frames.compactMap(\.lensModel).first?
                .trimmingCharacters(in: .whitespaces).nilIfEmpty
        }

        /// The first fix any frame carries — a timelapse is shot from one
        /// place, so the shoot has a location even though only some frames
        /// may record it.
        public var location: Location? { frames.compactMap(\.location).first }

        /// Distinct file types in the set, uppercased, first-seen order —
        /// the same vocabulary `CaptureProject.sourceFormatLabels` speaks.
        public var formatLabels: [String] {
            var labels: [String] = []
            for frame in frames {
                let ext = frame.url.pathExtension.uppercased()
                guard !ext.isEmpty else { continue }
                let label = ImportedStills.formatLabel(for: ext)
                if !labels.contains(label) { labels.append(label) }
            }
            return labels
        }

        /// True when the shutter, aperture and ISO are the same on every frame
        /// that states them — a locked-down manual shoot. The interesting
        /// negative is a shoot that ramped, which is what a bulb-ramped or
        /// auto-exposed sunset looks like from the outside.
        public var hasConstantExposure: Bool {
            let readings = frames.map { ($0.exposure.exposureDuration, $0.exposure.iso, $0.exposure.aperture) }
                .filter { $0.0 != nil || $0.1 != nil || $0.2 != nil }
            guard let first = readings.first else { return true }
            return readings.allSatisfy { $0 == first }
        }

        /// EV range across the shoot, at ISO 100, for the frames that state
        /// all three of aperture, shutter and ISO.
        public var exposureValueRange: (low: Double, high: Double)? {
            let values = frames.compactMap(\.exposure.exposureValue)
            guard let low = values.min(), let high = values.max() else { return nil }
            return (low, high)
        }

        // MARK: - Rebuilding the sidecars

        /// The `frames.timestamps` a capture of this shoot would have written.
        ///
        /// Nil when the set has no usable clock: without capture times this
        /// sidecar would be a list of guesses, and its absence is already
        /// meaningful downstream — every reader falls back to even spacing,
        /// which is exactly the right behaviour for frames whose real spacing
        /// is unknown.
        ///
        /// Shutter and ISO are non-optional in the entry, so a frame missing
        /// either records 0 — the same thing the capture path writes when the
        /// camera reports nothing. `ev` stays properly optional.
        public func frameTimestamps() -> FrameTimestamps? {
            guard let times = captureTimes else { return nil }
            let entries = zip(frames.indices, times).map { index, time in
                FrameTimestamps.Entry(
                    frame: index,
                    captureTime: time,
                    shutter: frames[index].exposure.exposureDuration ?? 0,
                    iso: frames[index].exposure.iso ?? 0,
                    ev: frames[index].exposure.exposureValue)
            }
            return FrameTimestamps(entries: entries)
        }

        /// The per-capture exposure lines (`frames.exposure`).
        ///
        /// One line per file, because that is what an import is: nothing was
        /// blended on the way in, so what landed and what was captured are the
        /// same set of frames.
        public func exposureEntries() -> [CaptureExposureLog.Entry] {
            frames.enumerated().map { index, frame in
                CaptureExposureLog.Entry(
                    frameIndex: index,
                    exposure: frame.exposure,
                    capturedAt: frame.capturedAt)
            }
        }

        /// The session document (`capture_log.json`).
        ///
        /// The mapping is deliberately literal about what an import is:
        ///
        /// - `deviceModel` / `cameraName` — the camera that took it, not the
        ///   device doing the importing. The log's job is to describe the
        ///   shoot, and the shoot happened on the other body.
        /// - `blendMode` is `"1"` — depth 1, no blending. Each file is one
        ///   frame; nothing was stacked at capture time.
        /// - `endReason` is `"imported"`, which is the honest answer to how
        ///   the run ended as far as this app can know: it didn't watch it end.
        /// - Per-frame `window` performance is left absent throughout. A window
        ///   is something this app's capture engine schedules and measures;
        ///   inventing empty ones would put a delivery record into the file
        ///   that nobody delivered.
        public func captureSession(
            sessionID: String,
            captureMode: String = ImportedStills.importedCaptureMode
        ) -> CaptureExposureLog.Session {
            CaptureExposureLog.Session(
                sessionID: sessionID,
                deviceModel: cameraName ?? "Unknown camera",
                captureMode: captureMode,
                blendMode: "1",
                cameraName: lensName ?? cameraName,
                captureWidth: pixelSize?.width,
                captureHeight: pixelSize?.height,
                intervalSeconds: intervalSeconds,
                endReason: "imported",
                startedAt: startedAt,
                endedAt: endedAt,
                frames: exposureEntries(),
                issues: issues().nilIfEmpty)
        }

        /// What is worth flagging about the set, in the same trail a shoot
        /// records its own problems in. Everything here is a measurement of
        /// the files, so it is stamped at the moment it describes rather than
        /// at import time.
        public func issues() -> [CaptureExposureLog.Issue] {
            var found: [CaptureExposureLog.Issue] = []
            if captureTimes == nil, let anchor = frames.compactMap(\.capturedAt).first ?? nil {
                found.append(.init(
                    at: anchor, kind: "importTiming", severity: "warning",
                    detail: "Some frames carry no capture time; the clip is laid out evenly."))
            }
            guard let times = captureTimes else { return found }
            if !captureTimesFollowOrder, let first = times.first {
                found.append(.init(
                    at: first, kind: "importOrder", severity: "warning",
                    detail: "Frames were imported in an order their capture times disagree with."))
            }
            for (afterIndex, seconds) in gaps() {
                found.append(.init(
                    at: times[afterIndex], windowIndex: afterIndex,
                    kind: "importGap", severity: "info",
                    detail: String(
                        format: "%.0fs gap before frame %d.", seconds, afterIndex + 2)))
            }
            // A set whose files disagree about pixel size will blend, but the
            // stack sizes itself on the first frame — worth recording where a
            // later surprise can be traced to.
            let sizes = Set(frames.compactMap { frame -> String? in
                guard let width = frame.pixelWidth, let height = frame.pixelHeight
                else { return nil }
                return "\(width)x\(height)"
            })
            if sizes.count > 1, let first = times.first {
                found.append(.init(
                    at: first, kind: "importMixedSize", severity: "warning",
                    detail: "Frames are not all the same size: \(sizes.sorted().joined(separator: ", "))."))
            }
            return found
        }
    }

    /// The `captureMode` an imported still sequence records in its session
    /// log, beside the engine's own "interval" and "dynamic".
    public static let importedCaptureMode = "imported"

    // MARK: - Probing

    /// File types worth offering to a stills import. Raw formats first (the
    /// case this exists for), then the ordinary processed stills.
    ///
    /// Extensions rather than UTIs because the set has to survive a file
    /// arriving with no type declared — a card copied off a camera through
    /// three operating systems often has exactly that.
    public static let stillExtensions: Set<String> = [
        // Raw
        "dng", "arw", "sr2", "srf", "cr2", "cr3", "crw", "nef", "nrw", "orf",
        "raf", "rw2", "raw", "pef", "srw", "erf", "3fr", "fff", "iiq", "mos",
        "mrw", "x3f", "gpr",
        // Processed
        "jpg", "jpeg", "heic", "heif", "png", "tif", "tiff", "webp",
    ]

    /// Raw file types — the ones that must go through `CIRAWFilter` rather
    /// than ImageIO's index-0 decode. `.raw` and `.dng` were the app's whole
    /// vocabulary while every raw file it saw was one it had written itself.
    public static let rawExtensions: Set<String> = [
        "dng", "arw", "sr2", "srf", "cr2", "cr3", "crw", "nef", "nrw", "orf",
        "raf", "rw2", "raw", "pef", "srw", "erf", "3fr", "fff", "iiq", "mos",
        "mrw", "x3f", "gpr",
    ]

    public static func isRaw(_ url: URL) -> Bool {
        rawExtensions.contains(url.pathExtension.lowercased())
    }

    public static func isStill(_ url: URL) -> Bool {
        stillExtensions.contains(url.pathExtension.lowercased())
    }

    /// One spelling per file type, matching `CaptureProject.sourceFormatLabel`.
    public static func formatLabel(for ext: String) -> String {
        switch ext.uppercased() {
        case "JPEG": return "JPG"
        case "TIFF": return "TIF"
        case "HEIF": return "HEIC"
        default: return ext.uppercased()
        }
    }

    /// Every still directly inside `directory`, sorted by name.
    ///
    /// Shallow on purpose. A card's `DCIM` tree holds several numbered
    /// folders that are usually several different shoots, and walking them
    /// into one project would silently splice them together.
    public static func stills(in directory: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])) ?? []
        return contents.filter(isStill).sorted { lhs, rhs in
            lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent)
                == .orderedAscending
        }
    }

    /// Reads the metadata of every file, **in the order it is given**.
    ///
    /// Header reads only — no frame is decoded, so this costs milliseconds per
    /// file even on raws that take a second each to develop.
    ///
    /// **The order handed in is the shoot's order, and nothing here second-
    /// guesses it.** An import's frame order is the one thing the person doing
    /// the importing can see and control — it is what their file browser
    /// showed them — and a set silently resequenced on EXIF timestamps is a
    /// set they can no longer reason about. Bodies whose clocks are wrong, two
    /// cameras merged into one shoot, a night that crossed the 9999 rollover:
    /// all of those are the operator's call, made in the picker.
    ///
    /// What this does instead is *notice*. When the capture times run counter
    /// to the given order, `Sequence.captureTimesFollowOrder` is false and the
    /// session log records an issue saying so — visible, and still theirs to
    /// act on.
    ///
    /// `progress` is called on the calling thread as each file is read.
    public static func probe(
        urls: [URL],
        progress: ((Int, Int) -> Void)? = nil
    ) -> Sequence {
        var frames: [Frame] = []
        frames.reserveCapacity(urls.count)
        for (index, url) in urls.enumerated() {
            frames.append(frame(at: url))
            progress?(index + 1, urls.count)
        }
        return Sequence(frames: frames)
    }

    /// One file's metadata. Never throws: a file that cannot be opened, or
    /// that carries no metadata at all, still becomes a frame — it is one of
    /// the shoot's images either way, and dropping it would silently shorten
    /// the import.
    public static func frame(at url: URL) -> Frame {
        var frame = Frame(url: url)
        frame.byteCount = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize

        guard let source = CGImageSourceCreateWithURL(
            url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                  as? [CFString: Any]
        else { return frame }

        frame.pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int
        frame.pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int
        frame.orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue

        let exif = properties[kCGImagePropertyExifDictionary] as? [String: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [String: Any] ?? [:]
        let aux = properties[kCGImagePropertyExifAuxDictionary] as? [String: Any] ?? [:]

        frame.capturedAt = captureDate(exif: exif, tiff: tiff)
            ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
        frame.exposure = DNGAuthor.DNGExposure(
            exifDictionary: exif, capturedAt: frame.capturedAt)

        func number(_ dictionary: [String: Any], _ key: CFString) -> Double? {
            dictionary[key as String] as? Double
                ?? (dictionary[key as String] as? NSNumber)?.doubleValue
        }
        func text(_ dictionary: [String: Any], _ key: CFString) -> String? {
            (dictionary[key as String] as? String)?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        }

        frame.focalLength = number(exif, kCGImagePropertyExifFocalLength)
        frame.focalLength35mm = number(exif, kCGImagePropertyExifFocalLenIn35mmFilm)
        // Some bodies write the lens only into the Aux dictionary, some only
        // into EXIF, and a few disagree with themselves — EXIF's is the one
        // the lens actually reported, so it wins.
        frame.lensModel = text(exif, kCGImagePropertyExifLensModel)
            ?? text(aux, kCGImagePropertyExifAuxLensModel)
        frame.cameraMake = text(tiff, kCGImagePropertyTIFFMake)
        frame.cameraModel = text(tiff, kCGImagePropertyTIFFModel)
        frame.software = text(tiff, kCGImagePropertyTIFFSoftware)
        frame.location = location(
            properties[kCGImagePropertyGPSDictionary] as? [String: Any] ?? [:])
        return frame
    }

    // MARK: - Dates

    /// EXIF's capture time, at the precision the file actually carries.
    ///
    /// Three tags, in the order a reader has to consult them:
    ///
    /// - `DateTimeOriginal` — "2026:08:31 20:29:27", whole seconds, no zone.
    /// - `SubsecTimeOriginal` — the fraction, as a digit string ("211" = .211).
    ///   **This matters more than it looks.** A 3.6-second interval quantised
    ///   onto whole seconds gains ±0.5 s of jitter that nothing in the scene
    ///   explains, and the warp axis reads that jitter as real pacing.
    /// - `OffsetTimeOriginal` — the zone, EXIF 2.31 and later. Absent on most
    ///   files, including plenty of current bodies.
    ///
    /// Without an offset the stamp is read in the **current** time zone, which
    /// is what every photo tool does and is right often enough to be the least
    /// surprising answer. It can only be wrong by a whole-hour offset, and
    /// nothing derived from these dates — spacing, interval, span, the warp
    /// axis — is affected by that: they are all differences.
    public static func captureDate(exif: [String: Any], tiff: [String: Any]) -> Date? {
        let stamp = (exif[kCGImagePropertyExifDateTimeOriginal as String] as? String)
            ?? (exif[kCGImagePropertyExifDateTimeDigitized as String] as? String)
            ?? (tiff[kCGImagePropertyTIFFDateTime as String] as? String)
        guard let stamp else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        if let offset = exif["OffsetTimeOriginal"] as? String,
           let zone = timeZone(fromEXIFOffset: offset) {
            formatter.timeZone = zone
        }
        guard let date = formatter.date(from: stamp) else { return nil }

        let subsecond = (exif[kCGImagePropertyExifSubsecTimeOriginal as String] as? String)
            ?? (exif[kCGImagePropertyExifSubsecTimeDigitized as String] as? String)
        guard let digits = subsecond?.trimmingCharacters(in: .whitespaces),
              !digits.isEmpty, digits.allSatisfy(\.isNumber),
              let fraction = Double("0.\(digits)")
        else { return date }
        return date.addingTimeInterval(fraction)
    }

    /// "+02:00" / "-0500" / "Z" → a fixed-offset zone.
    static func timeZone(fromEXIFOffset raw: String) -> TimeZone? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed == "Z" { return TimeZone(secondsFromGMT: 0) }
        guard let sign = trimmed.first, sign == "+" || sign == "-" else { return nil }
        let digits = trimmed.dropFirst().filter(\.isNumber)
        guard digits.count == 4,
              let hours = Int(digits.prefix(2)), let minutes = Int(digits.suffix(2))
        else { return nil }
        let seconds = (hours * 3600 + minutes * 60) * (sign == "-" ? -1 : 1)
        return TimeZone(secondsFromGMT: seconds)
    }

    // MARK: - GPS

    static func location(_ gps: [String: Any]) -> Location? {
        func number(_ key: CFString) -> Double? {
            gps[key as String] as? Double ?? (gps[key as String] as? NSNumber)?.doubleValue
        }
        guard var latitude = number(kCGImagePropertyGPSLatitude),
              var longitude = number(kCGImagePropertyGPSLongitude)
        else { return nil }
        // EXIF stores magnitude and hemisphere separately.
        if (gps[kCGImagePropertyGPSLatitudeRef as String] as? String)?.uppercased() == "S" {
            latitude = -latitude
        }
        if (gps[kCGImagePropertyGPSLongitudeRef as String] as? String)?.uppercased() == "W" {
            longitude = -longitude
        }
        var altitude = number(kCGImagePropertyGPSAltitude)
        if let reference = number(kCGImagePropertyGPSAltitudeRef), reference == 1,
           let value = altitude {
            altitude = -value  // 1 = below sea level.
        }
        return Location(latitude: latitude, longitude: longitude, altitude: altitude)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension Array {
    var nilIfEmpty: [Element]? { isEmpty ? nil : self }
}
