import SwiftUI
import LetsLapseKit
#if os(iOS)
import UIKit
#endif

/// What the display should do while a shoot runs — Settings ▸ Display, as one
/// value, so the capture screen hands over its whole intent in a single call
/// rather than through four setters that can disagree with each other.
struct ShootDisplayPlan: Equatable {
    /// A dimmable run is going (interval, blend, video — never Photo).
    var runActive = false
    /// "Blackout viewfinder": the cover, and the brightness floor under it.
    var blackout = false
    /// "Reduce brightness": the panel level for the WHOLE run, cover or no
    /// cover. Also the level a lifted curtain returns to.
    var reduceBrightness = false
    var peekEnabled = false
    var trigger: ShootPeekTrigger = .clock
    var everyMinutes = ShootPeekSchedule.defaultEveryMinutes
    /// Anchors an `.interval` schedule; nil while nothing is running.
    var runStartedAt: Date?
}

/// Runs the display while a shoot runs.
///
/// The panel is one of the larger non-SoC power draws in the box, and on the
/// OLED phones its cost scales with content brightness — a daylight viewfinder
/// at auto-brightness is watts of pure heat on exactly the devices that die of
/// heat (the 12 Pro's `systemPressure` veto, 2026-08-25 bench). Dimming buys
/// real minutes of survival.
///
/// **Two levers, and they are not the same lever on every device.** On the
/// OLED iPhones nearly all the saving is the *cover*: black pixels are off, so
/// once the panel is covered the lit pixels are the entire bill and the
/// brightness slider is almost free. On the LCD iPads it is the reverse — the
/// backlight burns whatever is drawn, so brightness is the only lever there
/// and covering the preview saves almost nothing. Hence two independent
/// settings rather than one three-way picker, and hence `lowBrightness` is
/// **0.05 rather than 0**: `UIScreen.brightness` caps every pixel on the
/// display, so a floor of zero makes the heartbeat below unseeable while
/// saving, under a black cover, essentially nothing.
///
/// A tap on the cover hands the screen back for 30 s and then re-dims. A
/// **scheduled peek** does the same thing without a finger on a phone that is
/// on a tripod — which is how a shoot gets knocked out of frame — and shows a
/// status card rather than the viewfinder (`ShootPeekCard`): legible across a
/// room, and ~94 % black, so it costs the OLED almost nothing.
///
/// Settings ▸ Display ("Blackout viewfinder", on by default) also seeds the
/// run cluster's Dim toggle, and is flippable from the Watch and the Camera
/// remote mid-run, because it is display-only and a live flip is exactly the
/// thermal A/B the bench wants.
@MainActor
final class ShootScreenDimmer: ObservableObject {
    /// The defaults key the Settings row, the remote command and the capture
    /// screen all share. **Unchanged by the 2026-09-05 rename** — the row is
    /// called "Blackout viewfinder" now, but this key, the wire command
    /// (`setDimDuringShoot`), the state-frame key and `shoot.py --dim` are the
    /// same, so no bench script breaks.
    static let defaultsKey = "letslapse.capture.dimDuringShoot"
    static let reduceBrightnessKey = "letslapse.capture.reduceBrightness"
    static let peekEnabledKey = "letslapse.capture.peekEnabled"
    static let peekTriggerKey = "letslapse.capture.peekTrigger"
    static let peekEveryMinutesKey = "letslapse.capture.peekEveryMinutes"

    /// The lowest level worth writing — low enough to be invisible across a
    /// dark room, high enough that a walk-up can read the screen, and high
    /// enough that one lit pixel is still a pixel. `CaptureStandby` has used
    /// it since the scheduled-standby work.
    static let lowBrightness: CGFloat = 0.05

    /// The black cover is up.
    @Published private(set) var covering = false
    /// A scheduled peek is showing its card.
    @Published private(set) var peeking = false
    /// When the current peek puts the cover back. Drives the card's footer.
    @Published private(set) var peekEndsAt: Date?
    /// When the blackout next lifts by itself — the other half of the footer,
    /// and the line that means the operator never has to touch the phone.
    @Published private(set) var nextPeekAt: Date?

    #if os(iOS)
    private var plan = ShootDisplayPlan()
    /// The operator's own level, taken before the first write of a run. iOS
    /// restores nothing for us: a `UIScreen.brightness` write outlives the app.
    private var savedBrightness: CGFloat?
    private var rewakeTask: Task<Void, Never>?
    private var peekTask: Task<Void, Never>?
    private var peekHoldTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    /// When this dimmer first saw the run. `captureRunStartedAt` is written on
    /// the session queue and is not published, so the first plan of a run can
    /// arrive with it still nil — an `.interval` schedule anchored on nil
    /// would never fire at all.
    private var runBeganAt: Date?
    /// `LL_PEEK` froze a card for a screenshot; nothing may take it down.
    private var peekFrozen = false

