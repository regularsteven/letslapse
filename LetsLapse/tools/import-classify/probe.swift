import Foundation
import ImageIO

let stillExts: Set<String> = ["dng","arw","sr2","srf","cr2","cr3","crw","nef","nrw","orf","raf","rw2","raw","pef","srw","erf","3fr","fff","iiq","mos","mrw","x3f","gpr","jpg","jpeg","heic","heif","png","tif","tiff","webp"]

func captureDate(exif: [String: Any], tiff: [String: Any]) -> (Date?, String) {
    let stamp = (exif[kCGImagePropertyExifDateTimeOriginal as String] as? String)
        ?? (exif[kCGImagePropertyExifDateTimeDigitized as String] as? String)
        ?? (tiff[kCGImagePropertyTIFFDateTime as String] as? String)
    guard let stamp else { return (nil, "none") }
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy:MM:dd HH:mm:ss"
    guard let date = f.date(from: stamp) else { return (nil, "unparsed:\(stamp)") }
    let sub = (exif[kCGImagePropertyExifSubsecTimeOriginal as String] as? String) ?? (exif[kCGImagePropertyExifSubsecTimeDigitized as String] as? String)
    var src = "exif"
    if let d = sub?.trimmingCharacters(in: .whitespaces), !d.isEmpty, d.allSatisfy(\.isNumber), let fr = Double("0.\(d)") {
        return (date.addingTimeInterval(fr), src + "+sub")
    }
    if exif[kCGImagePropertyExifDateTimeOriginal as String] == nil { src = exif[kCGImagePropertyExifDateTimeDigitized as String] != nil ? "digitized" : "tiff" }
    return (date, src)
}

let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])) ?? [])
    .filter { stillExts.contains($0.pathExtension.lowercased()) }
    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
print("name,capturedAt,epoch,dateSource,shutter,iso,aperture,focal,make,model,software,w,h,bytes,mtime")
for url in files {
    var line = [url.lastPathComponent]
    let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]))
    var cap: Date? = nil; var src = "none"
    var shutter = "", isoV = "", ap = "", focal = "", make = "", model = "", software = "", w = "", h = ""
    if let s = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
       let p = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any] {
        let exif = p[kCGImagePropertyExifDictionary] as? [String: Any] ?? [:]
        let tiff = p[kCGImagePropertyTIFFDictionary] as? [String: Any] ?? [:]
        (cap, src) = captureDate(exif: exif, tiff: tiff)
        func n(_ d: [String: Any], _ k: CFString) -> String { if let v = d[k as String] as? NSNumber { return "\(v.doubleValue)" }; return "" }
        func t(_ d: [String: Any], _ k: CFString) -> String { ((d[k as String] as? String) ?? "").replacingOccurrences(of: ",", with: " ") }
        shutter = n(exif, kCGImagePropertyExifExposureTime); isoV = ((exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first).map { "\($0)" } ?? ""
        ap = n(exif, kCGImagePropertyExifFNumber); focal = n(exif, kCGImagePropertyExifFocalLength)
        make = t(tiff, kCGImagePropertyTIFFMake); model = t(tiff, kCGImagePropertyTIFFModel); software = t(tiff, kCGImagePropertyTIFFSoftware)
        w = (p[kCGImagePropertyPixelWidth] as? NSNumber).map { "\($0)" } ?? ""; h = (p[kCGImagePropertyPixelHeight] as? NSNumber).map { "\($0)" } ?? ""
    }
    line.append(cap.map { iso.string(from: $0) } ?? "")
    line.append(cap.map { String(format: "%.3f", $0.timeIntervalSince1970) } ?? "")
    line.append(src)
    line += [shutter, isoV, ap, focal, make, model, software, w, h, "\(bytes?.fileSize ?? 0)", bytes?.contentModificationDate.map { String(format: "%.3f", $0.timeIntervalSince1970) } ?? ""]
    print(line.joined(separator: ","))
}
