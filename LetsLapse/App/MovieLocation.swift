import AVFoundation
import CoreLocation
import Foundation

/// The GPS fix a movie carries in its own metadata, written and read as the
/// `com.apple.quicktime.location.ISO6709` atom — where iOS Camera puts a clip's
/// place, and where Photos, Finder and Maps look for it.
///
/// The stills path has the same shape in `CLLocation+EXIF.swift`: bake the fix
/// into the captured file, then read it back out of the file when the asset is
/// handed to Photos. Video needs its own carrier because a movie has no EXIF
/// block, and because the GPX sidecar written beside a take doesn't follow the
/// clip into its project folder.
enum MovieLocation {
    /// The horizontal accuracy, in metres, at or below which a fix is good
    /// enough to stamp on a recording. Core Location reports a negative
    /// accuracy when it has no valid fix at all, so both ends matter.
    static let accuracyThreshold: CLLocationDistance = 50

    /// Whether `location` is a fix worth recording — see `accuracyThreshold`.
    static func isAccurate(_ location: CLLocation) -> Bool {
        location.horizontalAccuracy > 0 && location.horizontalAccuracy <= accuracyThreshold
    }

    /// Accuracy stamped on a fix recovered from a file that records no error
    /// estimate of its own. Photos reads a negative accuracy as "no fix", so a
    /// plausible consumer-GPS figure stands in — the same convention as
    /// `CLLocation(exifGPS:)`. Movies this app writes carry their real accuracy
    /// in a companion atom, so this is only for files from elsewhere.
    private static let recoveredAccuracy: CLLocationDistance = 10

    private static let accuracyIdentifier: AVMetadataIdentifier =
        .quickTimeMetadataLocationHorizontalAccuracyInMeters

    // MARK: - ISO 6709

    /// `±DD.DDDD±DDD.DDDD±AAA.AAA/` — ISO 6709 Annex H in the decimal-degrees
    /// form iOS Camera writes, e.g. `+51.5074-000.1278+021.000/`. The fixed
    /// field widths are part of the format: two integer digits of latitude,
    /// three of longitude, an explicit sign on each field and a trailing
    /// solidus. Altitude is omitted when Core Location has no vertical fix,
    /// which the format allows.
    static func iso6709(for location: CLLocation) -> String {
        let latitude = location.coordinate.latitude
        let longitude = location.coordinate.longitude
        guard location.verticalAccuracy > 0 else {
            return String(format: "%+08.4f%+09.4f/", latitude, longitude)
        }
        return String(
            format: "%+08.4f%+09.4f%+08.3f/", latitude, longitude, location.altitude)
    }

    /// Parses the decimal-degrees ISO 6709 form back into a fix, or nil if the
    /// text doesn't yield a valid coordinate.
    ///
    /// Handles what this app and iOS Camera write: signed decimal degrees, with
    /// or without the altitude field, with or without the trailing solidus and
    /// a CRS designator. The standard's sexagesimal forms (`±DDMM.MM`) are not
    /// decoded — nothing in this pipeline produces them, and mistaking one for
    /// decimal degrees would place the pin in the wrong country.
    static func location(fromISO6709 text: String, horizontalAccuracy: CLLocationDistance? = nil)
        -> CLLocation? {
        var fields: [String] = []
        var current = ""
        for character in text.trimmingCharacters(in: .whitespacesAndNewlines) {
            if character == "+" || character == "-" {
                if !current.isEmpty { fields.append(current) }
                current = String(character)
            } else if character.isNumber || character == "." {
                current.append(character)
            } else {
                // A solidus, a CRS designator, or junk: the numeric run is over.
                break
            }
        }
        if !current.isEmpty { fields.append(current) }

        guard fields.count >= 2,
              let latitude = Double(fields[0]),
              let longitude = Double(fields[1]) else { return nil }
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }

