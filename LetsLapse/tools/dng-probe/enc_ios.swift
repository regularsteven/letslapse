import Foundation
import ImageIO
let dst = CGImageDestinationCopyTypeIdentifiers() as! [String]
let src = CGImageSourceCopyTypeIdentifiers() as! [String]
print("ENCODE:", dst.filter { $0.contains("jxl") || $0.contains("jpeg-xl") || $0.contains("heic") || $0.contains("jpeg") || $0.contains("dng") || $0.contains("raw") })
print("DECODE jxl:", src.filter { $0.contains("jpeg-xl") || $0.contains("jxl") })
print("total encoders:", dst.count)
