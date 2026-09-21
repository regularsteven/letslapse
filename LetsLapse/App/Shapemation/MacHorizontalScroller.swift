#if os(macOS)
import SwiftUI
import AppKit

/// A horizontal strip with a scroll bar that is always there and a mouse
/// wheel that scrolls it: SwiftUI's `ScrollView(.horizontal)` hides its
/// indicator until a drag and answers a plain wheel with nothing (the wheel
/// is vertical; only a trackpad's two fingers go sideways) — Steven,
/// 2026-09-21, on the Sequence board's strip. An `NSScrollView` with a
/// legacy horizontal scroller hosts the SwiftUI content; a wheel turned over
/// it moves the strip along.
struct MacHorizontalScroller<Content: View>: NSViewRepresentable {
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> WheelToHorizontalScrollView {
        let scrollView = WheelToHorizontalScrollView()
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.scrollerStyle = .legacy
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.drawsBackground = false
        scrollView.scrollerKnobStyle = .light
        let host = NSHostingView(rootView: content())
        host.translatesAutoresizingMaskIntoConstraints = true
        scrollView.documentView = host
        return scrollView
    }

    func updateNSView(_ scrollView: WheelToHorizontalScrollView, context: Context) {
        guard let host = scrollView.documentView as? NSHostingView<Content> else { return }
        host.rootView = content()
        let fitting = host.fittingSize
        let clip = scrollView.contentView.bounds.size
        host.frame = CGRect(x: 0, y: 0, width: max(fitting.width, clip.width), height: max(clip.height, 1))
    }
}

/// An `NSScrollView` whose vertical wheel scrolls sideways when the content
/// only goes sideways; trackpad gestures pass through untouched.
final class WheelToHorizontalScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        let isWheel = event.phase == [] && event.momentumPhase == []
        guard isWheel, abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX), let document = documentView else {
            super.scrollWheel(with: event)
            return
        }
        let step = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12
        var origin = contentView.bounds.origin
        let maxX = max(0, document.frame.width - contentView.bounds.width)
        origin.x = min(max(0, origin.x - step), maxX)
        contentView.scroll(to: origin)
        reflectScrolledClipView(contentView)
    }

    override func layout() {
        super.layout()
        // The hosted strip is as tall as the clip, whatever the window did.
        if let host = documentView {
            let clip = contentView.bounds.size
            if host.frame.height != clip.height || host.frame.width < clip.width {
                host.frame = CGRect(x: 0, y: 0, width: max(host.fittingSize.width, clip.width), height: max(clip.height, 1))
            }
        }
    }
}
#endif