        let altitude = fields.count >= 3 ? (Double(fields[2]) ?? 0) : 0
        let accuracy = horizontalAccuracy.map { $0 > 0 ? $0 : recoveredAccuracy }
            ?? recoveredAccuracy
        return CLLocation(
            coordinate: coordinate,
            altitude: altitude,
            horizontalAccuracy: accuracy,
            verticalAccuracy: fields.count >= 3 ? accuracy : -1,
            timestamp: Date())
    }

    // MARK: - Reading

    /// The fix stored in the movie at `url`, or nil when it carries none.
    ///
    /// Reads the movie header only — no pixel decode — but it is still file
    /// I/O: keep it off the main thread.
    static func read(from url: URL) -> CLLocation? {
        guard let movie = try? AVMutableMovie(url: url, options: nil) else { return nil }
        return location(in: movie.metadata)
    }

    /// The fix to stamp on a Photos asset created from the movie at `url`: the
    /// movie's own metadata, or failing that the first point of a `.gpx`
    /// sidecar beside it — the track a take writes before its clip is imported
    /// into a project.
    static func locationForSaving(at url: URL) -> CLLocation? {
        read(from: url) ?? GPXReader.firstPoint(besideMovieAt: url)
    }

    /// The location among `items`, preferring the QuickTime movie-metadata atom
    /// this app and iOS Camera write, then the older user-data atom, then
    /// whatever the common key resolves to for other containers.
    static func location(in items: [AVMetadataItem]) -> CLLocation? {
        let accuracy = AVMetadataItem
            .metadataItems(from: items, filteredByIdentifier: accuracyIdentifier)
            .compactMap { $0.numberValue?.doubleValue }
            .first
        let identifiers: [AVMetadataIdentifier] = [
            .quickTimeMetadataLocationISO6709,
            .quickTimeUserDataLocationISO6709,
            .commonIdentifierLocation
        ]
        for identifier in identifiers {
            for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier) {
                if let text = item.stringValue,
                   let location = location(fromISO6709: text, horizontalAccuracy: accuracy) {
                    return location
                }
            }
        }
        return nil
    }

    // MARK: - Writing

    /// Writes `location` into the movie at `url`, replacing any location the
    /// file already carries and leaving every other metadata item — and every
    /// byte of media data — alone. Returns false, with the file as it was, if
    /// any step fails: a take without a map pin beats a take that won't play.
    ///
    /// Only the movie header is rewritten, so there is no re-encode and a long
    /// 4K take costs milliseconds rather than minutes. The safety net is a
    /// clone of the original taken first: on APFS that shares the file's blocks,
    /// so it costs no space and no time, and it is restored if the rewritten
    /// header doesn't read back as a playable movie carrying the fix.
    @discardableResult
    static func inject(_ location: CLLocation, into url: URL) -> Bool {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let fileType: AVFileType = url.pathExtension.lowercased() == "mov" ? .mov : .mp4
        let backupURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).gps-backup")
        try? FileManager.default.removeItem(at: backupURL)
        do {
            try FileManager.default.copyItem(at: url, to: backupURL)
        } catch {
            LLog("gps: no backup for \(url.lastPathComponent) — \(error.localizedDescription)")
            return false
        }
        defer { try? FileManager.default.removeItem(at: backupURL) }

        do {
            let movie = try AVMutableMovie(url: url, options: nil)
            guard movie.is(compatibleWithFileType: fileType) else {
                LLog("gps: \(url.lastPathComponent) isn't a \(fileType.rawValue) movie")
                return false
            }
            movie.metadata = metadata(of: movie, taggedWith: location)
            // `.addMovieHeaderToDestination` replaces the existing header and
            // preserves everything else in the file. Its sibling
            // `.truncateDestinationToMovieHeaderOnly` would throw the media
            // data away — it exists to make reference movies.
            try movie.writeHeader(to: url, fileType: fileType, options: .addMovieHeaderToDestination)
        } catch {
            LLog("gps: header write failed for \(url.lastPathComponent) — \(error.localizedDescription)")
            restore(backupURL, to: url)
            return false
        }

        guard isPlayableMovie(at: url), read(from: url) != nil else {
            LLog("gps: \(url.lastPathComponent) didn't read back after tagging — restoring")
            restore(backupURL, to: url)
            return false
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        LLog(String(
            format: "gps: tagged %@ %@ in %.0f ms",
            url.lastPathComponent, iso6709(for: location), elapsed * 1000))
        return true
    }

    /// The movie's metadata with the location atoms replaced: the ISO 6709
    /// string plus the fix's own horizontal accuracy, which is what lets a
    /// later read recover the real accuracy instead of assuming one. Everything
    /// else the recorder wrote (make, model, software, creation date) is kept.
    private static func metadata(
        of movie: AVMovie, taggedWith location: CLLocation
    ) -> [AVMetadataItem] {
        let replaced: Set<AVMetadataIdentifier> = [
            .quickTimeMetadataLocationISO6709,
            .quickTimeUserDataLocationISO6709,
            .commonIdentifierLocation,
            accuracyIdentifier
        ]
        var items = movie.metadata.filter { item in
            guard let identifier = item.identifier else { return true }
            return !replaced.contains(identifier)
        }

        let iso = AVMutableMetadataItem()
        iso.identifier = .quickTimeMetadataLocationISO6709
        iso.dataType = kCMMetadataBaseDataType_UTF8 as String
        iso.value = iso6709(for: location) as NSString
        items.append(iso)

        if location.horizontalAccuracy > 0 {
            let accuracy = AVMutableMetadataItem()
            accuracy.identifier = accuracyIdentifier
            accuracy.dataType = kCMMetadataBaseDataType_Float32 as String
            accuracy.value = NSNumber(value: Float(location.horizontalAccuracy))
            items.append(accuracy)
        }
        return items
    }

    /// Whether the file still reads as a movie with playable video in it — the
    /// check that decides whether a header rewrite is kept or rolled back.
    private static func isPlayableMovie(at url: URL) -> Bool {
        guard let movie = try? AVMutableMovie(url: url, options: nil) else { return false }
        return !movie.tracks(withMediaType: .video).isEmpty && movie.duration.seconds > 0
    }

    private static func restore(_ backupURL: URL, to url: URL) {
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: backupURL)
        } catch {
            LLog("gps: restore of \(url.lastPathComponent) failed — \(error.localizedDescription)")
        }
    }
}
