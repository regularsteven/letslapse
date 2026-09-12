// Real HID input for driver.py — mouse clicks, drags and typed text posted
// as CGEvents at the HID tap, which is what SwiftUI text fields and drag
// gestures actually respond to.
//
// Why this exists: System Events' `click at` reaches buttons and rows, but
// it does not give a SwiftUI TextField keyboard focus when a sibling window
// of the same app is key, and it cannot drive a DragGesture at all (both
// measured, 2026-09-03/04). AppleScript `keystroke` needs the target app to
// be frontmost; a CGEvent goes wherever the key window is, which after a
// real click is the field that was clicked.
//
// Usage:
//   xcrun swift hid.swift click <x> <y> [<x> <y> …]      screen points, 250 ms apart
//   xcrun swift hid.swift dblclick <x> <y>
//   xcrun swift hid.swift scroll <x> <y> <lines>          wheel ticks at a point, + = down
//   xcrun swift hid.swift drag <x1> <y1> <x2> <y2>       30 steps, ~16 ms apart
//   xcrun swift hid.swift type <text…>                   unicode, one event per char
//   xcrun swift hid.swift key <name> [cmd] [shift] [opt] a|return|delete|left|right|escape

import CoreGraphics
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
guard let verb = args.first else {
    print("usage: hid.swift click|dblclick|drag|type|key …"); exit(2)
}
let source = CGEventSource(stateID: .hidSystemState)

func post(_ event: CGEvent?) { event?.post(tap: .cghidEventTap) }

func mouse(_ type: CGEventType, at p: CGPoint, clicks: Int64 = 1) {
    let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
    event?.setIntegerValueField(.mouseEventClickState, value: clicks)
    post(event)
}

func click(_ p: CGPoint, count: Int64 = 1) {
    mouse(.mouseMoved, at: p)
    usleep(80_000)
    for n in 1...count {
        mouse(.leftMouseDown, at: p, clicks: n)
        usleep(50_000)
        mouse(.leftMouseUp, at: p, clicks: n)
        usleep(n < count ? 90_000 : 0)
    }
}

func points(_ values: ArraySlice<String>) -> [CGPoint] {
    let numbers = values.compactMap(Double.init)
    return stride(from: 0, to: numbers.count - 1, by: 2).map { CGPoint(x: numbers[$0], y: numbers[$0 + 1]) }
}

switch verb {
case "click":
    let targets = points(args.dropFirst())
    guard !targets.isEmpty else { print("click: need x y"); exit(2) }
    for (i, p) in targets.enumerated() {
        click(p)
        if i < targets.count - 1 { usleep(250_000) }
    }
    print("clicked \(targets.count) point(s)")
case "dblclick":
    guard let p = points(args.dropFirst()).first else { print("dblclick: need x y"); exit(2) }
    click(p, count: 2)
    print("double-clicked")
case "scroll":
    // scroll <x> <y> <lines>: wheel ticks at a screen point, positive = down,
    // one event per line so a SwiftUI ScrollView takes them as a real wheel.
    let numbers = args.dropFirst().compactMap(Double.init)
    guard numbers.count == 3 else { print("scroll: need x y lines"); exit(2) }
    let p = CGPoint(x: numbers[0], y: numbers[1])
    let lines = Int(numbers[2])
    mouse(.mouseMoved, at: p)
    usleep(80_000)
    for _ in 0..<abs(lines) {
        let event = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 1,
                            wheel1: Int32(lines < 0 ? 3 : -3), wheel2: 0, wheel3: 0)
        event?.location = p
        post(event)
        usleep(20_000)
    }
    print("scrolled \(lines) line(s)")
case "drag":
    let pts = points(args.dropFirst())
    guard pts.count == 2 else { print("drag: need x1 y1 x2 y2"); exit(2) }
    let (from, to) = (pts[0], pts[1])
    mouse(.mouseMoved, at: from)
    usleep(120_000)
    mouse(.leftMouseDown, at: from)
    usleep(80_000)
    for i in 1...30 {
        let t = Double(i) / 30
        mouse(.leftMouseDragged, at: CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
        usleep(16_000)
    }
    usleep(80_000)
    mouse(.leftMouseUp, at: to)
    print("dragged")
case "type":
    let text = args.dropFirst().joined(separator: " ")
    for scalar in text.unicodeScalars {
        var chars = Array(String(scalar).utf16)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        down?.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
        post(down)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        up?.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
        post(up)
        usleep(12_000)
    }
    print("typed \(text.count) character(s)")
case "key":
    let names: [String: CGKeyCode] = [
        "a": 0, "return": 36, "delete": 51, "escape": 53, "left": 123, "right": 124,
        "down": 125, "up": 126, "tab": 48, "space": 49,
    ]
    guard args.count >= 2, let code = names[args[1]] else {
        print("key: need one of \(names.keys.sorted().joined(separator: "|"))"); exit(2)
    }
    var flags: CGEventFlags = []
    for modifier in args.dropFirst(2) {
        switch modifier {
        case "cmd": flags.insert(.maskCommand)
        case "shift": flags.insert(.maskShift)
        case "opt", "option": flags.insert(.maskAlternate)
        case "ctrl": flags.insert(.maskControl)
        default: break
        }
    }
    let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
    down?.flags = flags
    post(down)
    usleep(40_000)
    let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
    up?.flags = flags
    post(up)
    print("key \(args[1]) \(args.dropFirst(2).joined(separator: "+"))")
default:
    print("hid.swift: unknown verb \(verb)"); exit(2)
}
