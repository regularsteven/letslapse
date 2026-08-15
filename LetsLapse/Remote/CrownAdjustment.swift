#if os(watchOS) || os(macOS)
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The Digital Crown, and what stands in for it on a Mac.
///
/// The two crown sites — ISO/lens position while recording, and the Stop At
/// dial — are both *no-look* controls: on the wrist you turn them while
/// watching the frame, not the readout. The closest Mac analogue is the scroll
/// wheel / two-finger trackpad scroll, which is continuous, needs no pointer
/// precision, and leaves the eyes on the content.
///
/// **This substitution teaches us nothing about the wrist version.** A scroll
/// wheel has no detent count that maps to a crown, so any feel tuning done
/// here — how far the value moves per notch — is not transferable and must
/// still be judged on a real Watch. It exists so the Mac mirror is *operable*,
/// not so the Mac becomes where crown feel is decided.
extension View {
    func crownAdjustable(
        _ value: Binding<Double>,
        from lowerBound: Double,
        through upperBound: Double,
        by step: Double,
        isEnabled: Bool = true,
        focus: FocusState<Bool>.Binding? = nil
    ) -> some View {
        modifier(CrownAdjustment(
            value: value,
            lowerBound: lowerBound,
            upperBound: upperBound,
            step: step,
            isEnabled: isEnabled,
            focus: focus))
    }
}

private struct CrownAdjustment: ViewModifier {
    @Binding var value: Double
    let lowerBound: Double
    let upperBound: Double
    let step: Double
    let isEnabled: Bool
    /// watchOS leaves first focus to chance when several focusable views are
    /// mounted (or none was, and one appears). A site that must own the crown
    /// the moment it appears — the lock screen — passes a binding and asserts
    /// it; everyone else leaves this nil and keeps today's behaviour.
    var focus: FocusState<Bool>.Binding?

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(watchOS)
        if let focus {
            content
                .focusable(isEnabled)
                .focused(focus)
                .digitalCrownRotation(
                    $value,
                    from: lowerBound,
                    through: upperBound,
                    by: step,
                    sensitivity: .medium)
        } else {
            content
                .focusable(isEnabled)
                .digitalCrownRotation(
                    $value,
                    from: lowerBound,
                    through: upperBound,
                    by: step,
                    sensitivity: .medium)
        }
        #else
        // Focus is a crown concept; the Mac's scroll arbiter below already
        // picks one owner, so the binding is accepted and ignored here.
        content.modifier(ScrollWheelAdjustment(
            value: $value,
            lowerBound: lowerBound,
            upperBound: upperBound,
            step: step,
            isEnabled: isEnabled))
        #endif
    }
}

#if os(macOS)
/// Decides which adjuster owns the scroll wheel when more than one is alive.
///
/// The recording screen's ISO dial stays mounted behind the Stop At sheet, so
/// without an arbiter one scroll would move both. Most recently appeared wins,
/// which is what "the thing in front of you" means in every case here.
@MainActor
private final class CrownArbiter {
    static let shared = CrownArbiter()
    private var nextToken = 0
    private(set) var activeToken = 0

    func claim() -> Int {
        nextToken += 1
        activeToken = nextToken
        return nextToken
    }

    func resign(_ token: Int) {
        // Only the current owner hands back; a stale one disappearing must not
        // steal ownership from whatever took over.
        guard token == activeToken else { return }
        activeToken = 0
    }
}

/// Scroll-wheel binding via a local event monitor.
///
/// Deliberately NOT an `NSViewRepresentable` overlay: scroll events are routed
/// by hit testing, so a transparent catcher must either swallow clicks meant
/// for the buttons underneath or never receive the wheel at all. A monitor
/// sidesteps hit testing entirely, and one crown site sits on a `ScrollView`
/// where a `DragGesture` would fight scrolling.
private struct ScrollWheelAdjustment: ViewModifier {
    @Binding var value: Double
    let lowerBound: Double
    let upperBound: Double
    let step: Double
    let isEnabled: Bool

    @State private var monitor: Any?
    @State private var token = 0

    func body(content: Content) -> some View {
        content
            .onAppear { install() }
            .onDisappear { remove() }
            .onChange(of: isEnabled) { _ in
                remove()
                install()
            }
    }

    private func install() {
        guard isEnabled, monitor == nil else { return }
        token = CrownArbiter.shared.claim()
        let owned = token
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard CrownArbiter.shared.activeToken == owned else { return event }
            // Trackpads report fine-grained deltas, a wheel reports whole
            // lines — normalise so one notch is about one step either way.
            let delta = event.hasPreciseScrollingDeltas
                ? event.scrollingDeltaY / 10
                : event.scrollingDeltaY
            guard delta != 0 else { return event }
            let next = value + Double(delta) * step
            value = min(max(next, lowerBound), upperBound)
            // Consumed: the window must not also scroll its content.
            return nil
        }
    }

    private func remove() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        CrownArbiter.shared.resign(token)
        token = 0
    }
}
#endif
#endif
