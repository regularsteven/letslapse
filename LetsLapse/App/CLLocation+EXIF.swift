import CoreLocation
import Foundation
import ImageIO

extension CLLocation {
    /// The EXIF GPS dictionary for this fix, keyed for `kCGImagePropertyGPSDictionary`.
    func exifGPSDictionary() -> [String: Any] {
        let lat = coordinate.latitude
        let lon = coordinate.longitude
        let alt = altitude
        var dict: [String: Any] = [
            kCGImagePropertyGPSLatitude as String: abs(lat),
            kCGImagePropertyGPSLatitudeRef as String: lat >= 0 ? "N" : "S",
            kCGImagePropertyGPSLongitude as String: abs(lon),
            kCGImagePropertyGPSLongitudeRef as String: lon >= 0 ? "E" : "W",
            kCGImagePropertyGPSAltitude as String: abs(alt),
            kCGImagePropertyGPSAltitudeRef as String: alt >= 0 ? 0 : 1
        ]
        let cal = Calendar(identifier: .gregorian)
        let utc = TimeZone(identifier: "UTC")!
        let comps = cal.dateComponents(in: utc, from: timestamp)
        let timeStr = String(format: "%02d:%02d:%02d", comps.hour ?? 0, comps.minute ?? 0, comps.second ?? 0)
        let dateStr = String(format: "%04d:%02d:%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
        dict[kCGImagePropertyGPSTimeStamp as String] = timeStr
        dict[kCGImagePropertyGPSDateStamp as String] = dateStr
        return dict
    }

    /// The fix a still carries in its EXIF GPS block — a JPEG's EXIF or a DNG's
    /// GPS sub-IFD, both read through ImageIO — or nil when the file has none.
    ///
    /// The inverse of `exifGPSDictionary()`, and how a save to Photos recovers
    /// the location that was baked in at capture time. Reads only the file's
    /// metadata (no pixel decode), but it is still file I/O: keep it off the
    /// main thread for anything more than a single file.
    static func fromEXIF(of url: URL) -> CLLocation? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any]
        else { return nil }
        return CLLocation(exifGPS: gps)
    }

    /// Rebuilds a fix from an EXIF GPS dictionary: unsigned degrees plus a
    /// hemisphere letter become a signed coordinate, and the UTC date/time
    /// stamps become the fix's timestamp. Returns nil unless the dictionary
    /// yields a valid coordinate — a GPS block with only an altitude or a
    /// timestamp isn't a location.
    convenience init?(exifGPS gps: [CFString: Any]) {
        func number(_ key: CFString) -> Double? {
            if let value = gps[key] as? NSNumber { return value.doubleValue }
            if let text = gps[key] as? String { return Double(text) }
            return nil
        }
        func reference(_ key: CFString) -> String? {
            (gps[key] as? String)?.trimmingCharacters(in: .whitespaces).uppercased()
        }
        guard var latitude = number(kCGImagePropertyGPSLatitude),
              var longitude = number(kCGImagePropertyGPSLongitude) else { return nil }
        if reference(kCGImagePropertyGPSLatitudeRef) == "S" { latitude = -latitude }
        if reference(kCGImagePropertyGPSLongitudeRef) == "W" { longitude = -longitude }
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }

        var altitude = number(kCGImagePropertyGPSAltitude) ?? 0
        // AltitudeRef 1 means "below sea level"; the tag itself is unsigned.
        if let ref = number(kCGImagePropertyGPSAltitudeRef), ref == 1 { altitude = -altitude }

        // Photos treats a negative accuracy as "no valid fix", so fall back to a
        // plausible consumer-GPS figure when the file records no error estimate.
        let horizontalAccuracy = number(kCGImagePropertyGPSHPositioningError) ?? 10
        let timestamp = Self.exifGPSTimestamp(gps) ?? Date()
        self.init(
            coordinate: coordinate,
            altitude: altitude,
            horizontalAccuracy: horizontalAccuracy,
            verticalAccuracy: altitude == 0 ? -1 : horizontalAccuracy,
            timestamp: timestamp)
    }

    /// The UTC instant from the GPS date and time stamps (`"yyyy:MM:dd"` and
    /// `"HH:mm:ss"`, as `exifGPSDictionary()` writes them), or nil if either is
    /// missing or malformed.
    private static func exifGPSTimestamp(_ gps: [CFString: Any]) -> Date? {
        guard let dateStamp = gps[kCGImagePropertyGPSDateStamp] as? String,
              let timeStamp = gps[kCGImagePropertyGPSTimeStamp] as? String else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        // Some writers emit fractional seconds; the whole-second prefix is enough.
        let seconds = timeStamp.split(separator: ".").first.map(String.init) ?? timeStamp
        return formatter.date(from: "\(dateStamp) \(seconds)")
    }
}
