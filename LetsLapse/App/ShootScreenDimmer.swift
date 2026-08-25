import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Floors the display while a shoot runs.
///
/// The panel is one of the larger non-SoC power draws in the box, and on the
/// OLED phones its cost scales with content brightness — a daylight viewfinder
/// at auto-brightness is watts of pure heat on exactly the devices that die of
/// heat (the 12 Pro's `systemPressure` veto, 2026-08-25 bench). Dimming buys
/// real minutes of survival and costs nothing the operator can't get back
/// with a tap.
///
/// Two levers, pulled together: `UIScreen.brightness` to the floor (a
/// system-wide write, so every exit path restores the saved value), and a
/// black cover over the viewfinder so the OLED content itself goes near-dark
/// and the preview stops costing compositor work to look at. A tap on the
/// cover hands the screen back for a few seconds, then re-dims while the run
/// is still going.
///
/// Settings ▸ Advanced ▸ "Dim screen during shoot" (on by default); also
/// flippable from the Watch and the Camera remote — mid-run too, because it
/// is display-only and a live flip is exactly the thermal A/B the bench
/// wants.
@MainActor
final class ShootScreenDimmer: ObservableObject {
    /// The defaults key the Settings row, the remote command and the capture
    /// screen all share.
    static let defaultsKey = "letslapse.capture.dimDuringShoot"

    /// The black cover is up (and brightness is floored).
    @Published private(set) var covering = false

    #if os(iOS)
    private var engaged = false
    private var savedBrightness: CGFloat?
    private var rewakeTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    init() {
        // iOS restores nothing for us: a `UIScreen.brightness` write outlives
        // the app. The thermal veto's own path — session interrupted, app
        // backgrounded, device locked — must hand the system brightness back,
        // and a return to foreground mid-run re-dims.
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil,
            queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.restoreBrightnessOnly() }
            })
        observers.append(nc.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil,
            queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refloorIfEngaged() }
            })
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func setEngaged(_ engage: Bool) {
        guard engage != engaged else { return }
        engaged = engage
        rewakeTask?.cancel()
        rewakeTask = nil
        if engage { floorNow() } else { restore() }
    }

    /// A tap on the cover: the operator gets the screen back briefly, then
    /// the run re-dims itself.
    func wake(for seconds: Double = 8) {
        guard engaged else { return }
        restoreBrightnessOnly()
        covering = false
        rewakeTask?.cancel()
        rewakeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.refloorIfEngaged()
        }
    }

    private func floorNow() {
        if savedBrightness == nil { savedBrightness = UIScreen.main.brightness }
        UIScreen.main.brightness = 0
        covering = true
    }

    private func refloorIfEngaged() {
        guard engaged else { return }
        if savedBrightness == nil { savedBrightness = UIScreen.main.brightness }
        UIScreen.main.brightness = 0
        covering = true
    }

    private func restoreBrightnessOnly() {
        if let brightness = savedBrightness { UIScreen.main.brightness = brightness }
    }

    private func restore() {
        restoreBrightnessOnly()
        savedBrightness = nil
        covering = false
    }
    #else
    // The Mac has no UIScreen and no thermal veto; the rows and the wire
    // command still exist so a fleet script is portable, they just do nothing.
    func setEngaged(_ engage: Bool) {}
    func wake(for seconds: Double = 8) {}
    #endif
}

/// The capture screen's whole dim wiring as ONE modifier — CaptureView's
/// body already rides the edge of the type-checker's budget, and five chained
/// modifiers there was the straw (the compiler gave up in
/// "reasonable time"). One opaque modifier costs what one modifier costs.
struct ShootDimming: ViewModifier {
    @ObservedObject var dimmer: ShootScreenDimmer
    /// True while a dimmable run is going and the setting is on.
    let engage: Bool
    /// The Settings/remote/Watch-shared flag, so flips republish to remotes.
    let setting: Bool
    let syncRemote: (Bool) -> Void

    func body(content: Content) -> some View {
        content
            .overlay { ShootDimCover(dimmer: dimmer) }
            .onChange(of: engage) { dimmer.setEngaged($0) }
            .onChange(of: setting) { syncRemote($0) }
            .onAppear { syncRemote(setting) }
            .onDisappear { dimmer.setEngaged(false) }
    }
}

/// The cover itself: black, full-bleed, one barely-there pulse so a glance
/// still says "recording" without paying for pixels.
struct ShootDimCover: View {
    @ObservedObject var dimmer: ShootScreenDimmer

    var body: some View {
        if dimmer.covering {
            ZStack {
                Color.black
                Circle()
                    .fill(Color.red.opacity(0.30))
                    .frame(width: 5, height: 5)
            }
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { dimmer.wake() }
            .transition(.opacity)
        }
    }
}
