// Accessibility lookup by PID for driver.py — prints the screen frame of the
// first element of a role whose title or value matches, inside one window:
//   xcrun swift ax.swift <pid> <windowTitleSubstring> <AXRole> <text>
// → "x,y,w,h" (or nothing, exit 1)
//
// Why by pid: System Events' `process whose unix id is <pid>` resolves to the
// WRONG process when two share a name — Steven's own copy of the app and a
// driver-launched one (measured again 2026-09-04; it walked his "AI Models"
// window instead of the editor). AXUIElementCreateApplication takes the pid
// itself. This runs from the same shell that posts HID events, which is the
// process macOS holds responsible for accessibility, so it is trusted the
// same way hid.swift is.

import AppKit
import ApplicationServices
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
// `frontpid` prints the pid of the app that owns keyboard focus right now —
// the guard a keystroke-driven smoke checks before and after typing, so a
// burst can never land in someone's other window.
// `activate <pid>` brings that app to the front — a System Events click on
// an inactive window's title bar did not (the click reached buttons, which
// accept first mouse, while the app stayed in the background).
if args.first == "activate", args.count == 2, let pid = Int32(args[1]) {
    guard let app = NSRunningApplication(processIdentifier: pid) else { print("ax: no app with pid \(pid)"); exit(1) }
    let ok = app.activate(options: [.activateIgnoringOtherApps])
    usleep(300_000)
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
    print(ok && front == pid ? "activated" : "ax: activate returned \(ok), frontmost is \(front)")
    exit(ok && front == pid ? 0 : 1)
}
if args.first == "frontpid" {
    // NSWorkspace, not the system-wide AX focused-application attribute:
    // that one needs full accessibility trust (-25204 here), this does not.
    guard let app = NSWorkspace.shared.frontmostApplication else { print("ax: no frontmost application"); exit(1) }
    print(app.processIdentifier)
    exit(0)
}
// `move <pid> <titlePart> <x> <y>` puts a window's top-left at a screen
// point — onto the main display, where System Events clicks land; on a
// display at negative x they did not (2026-09-04).
let moving = args.first == "move"
// `focus <pid> <titlePart> <role> <text>` gives an element keyboard focus
// through accessibility — a System Events click on a SwiftUI text field
// activates its window but does not place a caret (measured 2026-09-04).
let focusing = args.first == "focus"
// `setvalue <pid> <titlePart> <role> <currentText> <newText>` replaces a
// text field's contents through accessibility — the same text-storage
// change the keyboard makes, with none of the keystrokes, so nothing can
// land in another app's window.
let setting = args.first == "setvalue"
// `type <pid> <titlePart> <role> <currentText> <newText>` selects the whole
// text and replaces the SELECTION — the text view's own insertion path, the
// one a keystroke takes — where `setvalue` swaps the storage wholesale and
// never trips what typing trips.
let typing = args.first == "type"
let positional = (moving || focusing || setting || typing) ? Array(args.dropFirst()) : args
guard positional.count == ((setting || typing) ? 5 : 4), let pid = Int32(positional[0]) else {
    print("usage: ax.swift <pid> <windowTitleSubstring> <AXRole> <text>  |  ax.swift move <pid> <windowTitleSubstring> <x> <y>"); exit(2)
}
let (titlePart, role, text) = (positional[1], positional[2], positional[3])