    init() {
        // The thermal veto's own path — session interrupted, app backgrounded,
        // device locked — must hand the system brightness back, and a return
        // to foreground mid-run re-applies.
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil,
            queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.restoreBrightnessOnly() }
            })
        observers.append(nc.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil,
            queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reapplyAfterForeground() }
            })
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: - The one entry point

    /// Take the capture screen's whole intent. Idempotent, so it can be called
    /// from `onAppear` and from every `onChange` without guarding the call.
    func apply(_ next: ShootDisplayPlan) {
        guard next != plan else { return }
        let wasRunning = plan.runActive
        plan = next

        guard next.runActive else {
            if wasRunning { standDown() }
            return
        }
        if !wasRunning { runBeganAt = Date() }

        if next.blackout {
            // A peek in flight survives a plan change that did not touch it;
            // anything else puts the cover straight back up.
            if !peeking { floorNow() }
        } else {
            endPeekHold()
            peeking = false
            peekEndsAt = nil
            covering = false
            applyBaselineBrightness()
        }
        reschedulePeek()
    }

    /// A tap on the cover or the card: the operator gets the real screen back
    /// for 30 s (design 2026-09-04 — it was 8), then the run re-dims itself
    /// unless the cluster's Dim toggle is turned off inside that window.
    func wake(for seconds: Double = 30) {
        guard plan.runActive, plan.blackout, !peekFrozen else { return }
        endPeekHold()
        peeking = false
        peekEndsAt = nil
        covering = false
        applyBaselineBrightness()
        rewakeTask?.cancel()
        rewakeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.floorNow()
            self?.reschedulePeek()
        }
    }

    // MARK: - Peeks

    /// True while the schedule can fire: a peek only exists under a blackout,
    /// which is what the Settings disclosure group says.
    private var peekActive: Bool {
        plan.runActive && plan.blackout && plan.peekEnabled
    }

    private func reschedulePeek() {
        peekTask?.cancel()
        peekTask = nil
        guard peekActive, !peekFrozen,
              let startedAt = plan.runStartedAt ?? runBeganAt else {
            nextPeekAt = nil
            return
        }
        guard let next = ShootPeekSchedule.next(
            after: Date(), runStartedAt: startedAt,
            trigger: plan.trigger, everyMinutes: plan.everyMinutes) else {
            nextPeekAt = nil
            return
        }
        nextPeekAt = next
        peekTask = Task { [weak self] in
            let delay = next.timeIntervalSinceNow
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            self?.firePeek()
        }
    }

    private func firePeek() {
        // Nothing to lift if the operator already has the screen — take the
        // peek as spent and line the next one up.
        guard peekActive, covering else {
            reschedulePeek()
            return
        }
        rewakeTask?.cancel()
        rewakeTask = nil
        covering = false
        peeking = true
        applyBaselineBrightness()
        peekEndsAt = Date().addingTimeInterval(ShootPeekSchedule.peekSeconds)
        LLog("peek: card up for \(Int(ShootPeekSchedule.peekSeconds))s")
        peekHoldTask?.cancel()
        peekHoldTask = Task { [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(ShootPeekSchedule.peekSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.endPeek()
        }
    }

    private func endPeek() {
        peeking = false
        peekEndsAt = nil
        if plan.runActive, plan.blackout { floorNow() }
        reschedulePeek()
    }

    private func endPeekHold() {
        peekHoldTask?.cancel()
        peekHoldTask = nil
    }

    /// `LL_PEEK=card`: hold a card open for a screenshot. DEBUG only — the
    /// simulator has no camera to run a shoot the schedule could fire against.
    func freezePeekForDesign() {
        peekFrozen = true
        peekTask?.cancel(); peekTask = nil
        rewakeTask?.cancel(); rewakeTask = nil
        endPeekHold()
        covering = false
        peeking = true
        peekEndsAt = Date().addingTimeInterval(12)
        nextPeekAt = Date().addingTimeInterval(12 + 5 * 60)
    }

    // MARK: - Brightness

    private func floorNow() {
        captureSavedBrightness()
        UIScreen.main.brightness = Self.lowBrightness
        covering = true
    }

    /// Put the panel at the run's baseline: the operator's own level, or the
    /// reduced one when they asked for it. With neither lever pulled there is
    /// nothing to write — and writing anyway would clobber auto-brightness.
    private func applyBaselineBrightness() {
        if plan.reduceBrightness {
            captureSavedBrightness()
            UIScreen.main.brightness = Self.lowBrightness
        } else if let savedBrightness {
            UIScreen.main.brightness = savedBrightness
        }
    }

    private func captureSavedBrightness() {
        if savedBrightness == nil { savedBrightness = UIScreen.main.brightness }
    }

    private func restoreBrightnessOnly() {
        if let savedBrightness { UIScreen.main.brightness = savedBrightness }
    }

    private func reapplyAfterForeground() {
        guard plan.runActive else { return }
        if covering {
            floorNow()
        } else {
            applyBaselineBrightness()
        }
        // A schedule that slept through a suspension comes back with a stale
        // deadline; recompute against the wall clock rather than trust it.
        reschedulePeek()
    }

    /// The run is over, or the screen is leaving: hand everything back.
    private func standDown() {
        rewakeTask?.cancel(); rewakeTask = nil
        peekTask?.cancel(); peekTask = nil
        endPeekHold()
        peekFrozen = false
        runBeganAt = nil
        restoreBrightnessOnly()
        savedBrightness = nil
        covering = false
        peeking = false
        peekEndsAt = nil
        nextPeekAt = nil
    }
    #else
    // The Mac has no UIScreen and no thermal veto; the rows and the wire
    // command still exist so a fleet script is portable, they just do nothing.
    func apply(_ next: ShootDisplayPlan) {}
    func wake(for seconds: Double = 30) {}
    func freezePeekForDesign() {}
    #endif
}

/// The capture screen's whole display wiring as ONE modifier — CaptureView's
/// body already rides the edge of the type-checker's budget, and five chained
/// modifiers there was the straw (the compiler gave up in "reasonable time").
/// One opaque modifier costs what one modifier costs.
struct ShootDimming: ViewModifier {
    @ObservedObject var dimmer: ShootScreenDimmer
    /// Everything Settings ▸ Display asked for, as one value.
    let plan: ShootDisplayPlan
    /// Climbs once per banked frame; the heartbeat pulses on the change.
    let frameTick: Int
    /// What a scheduled peek shows. Rebuilt by the capture screen; only read
    /// while a card is up.
    let peek: ShootPeekReadout
    /// The Settings/remote/Watch-shared blackout flag, so flips republish.
    let blackoutSetting: Bool
    /// A card opening or closing. Lives here rather than in CaptureView's body,
    /// which is the whole reason this modifier exists.
    let onPeekChanged: (Bool) -> Void
    let syncRemote: (Bool) -> Void

    func body(content: Content) -> some View {
        content
            .overlay { ShootDimCover(dimmer: dimmer, frameTick: frameTick, peek: peek) }
            .onChange(of: plan) { dimmer.apply($0) }
            .onChange(of: dimmer.peeking) { onPeekChanged($0) }
            .onChange(of: blackoutSetting) { syncRemote($0) }
            .onAppear {
                dimmer.apply(plan)
                syncRemote(blackoutSetting)
            }
            .onDisappear { dimmer.apply(ShootDisplayPlan()) }
    }
}

/// The cover and the card, in the one overlay.
struct ShootDimCover: View {
    @ObservedObject var dimmer: ShootScreenDimmer
    let frameTick: Int
    let peek: ShootPeekReadout
    /// The heartbeat rests here and pulses to `pulsePeak` on each banked frame.
    private static let restOpacity = 0.12
    private static let pulsePeak = 0.55
    @State private var beat = ShootDimCover.restOpacity
    @State private var beatTask: Task<Void, Never>?

    var body: some View {
        if dimmer.peeking {
            ShootPeekCard(
                readout: peek, endsAt: dimmer.peekEndsAt, nextPeekAt: dimmer.nextPeekAt)
                .contentShape(Rectangle())
                .onTapGesture { dimmer.wake() }
                .transition(.opacity)
        } else if dimmer.covering {
            ZStack {
                Color.black
                // Amber, not the system's green: green means the camera is
                // powered, a pulse per banked frame means LetsLapse took a
                // picture. A resting glow because a dot dark for 59 of every
                // 60 s reads as dead, and a pulse rather than a hold because a
                // static lit pixel across a two-hour OLED shoot is burn-in.
                Circle()
                    .fill(LL.amber)
                    .frame(width: 6, height: 6)
                    .opacity(beat)
            }
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { dimmer.wake() }
            .onChange(of: frameTick) { _ in pulse() }
            .transition(.opacity)
        }
    }

    private func pulse() {
        beatTask?.cancel()
        withAnimation(.easeOut(duration: 0.08)) { beat = Self.pulsePeak }
        beatTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.35)) { beat = Self.restOpacity }
        }
    }
}
