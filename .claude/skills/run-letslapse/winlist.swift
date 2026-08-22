// Window enumeration for driver.py — prints one TSV row per on-screen window:
//   <windowID>\t<pid>\t<owner>\t<x>\t<y>\t<w>\t<h>\t<title>
//
// Why this exists: `screencapture -l <windowID>` grabs a window's own buffer
// and is immune to occlusion, but nothing on macOS hands you a CGWindowID from
// the shell. AppleScript/System Events can't (and its `whose unix id is <pid>`
// filter silently resolves to the WRONG process when two processes share a
// name — which is exactly the case here, because Steven's own copy of the Mac
// app is usually running while an agent drives a freshly built one).
//
// PyObjC is not installed on this Mac in any of the three python3s, so this is
// a Swift script rather than part of driver.py. `xcrun swift winlist.swift`
// compiles and runs in a couple of seconds.
//
// Usage:  xcrun swift winlist.swift [ownerSubstring] [pid]

import CoreGraphics
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
let ownerFilter = args.first { Int($0) == nil }
let pidFilter = args.compactMap { Int($0) }.first

let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
    FileHandle.standardError.write(Data("winlist: CGWindowListCopyWindowInfo returned nil\n".utf8))
    exit(1)
}

for window in windows {
    guard let id = window[kCGWindowNumber as String] as? Int,
          let pid = window[kCGWindowOwnerPID as String] as? Int,
          let owner = window[kCGWindowOwnerName as String] as? String,
          let bounds = window[kCGWindowBounds as String] as? [String: Any],
          let x = bounds["X"] as? Double, let y = bounds["Y"] as? Double,
          let w = bounds["Width"] as? Double, let h = bounds["Height"] as? Double
    else { continue }
    // Menu-bar items, notification chrome and other 1-pixel furniture.
    if w < 120 || h < 120 { continue }
    if let filter = ownerFilter, !owner.localizedCaseInsensitiveContains(filter) { continue }
    if let filter = pidFilter, pid != filter { continue }
    let title = (window[kCGWindowName as String] as? String) ?? ""
    print("\(id)\t\(pid)\t\(owner)\t\(Int(x))\t\(Int(y))\t\(Int(w))\t\(Int(h))\t\(title)")
}
