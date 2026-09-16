#if DEBUG && os(macOS)
import AppKit

/// A synthetic mouse drag for the launch hooks (`LL_DRAG`), built in-process
/// and handed straight to the view under the point — never posted to the
/// HID stream, so nothing else on the Mac sees it: no cursor moves, no other
/// app's window can catch it. It exists because the gestures over the
/// picture (drawing a mask or a shape, a crop handle) are the one thing a
/// screenshot run cannot otherwise perform, and real input cannot be posted
/// on a Mac somebody is working at.
///
/// The events go to the hit view's responder methods rather than through
/// `NSWindow.sendEvent`: a titled window that is not key — every window of
/// a copy launched beside somebody's own — swallows a sent mouse-down to
/// become key with, and never does while the app is inactive (measured
/// 2026-09-13); the responder path is the one AppKit takes after that dance
/// and works without it.
@MainActor enum DebugDrag {
    /// `from`/`to` are window points measured from the window frame's
    /// top-left — the frame a `screencapture -l <windowID>` shows, at 1× —
    /// so a point read off that capture drives the drag directly.
    static func perform(from start: CGPoint, to end: CGPoint, steps: Int = 24,
                        interval: TimeInterval = 1.0 / 60) {
        guard let window = NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible),
              let root = window.contentView else {
            LLog("LL_DRAG: no window to drag in")
            return
        }
        // AppKit's window base is bottom-left, frame-relative.
        func location(_ p: CGPoint) -> NSPoint { NSPoint(x: p.x, y: window.frame.height - p.y) }
        func event(_ type: NSEvent.EventType, at p: CGPoint) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: location(p), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
        }
        guard let down = event(.leftMouseDown, at: start) else { return }
        // `hitTest` takes its point in the superview's space; the content
        // view's superview is the window's frame view.
        let hit = (root.superview.map { root.hitTest($0.convert(down.locationInWindow, from: nil)) } ?? nil) ?? root
        LLog("LL_DRAG: \(Int(start.x)),\(Int(start.y)) → \(Int(end.x)),\(Int(end.y)) in window \(window.windowNumber) (\(Int(window.frame.width))×\(Int(window.frame.height))), hit \(type(of: hit))")
        hit.mouseDown(with: down)
        let count = max(steps, 1)
        for i in 1...count {
            let t = Double(i) / Double(count)
            let p = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            DispatchQueue.main.asyncAfter(deadline: .now() + interval * Double(i)) {
                if let move = event(.leftMouseDragged, at: p) { hit.mouseDragged(with: move) }
                if i == count, let up = event(.leftMouseUp, at: p) {
                    hit.mouseUp(with: up)
                    LLog("LL_DRAG: released")
                }
            }
        }
    }
}

/// A synthetic key press for the launch hooks (`LL_KEY`), the keyboard twin
/// of `DebugDrag`: built in-process and sent through `NSApp.sendEvent` to the
/// main window — the path a real key takes after the HID layer, so the local
/// monitors (the Gallery's keys) and the key equivalents see it — and never
/// posted to the HID stream, so no other app on the Mac can catch it.
@MainActor enum DebugKey {
    /// `spec` is `[cmd+][shift+][alt+][ctrl+]<key>` — `z`, `escape`, `return`,
    /// `left`/`right`/`up`/`down`, or any single character.
    static func press(_ spec: String) {
        guard let window = NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible) else {
            LLog("LL_KEY: no window to key into")
            return
        }
        var flags: NSEvent.ModifierFlags = []
        var key = ""
        for part in spec.lowercased().split(separator: "+").map(String.init) {
            switch part {
            case "cmd", "command": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "alt", "option": flags.insert(.option)
            case "ctrl", "control": flags.insert(.control)
            default: key = part
            }
        }
        let codes: [String: (UInt16, String)] = [
            "escape": (53, "\u{1B}"), "return": (36, "\r"), "left": (123, "\u{F702}"),
            "right": (124, "\u{F703}"), "up": (126, "\u{F700}"), "down": (125, "\u{F701}"),
            "a": (0, "a"), "d": (2, "d"), "z": (6, "z"),
        ]
        let (code, characters) = codes[key] ?? (0, key)
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code)
        }
        guard let down = event(.keyDown), let up = event(.keyUp) else { return }
        LLog("LL_KEY: \(spec) → window \(window.windowNumber)")
        NSApp.sendEvent(down)
        NSApp.sendEvent(up)
    }
}
#endif
