import Foundation

/// The capture screen's horizon level, as arithmetic: one gravity reading and
/// the way the interface is drawn in, turned into what the level shows — how
/// far the picture is off level, and where on the screen its reference and
/// its horizon lie.
///
/// **Two orientations, deliberately apart.** The *hold* is the quarter turn
/// the phone is physically nearest — what the capture is tagged with
/// (`effectiveCaptureOrientation(device:)`), so what "level" means for the
/// picture being taken. The *interface* is how the chrome is drawn, which
/// follows the hold only when the screen is free to rotate: under the system
/// rotation lock, and in the moment before the chrome catches up with a turn,
/// the two differ by a quarter turn. The first level measured against the
/// hold alone and drew in interface space, which is the same thing only when
/// they agree; this keeps them apart, so the reference stays on the picture's
/// horizontal axis whichever way the chrome is drawn.
///
/// Angles follow the gravity vector in the device's own frame (Core Motion:
/// x to the right of the portrait screen, y up it, z out of the glass) and are
/// **clockwise-positive**, in degrees — clockwise as the person holding the
/// phone sees it, which is also SwiftUI's `rotationEffect` sense on a y-down
/// screen.
public struct HorizonLevel: Equatable, Sendable {
    /// Signed degrees the picture is off level — the phone's roll about the
    /// lens axis, measured from the hold. Positive when the phone is turned
    /// clockwise past it; within ±45 by construction.
    public let offLevelDegrees: Double
    /// The hold, in clockwise quarter turns from upright portrait, 0…3:
    /// 1 is the phone turned clockwise onto its side (the interface's
    /// `.landscapeLeft`), 3 anticlockwise (`.landscapeRight`), 2 upside down.
    public let holdQuarterTurns: Int
    /// Where the level's reference — the picture's horizontal axis — lies on a
    /// screen drawn upright at the interface's quarter turn: 0 when the chrome
    /// follows the hold, ±90 under a rotation lock across it, 180 on an
    /// iPhone held upside down (whose chrome never turns that far — the
    /// assembly turns with the person's head instead). In (−180, 180].
    public let referenceDegrees: Double

    public init(offLevelDegrees: Double, holdQuarterTurns: Int, referenceDegrees: Double) {
        self.offLevelDegrees = offLevelDegrees
        self.holdQuarterTurns = holdQuarterTurns
        self.referenceDegrees = referenceDegrees
    }

    /// Where the horizon itself lies on the screen: the reference, turned back
    /// by however far the phone is off level. A phone turned clockwise sees
    /// the world turn anticlockwise.
    public var horizonDegrees: Double {
        Self.normalizedDegrees(referenceDegrees - offLevelDegrees)
    }

    /// Below this share of gravity in the screen's plane the phone is lying
    /// flat or looking straight up or down (≈ 72° or more from upright), and
    /// its roll stops meaning anything — the angle between two near-zero
    /// components swings wildly with noise. The level shows no reading there
    /// rather than a confident wrong one.
    public static let minimumInPlaneGravity = 0.3

    /// The level for one gravity reading, or nil when there is none worth
    /// showing (the phone lies flat, or the reading is not a number).
    ///
    /// - Parameters:
    ///   - gravityX: gravity along the device's x axis, in g.
    ///   - gravityY: gravity along the device's y axis, in g.
    ///   - interfaceQuarterTurns: the clockwise quarter turns at which the
    ///     interface is drawn upright (portrait 0, `.landscapeLeft` 1,
    ///     `.portraitUpsideDown` 2, `.landscapeRight` 3); any integer, folded.
    public static func reading(gravityX: Double, gravityY: Double, interfaceQuarterTurns: Int) -> HorizonLevel? {
        guard gravityX.isFinite, gravityY.isFinite,
              (gravityX * gravityX + gravityY * gravityY).squareRoot() >= minimumInPlaneGravity
        else { return nil }
        // `atan2` over the two axes in the screen plane stays correct through
        // the full ±180°, where `asin` would fold at the extremes. Upright
        // portrait has gravity along −y, which reads 0.
        let roll = atan2(gravityX, -gravityY) * 180 / .pi
        let hold = (roll / 90).rounded()
        return HorizonLevel(
            offLevelDegrees: roll - hold * 90,
            holdQuarterTurns: QuarterTurns.normalized(Int(hold)),
            referenceDegrees: referenceDegrees(
                holdQuarterTurns: Int(hold),
                interfaceQuarterTurns: interfaceQuarterTurns
            )
        )
    }

    /// The reference's on-screen angle for a hold drawn in an interface:
    /// the interface's own turn less the hold's, folded into (−180, 180].
    public static func referenceDegrees(holdQuarterTurns: Int, interfaceQuarterTurns: Int) -> Double {
        normalizedDegrees(Double(interfaceQuarterTurns - holdQuarterTurns) * 90)
    }

    /// Any angle folded into (−180, 180].
    public static func normalizedDegrees(_ degrees: Double) -> Double {
        var folded = degrees.truncatingRemainder(dividingBy: 360)
        if folded <= -180 { folded += 360 }
        if folded > 180 { folded -= 360 }
        return folded
    }
}
