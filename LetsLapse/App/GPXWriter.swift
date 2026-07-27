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
