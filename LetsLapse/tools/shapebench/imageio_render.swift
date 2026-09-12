// The rig's DNG renderer: ImageIO's thumbnail with the orientation applied,
// at the file's full size — the same raw engine the `lapse` CLI decodes with,
// and what the app's CIRAWFilter path was measured to match on macOS
// (App/ProjectMedia.swift). rawpy's render is darker and more contrasted,
// and the P-sign DNG lost both its squares to that difference (2026-09-12).
// Built on demand by imaging.py: swiftc -O imageio_render.swift -o work/imageio_render
import ImageIO
import CoreGraphics
import Foundation
import UniformTypeIdentifiers
let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, nil)!
let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: Int(CommandLine.arguments[3]) ?? 8192]
let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[2]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
print(img.width, img.height, img.bitsPerComponent, img.colorSpace?.name ?? "?" as CFString)