func attr(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
func string(_ element: AXUIElement, _ name: String) -> String? {
    guard let v = attr(element, name) else { return nil }
    if let s = v as? String { return s }
    if let n = v as? NSNumber { return n.stringValue }
    return nil
}
func children(_ element: AXUIElement) -> [AXUIElement] {
    (attr(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}
func frame(_ element: AXUIElement) -> CGRect? {
    guard let p = attr(element, kAXPositionAttribute), let s = attr(element, kAXSizeAttribute) else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &point)
    AXValueGetValue(s as! AXValue, .cgSize, &size)
    return CGRect(origin: point, size: size)
}

let app = AXUIElementCreateApplication(pid)
guard let windows = attr(app, kAXWindowsAttribute) as? [AXUIElement] else {
    print("ax: no windows for pid \(pid) — accessibility refused, or no such process"); exit(1)
}
guard let window = windows.first(where: { (string($0, kAXTitleAttribute) ?? "").contains(titlePart) }) else {
    let names = windows.map { string($0, kAXTitleAttribute) ?? "?" }
    print("ax: no window titled *\(titlePart)* — windows: \(names)"); exit(1)
}

if moving {
    guard let x = Double(role), let y = Double(text) else { print("move: need x y"); exit(2) }
    var point = CGPoint(x: x, y: y)
    guard let value = AXValueCreate(.cgPoint, &point) else { exit(1) }
    let result = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
    if result == .success, let f = frame(window) {
        print("\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width)),\(Int(f.height))")
        exit(0)
    }
    print("ax: move failed (\(result.rawValue))"); exit(1)
}

var visited = 0
func search(_ element: AXUIElement, depth: Int) -> AXUIElement? {
    visited += 1
    if depth > 60 || visited > 20000 { return nil }
    if string(element, kAXRoleAttribute) == role {
        let title = string(element, kAXTitleAttribute) ?? ""
        let value = string(element, kAXValueAttribute) ?? ""
        let described = string(element, kAXDescriptionAttribute) ?? ""
        if title == text || value == text || described == text { return element }
    }
    for child in children(element) {
        if let hit = search(child, depth: depth + 1) { return hit }
    }
    return nil
}

if role == "dump" {
    // Debug: every element with a title/value, one per line, so a role can
    // be read off before it is asked for.
    func dump(_ element: AXUIElement, depth: Int) {
        if depth > 40 { return }
        let r = string(element, kAXRoleAttribute) ?? "?"
        let t = string(element, kAXTitleAttribute) ?? ""
        let v = string(element, kAXValueAttribute) ?? ""
        let d = string(element, kAXDescriptionAttribute) ?? ""
        if !t.isEmpty || !v.isEmpty || !d.isEmpty {
            print("\(String(repeating: " ", count: depth))\(r) title=\(t.prefix(40)) value=\(v.prefix(40)) desc=\(d.prefix(40))")
        }
        for child in children(element) { dump(child, depth: depth + 1) }
    }
    dump(window, depth: 0)
    exit(0)
}

if typing {
    guard let hit = search(window, depth: 0) else {
        print("ax: \(role) \(text) not found (\(visited) elements walked)"); exit(1)
    }
    AXUIElementSetAttributeValue(hit, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    usleep(150_000)
    let current = string(hit, kAXValueAttribute) ?? ""
    var whole = CFRange(location: 0, length: (current as NSString).length)
    if let rangeValue = AXValueCreate(.cfRange, &whole) {
        AXUIElementSetAttributeValue(hit, kAXSelectedTextRangeAttribute as CFString, rangeValue)
    }
    usleep(100_000)
    let result = AXUIElementSetAttributeValue(hit, kAXSelectedTextAttribute as CFString, positional[4] as CFString)
    if result == .success {
        print("typed")
        exit(0)
    }
    print("ax: type failed (\(result.rawValue))"); exit(1)
}

if setting {
    guard let hit = search(window, depth: 0) else {
        print("ax: \(role) \(text) not found (\(visited) elements walked)"); exit(1)
    }
    let result = AXUIElementSetAttributeValue(hit, kAXValueAttribute as CFString, positional[4] as CFString)
    if result == .success {
        print("set")
        exit(0)
    }
    print("ax: setvalue failed (\(result.rawValue))"); exit(1)
}

if focusing {
    guard let hit = search(window, depth: 0) else {
        print("ax: \(role) \(text) not found (\(visited) elements walked)"); exit(1)
    }
    let result = AXUIElementSetAttributeValue(hit, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    if result == .success, let f = frame(hit) {
        print("\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width)),\(Int(f.height))")
        exit(0)
    }
    print("ax: focus failed (\(result.rawValue))"); exit(1)
}

if let hit = search(window, depth: 0), let f = frame(hit) {
    print("\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width)),\(Int(f.height))")
} else {
    print("ax: \(role) \(text) not found in that window (\(visited) elements walked)"); exit(1)
}
