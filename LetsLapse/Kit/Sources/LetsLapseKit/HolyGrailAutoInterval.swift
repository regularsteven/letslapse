import Foundation

/// How wide to space the frames of a **holy-grail shoot whose EVERY dial is on
/// Auto** — the spacing the ramp chooses for itself.
///
/// A pure function of the exposure the ramp has arrived at, so the policy can
/// be reasoned about and tested without a camera, exactly like
/// `HolyGrailRampEngine` itself.
///
/// **Why the interval moves at all.** It is *not* about fitting the shutter in:
/// the hardware ceiling is 1.0 s on current iPhones (see
/// `HolyGrailRampEngine.HardwareLimits.maxShutter`), so even the floor below
/// clears the longest exposure the sensor can take with seconds to spare. It is
/// about the back half of a day-to-night run. Once the shutter has pinned at
/// its ceiling and ISO is carrying the ramp, three things are true at once:
/// nothing in the frame is moving fast enough to need dense sampling any more,
/// every frame costs more heat and battery than the last (a high-ISO capture
/// does real work in the ISP), and the shoot has hours still to run. Widening
/// the spacing as the light dies spends the remaining budget where it buys
/// something.
///
/// **The two numbers.** The floor is 3 s and the cap is 15 s. The floor is
/// where a holy-grail shoot opens in daylight — tighter than that and a
/// 1-second-shutter frame has no settle room left, and the ramp's own
/// per-window latch (~0.3 s) starts eating into the exposure. The cap is 15 s
/// because past that a timelapse stops reading as continuous motion: at 30 fps
/// output, 15 s of scene time per frame is already 450× and clouds jump rather
/// than flow.
public enum HolyGrailAutoInterval {

    /// The tightest Auto spacing, in seconds — daylight, shutter with room.
    public static let floorSeconds: Double = 3
    /// The widest Auto spacing, in seconds — deep into the ISO climb.
    public static let capSeconds: Double = 15
    /// How many stops of ISO gain map to the full floor→cap travel. Four stops
    /// is roughly base ISO to ISO 800–1000 on an iPhone wide camera, which is
    /// about where a civil-twilight run has stopped changing quickly.
    public static let stopsToCap: Double = 4

    /// The spacing for an exposure the ramp has arrived at.
    ///
    /// While the shutter still has room the answer is the floor: the shutter is
    /// absorbing the light change on its own and the scene is still moving at
    /// daytime speeds. Once the shutter pins, the ISO gain over the floor ISO —
    /// measured in stops, because that is how the ramp itself thinks — walks
    /// the interval up to the cap.
    ///
    /// Rounded to whole seconds so the number the HUD prints is the number the
    /// timer uses, and so a run's spacing changes in visible steps rather than
    /// drifting by fractions no one asked for.
    public static func seconds(
        shutterSeconds: Double,
        iso: Float,
        limits: HolyGrailRampEngine.HardwareLimits
    ) -> Double {
        let ceiling = max(limits.maxShutter.seconds, 1e-6)
        // "Pinned" with the same 1% tolerance `isISORamping` uses, so the two
        // readouts can never disagree about which half of the run this is.
        guard shutterSeconds >= ceiling * 0.99 else { return floorSeconds }
        let baseISO = Double(max(limits.minISO, 1))
        let stops = log2(max(Double(iso), baseISO) / baseISO)
        let travel = min(max(stops / stopsToCap, 0), 1)
        return (floorSeconds + (capSeconds - floorSeconds) * travel).rounded()
    }

    /// The same answer straight off a ramp engine — the form the capture code
    /// calls, kept here so the clamping lives in one place.
    public static func seconds(
        for engine: HolyGrailRampEngine,
        limits: HolyGrailRampEngine.HardwareLimits
    ) -> Double {
        seconds(
            shutterSeconds: engine.currentTarget.shutterSeconds,
            iso: engine.currentTarget.iso,
            limits: limits)
    }

    /// Whether a spacing change is worth acting on. Re-anchoring the window
    /// clock costs a frame's worth of jitter, so a run only re-paces when the
    /// answer has moved by a whole second or more.
    public static func isMeaningfulChange(from current: Double, to next: Double) -> Bool {
        abs(next - current) >= 1
    }
}
