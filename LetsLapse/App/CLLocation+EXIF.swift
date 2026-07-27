import CoreLocation
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
}
