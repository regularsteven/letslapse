import CoreLocation
import Foundation

/// Writes a minimal GPX 1.1 track from a location log — one `<trkpt>` per point,
/// used as a sidecar next to internally captured video.
struct GPXWriter {
    static func write(points: [(timestamp: Date, location: CLLocation)], to url: URL) throws {
        let formatter = ISO8601DateFormatter()
        var lines = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            #"<gpx version="1.1" creator="LetsLapse" xmlns="http://www.topografix.com/GPX/1/1">"#,
            "<trk><name>LetsLapse Capture</name><trkseg>"
        ]
        for point in points {
            let lat = String(format: "%.7f", point.location.coordinate.latitude)
            let lon = String(format: "%.7f", point.location.coordinate.longitude)
            let ele = String(format: "%.1f", point.location.altitude)
            let time = formatter.string(from: point.timestamp)
            lines.append(#"<trkpt lat="\#(lat)" lon="\#(lon)"><ele>\#(ele)</ele><time>\#(time)</time></trkpt>"#)
        }
        lines += ["</trkseg></trk></gpx>"]
        let xml = lines.joined(separator: "\n")
        try xml.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Reads back what `GPXWriter` writes — only as much as the geotagging path
/// needs, which is the track's starting point. A take's sidecar is the fallback
/// carrier for its location when no fix ever cleared the accuracy threshold
/// during recording, so nothing was baked into the movie itself.
enum GPXReader {
    /// The first `<trkpt>` of the `.gpx` sidecar beside the movie at `movieURL`
    /// (same base name), or nil when there is no sidecar or no point in it.
    static func firstPoint(besideMovieAt movieURL: URL) -> CLLocation? {
        let sidecarURL = movieURL.deletingPathExtension().appendingPathExtension("gpx")
        guard FileManager.default.fileExists(atPath: sidecarURL.path) else { return nil }
        return firstPoint(in: sidecarURL)
    }

    /// The first track point of the GPX file at `url`. Deliberately a shallow
    /// string scan rather than an XML parse: this reads one attribute pair out
    /// of a file this app wrote, and a malformed sidecar should come back nil
    /// rather than throw.
    static func firstPoint(in url: URL) -> CLLocation? {
        guard let xml = try? String(contentsOf: url, encoding: .utf8),
              let pointRange = xml.range(of: "<trkpt ") else { return nil }
        let point = xml[pointRange.lowerBound...].prefix(400)
        guard let latitude = attribute("lat", in: point),
              let longitude = attribute("lon", in: point) else { return nil }
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }

        let elevation = element("ele", in: point)
        // The sidecar records no error estimate; Photos treats a negative
        // accuracy as "no fix", so stand in a plausible consumer-GPS figure —
        // the same convention as `CLLocation(exifGPS:)`.
        return CLLocation(
            coordinate: coordinate,
            altitude: elevation ?? 0,
            horizontalAccuracy: 10,
            verticalAccuracy: elevation == nil ? -1 : 10,
            timestamp: Date())
    }

    private static func attribute(_ name: String, in text: Substring) -> Double? {
        guard let range = text.range(of: "\(name)=\"") else { return nil }
        let rest = text[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return Double(rest[..<end])
    }

    private static func element(_ name: String, in text: Substring) -> Double? {
        guard let range = text.range(of: "<\(name)>") else { return nil }
        let rest = text[range.upperBound...]
        guard let end = rest.range(of: "</\(name)>") else { return nil }
        return Double(rest[..<end.lowerBound])
    }
}
