import SwiftUI

/// The LetsLapse rig — the app icon's mark — drawn as a single `Canvas` pass
/// and animated from a clock rather than from SwiftUI transitions.
///
/// Two reasons it is a `Canvas` and not ~20 composed shapes: the render screen
/// this lives on re-renders constantly from `AppModel.progress`, so view-graph
/// churn is the thing to avoid; and every "draw-on" and "sweep" in the design
/// is an arc *fraction*, which is far more honest to compute directly than to
/// coax out of `.trim` plus an implicit animation.
///
/// Geometry, colours and timings are a port of the signed-off design
/// (Claude Design → "LetsLapse Loading Animation", turns 4a/4b/5a). The design
/// works in a 1024×1024 box; so does everything below.

// MARK: - Colour

/// Straight RGB so colours can be interpolated (the rim and board rim both
/// *cool* from accent to a slate as the mark settles).
struct LLRigRGB {
    var r: Double, g: Double, b: Double

    init(_ r: Int, _ g: Int, _ b: Int) {
        self.r = Double(r) / 255
        self.g = Double(g) / 255
        self.b = Double(b) / 255
    }

    func color(_ opacity: Double = 1) -> Color {
        Color(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }

    static func lerp(_ a: LLRigRGB, _ b: LLRigRGB, _ t: Double) -> LLRigRGB {
        var out = a
        out.r += (b.r - a.r) * t
        out.g += (b.g - a.g) * t
        out.b += (b.b - a.b) * t
        return out
    }
}

/// The mark's own palette — deliberately *not* `LL` tokens. `LL.accent`
/// (#C36A00) is the UI's burnt orange and `LL.amber` (#FFB340) its highlight;
/// the rig's amber is the app icon's #F0A32C and never appears outside the mark.
enum LLRigPalette {
    static let accent = LLRigRGB(0xF0, 0xA3, 0x2C)
    static let rimCool = LLRigRGB(0x6E, 0x7F, 0x99)
    static let boardRimCool = LLRigRGB(0x24, 0x5A, 0x85)
    static let legBack = LLRigRGB(0x1E, 0x43, 0x68)
    static let legFront = LLRigRGB(0x12, 0x32, 0x4F)
    static let irisBase = LLRigRGB(0x02, 0x04, 0x0C)

    static let pipe: [(Double, LLRigRGB)] = [
        (0.00, LLRigRGB(0xE9, 0xEE, 0xF6)),
        (0.45, LLRigRGB(0xBA, 0xC6, 0xD8)),
        (1.00, LLRigRGB(0x7C, 0x8C, 0xA5)),
    ]
    static let board: [(Double, LLRigRGB)] = [
        (0.00, LLRigRGB(0x0E, 0x2E, 0x4E)),
        (1.00, LLRigRGB(0x04, 0x10, 0x1F)),
    ]
    static let lens: [(Double, LLRigRGB)] = [
        (0.00, LLRigRGB(0x1E, 0x1C, 0x48)),
        (0.26, LLRigRGB(0x4A, 0x4A, 0x93)),
        (0.42, LLRigRGB(0x15, 0x03, 0x32)),
        (0.72, LLRigRGB(0x0C, 0x03, 0x22)),
        (1.00, LLRigRGB(0x00, 0x1C, 0x4C)),
    ]

    /// The field the mark sits on, and the wordmark over it. Dark in both
    /// appearances by design: the mark's home is the app icon's navy, and Create
    /// opens straight into the camera, so a light launch would seam badly into a
    /// black viewfinder a moment later.
    static let field = LLRigRGB(0x0A, 0x0F, 0x1C)
    static let wordmark = LLRigRGB(0xC6, 0xD2, 0xE4)

    static func gradient(_ stops: [(Double, LLRigRGB)], opacity: Double = 1) -> Gradient {
        Gradient(stops: stops.map { .init(color: $0.1.color(opacity), location: $0.0) })
    }
}

// MARK: - Easing

/// A CSS `cubic-bezier`. The design leans on overshooting curves (y₂ > 1), so
/// the solver has to tolerate values outside 0…1 — that overshoot *is* the
/// "nothing snaps into place, everything arrives with weight" of the brief.
struct LLEase {
    private let ax, bx, cx: Double
    private let ay, by, cy: Double

    init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
        cx = 3 * x1
        bx = 3 * (x2 - x1) - cx
        ax = 1 - cx - bx
        cy = 3 * y1
        by = 3 * (y2 - y1) - cy
        ay = 1 - cy - by
    }

    private func sampleX(_ u: Double) -> Double { ((ax * u + bx) * u + cx) * u }
    private func sampleY(_ u: Double) -> Double { ((ay * u + by) * u + cy) * u }
    private func slopeX(_ u: Double) -> Double { (3 * ax * u + 2 * bx) * u + cx }

    func callAsFunction(_ t: Double) -> Double {
        if t <= 0 { return 0 }
        if t >= 1 { return 1 }

        // Newton first — converges in a couple of steps for every curve here.
        var u = t
        for _ in 0..<8 {
            let x = sampleX(u) - t
            if abs(x) < 1e-6 { return sampleY(u) }
            let d = slopeX(u)
            if abs(d) < 1e-6 { break }
            u -= x / d
        }

        // Bisection fallback for the flat-slope curves (.5,0,.15,1 and friends).
        var lo = 0.0, hi = 1.0
        u = t
        while lo < hi {
            let x = sampleX(u)
            if abs(x - t) < 1e-6 { break }
            if t > x { lo = u } else { hi = u }
            u = (hi - lo) / 2 + lo
            if hi - lo < 1e-7 { break }
        }
        return sampleY(u)
    }

    static let linear = LLEase(0, 0, 1, 1)
    static let easeOut = LLEase(0, 0, 0.58, 1)
    static let easeInOut = LLEase(0.42, 0, 0.58, 1)

    // The design's own curves, one per keyframe family.
    static let rootIn = LLEase(0.22, 1.1, 0.32, 1)
    static let loopIn = LLEase(0.22, 1.1, 0.32, 1)
    static let draw = LLEase(0.5, 0, 0.15, 1)
    static let drawLens = LLEase(0.45, 0, 0.15, 1)
    static let legBack = LLEase(0.3, 1.4, 0.5, 1)
    static let legFront = LLEase(0.3, 1.45, 0.5, 1)
    static let fillPipe = LLEase(0.34, 1.4, 0.5, 1)
    static let fillBoard = LLEase(0.34, 1.45, 0.5, 1)
    static let pop = LLEase(0.3, 1.6, 0.5, 1)
    static let irisOpen = LLEase(0.3, 1.5, 0.5, 1)
    static let spin = LLEase(0.62, 0, 0.38, 1)
}

/// A CSS keyframe track. The timing function applies to each *segment*, which
/// is what gives `llLegDrop` its punch-down-then-settle rather than one long ease.
private func llKey(_ p: Double, _ stops: [(Double, Double)], _ ease: LLEase) -> Double {
    guard let first = stops.first, let last = stops.last else { return 0 }
    if p <= first.0 { return first.1 }
    if p >= last.0 { return last.1 }
    for i in 1..<stops.count where p <= stops[i].0 {
        let (p0, v0) = stops[i - 1]
        let (p1, v1) = stops[i]
        let u = p1 > p0 ? (p - p0) / (p1 - p0) : 1
        return v0 + (v1 - v0) * ease(u)
    }
    return last.1
}

private func llClamp01(_ v: Double) -> Double { min(1, max(0, v)) }

/// Local progress of a delayed clip, with CSS `fill-mode: both` semantics —
/// before the delay it holds the 0% frame, after it holds the 100% frame.
private func llClip(_ time: Double, delay: Double, duration: Double) -> Double {
    guard duration > 0 else { return 1 }
    return llClamp01((time - delay) / duration)
}

/// Position within a repeating cycle.
private func llPhase(_ time: Double, cycle: Double) -> Double {
    guard cycle > 0 else { return 0 }
    let p = time.truncatingRemainder(dividingBy: cycle) / cycle
    return p < 0 ? p + 1 : p
}

// MARK: - Beats

/// The assembly beat sheet, in seconds, lifted from the design's CSS. One place
/// so retiming the build never means hunting through draw code.
enum LLRigBeats {
    /// Door to door for the build, including the glint that lands last.
    static let build: Double = 2.244
    /// The idle/render loop.
    static let loop: Double = 1.70

    static let root = (delay: 0.0, duration: 2.006)
    static let glowIn = (delay: 0.0, duration: 1.224)
    static let glowPulseStart: Double = 2.04
    static let glowPulseCycle: Double = 4.42

    static let rimDraw = (delay: 0.102, duration: 0.816)
    static let rimCool = (delay: 1.122, duration: 0.578)
    static let pipeFill = (delay: 0.510, duration: 0.782)

    static let backLegs = (delays: [0.442, 0.527], duration: 0.884)
    static let frontLegs = (delays: [0.714, 0.799], duration: 0.884)

    static let boardDraw = (delay: 0.578, duration: 0.782)
    static let boardFill = (delay: 0.952, duration: 0.714)
    static let boardCool = (delay: 1.462, duration: 0.510)

    static let lensDraw = (delay: 0.850, duration: 0.748)
    static let iris = (delay: 1.224, duration: 0.748)
    static let glint = (delay: 1.666, duration: 0.578)

    /// Clockwise from top-left, 85 ms apart.
    static let pads = (delays: [1.258, 1.343, 1.428, 1.513], duration: 0.544)

    /// Wordmark rise on the launch screen — after the mark has settled.
    static let wordmark = (delay: 1.780, duration: 0.500)

    static let loopInDuration: Double = 0.5
}

// MARK: - Geometry

/// Everything in the design's 1024×1024 box.
private enum G {
    static let box: CGFloat = 1024

    static let pipeCentre = CGPoint(x: 512, y: 486)
    static let pipeRadius: CGFloat = 402
    static let glowRadius: CGFloat = 440

    static let board = CGRect(x: 242, y: 234, width: 540, height: 456)
    static let boardRadius: CGFloat = 18

    static let lensCentre = CGPoint(x: 478, y: 452)
    static let lensRingRadius: CGFloat = 196
    static let irisRadius: CGFloat = 173

    /// The whole rig leans 5° left.
    static let lean: Double = -5

    /// leg rect · foot rect · transform origin for the drop
    static let backLegs: [(CGRect, CGRect, CGPoint)] = [
        (CGRect(x: 281, y: 790, width: 34, height: 112),
         CGRect(x: 269, y: 884, width: 58, height: 20), CGPoint(x: 298, y: 792)),
        (CGRect(x: 709, y: 790, width: 34, height: 112),
         CGRect(x: 697, y: 884, width: 58, height: 20), CGPoint(x: 726, y: 792)),
    ]
    static let frontLegs: [(CGRect, CGRect, CGPoint)] = [
        (CGRect(x: 340, y: 640, width: 48, height: 134),
         CGRect(x: 325, y: 752, width: 78, height: 24), CGPoint(x: 364, y: 642)),
        (CGRect(x: 636, y: 640, width: 48, height: 134),
         CGRect(x: 621, y: 752, width: 78, height: 24), CGPoint(x: 660, y: 642)),
    ]
    static let legRadii: (back: CGFloat, backFoot: CGFloat, front: CGFloat, frontFoot: CGFloat) =
        (9, 10, 12, 12)

    /// Interval pads, clockwise from top-left.
    static let pads: [CGRect] = [
        CGRect(x: 274, y: 266, width: 32, height: 32),
        CGRect(x: 718, y: 266, width: 32, height: 32),
        CGRect(x: 718, y: 626, width: 32, height: 32),
        CGRect(x: 274, y: 626, width: 32, height: 32),
    ]
    static let padRadius: CGFloat = 8

    static let glint = (centre: CGPoint(x: 422, y: 392), rx: 66.0, ry: 38.0, rotation: -38.0)
}

// MARK: - The mark

enum LLRigStyle {
    /// The full mark: the iris breathes and carries a glint.
    case full
    /// Gauge mode (design 5a): the lens holds steady and its gradient is dimmed
    /// so the number in front of it owns the space.
    case gauge
}

struct LLRigMark: View {
    /// Where the lens sits as a fraction of the mark's box. The percent readout
    /// in design 5a is centred on the *lens*, which the rig's 5° lean and the
    /// board's offset put up and to the left of the view centre.
    static let lensUnitCentre = CGPoint(x: 478.0 / 1024, y: 452.0 / 1024)
    /// The aperture the readout has to live inside, as a fraction of the box.
    static let lensUnitDiameter: CGFloat = 346.0 / 1024

    /// 0…1 assembly. 1 is fully built.
    var build: Double
    /// Seconds since the animation started; drives every looping motion.
    var time: Double
    var style: LLRigStyle = .full
    /// The running head arc (design 4b/5a). Also gates the rest of the loop —
    /// bobbing legs, rocking board, chasing pads.
    var sweep: Bool = false

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            let side = min(size.width, size.height)
            guard side > 0 else { return }
            var ctx = context
            ctx.translateBy(x: (size.width - side) / 2, y: (size.height - side) / 2)
            ctx.scaleBy(x: side / G.box, y: side / G.box)
            draw(into: &ctx)
        }
        .allowsHitTesting(false)
    }

    // MARK: Draw

    private func draw(into ctx: inout GraphicsContext) {
        drawGlow(into: &ctx)

        // The mark's own entrance: a settling overshoot on the build, a short
        // scale-up when a gauge mounts.
        ctx.drawLayer { root in
            let t = build * LLRigBeats.build
            if sweep {
                let p = llClip(time, delay: 0, duration: LLRigBeats.loopInDuration)
                root.opacity = llKey(p, [(0, 0), (1, 1)], .loopIn)
                root.llScale(llKey(p, [(0, 0.90), (0.6, 1.02), (1, 1)], .loopIn), about: G.pipeCentre)
            } else {
                let p = llClip(t, delay: LLRigBeats.root.delay, duration: LLRigBeats.root.duration)
                root.opacity = llKey(p, [(0, 0), (0.18, 1), (1, 1)], .rootIn)
                root.llScale(
                    llKey(p, [(0, 0.80), (0.56, 1.055), (0.78, 0.982), (1, 1)], .rootIn),
                    about: G.pipeCentre)
                root.llRotate(
                    llKey(p, [(0, -9), (0.56, 2.5), (0.78, -1), (1, 0)], .rootIn),
                    about: G.pipeCentre)
            }

            drawBackLegs(into: &root, t: t)
            drawPipe(into: &root, t: t)
            if sweep { drawSweep(into: &root) }
            drawFrontLegsAndBoard(into: &root, t: t)
            drawLens(into: &root, t: t)
        }
    }

    private func drawGlow(into ctx: inout GraphicsContext) {
        let (opacity, scale) = glowState
        guard opacity > 0.001 else { return }
        let r = G.glowRadius * scale
        let rect = CGRect(
            x: G.pipeCentre.x - r, y: G.pipeCentre.y - r, width: r * 2, height: r * 2)
        let accent = LLRigPalette.accent
        ctx.fill(
            Path(ellipseIn: rect),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: accent.color(0.55 * opacity), location: 0),
                    .init(color: accent.color(0), location: 1),
                ]),
                center: G.pipeCentre, startRadius: 0, endRadius: r))
    }

    /// `llGlowIn` then `llGlowPulse` — the loop runs a faster, shallower pulse
    /// than the idle one that follows a build.
    private var glowState: (opacity: Double, scale: Double) {
        if sweep {
            let p = llPhase(time, cycle: LLRigBeats.loop)
            return (llKey(p, [(0, 0.24), (0.5, 0.48), (1, 0.24)], .easeInOut),
                    llKey(p, [(0, 0.95), (0.5, 1.06), (1, 0.95)], .easeInOut))
        }
        // The idle pulse runs off the real clock, not the assembly progress —
        // otherwise it would freeze the moment the build finished.
        if time > LLRigBeats.glowPulseStart {
            let p = llPhase(time - LLRigBeats.glowPulseStart, cycle: LLRigBeats.glowPulseCycle)
            return (llKey(p, [(0, 0.24), (0.5, 0.48), (1, 0.24)], .easeInOut),
                    llKey(p, [(0, 0.95), (0.5, 1.06), (1, 0.95)], .easeInOut))
        }
        let t = build * LLRigBeats.build
        let p = llClip(t, delay: LLRigBeats.glowIn.delay, duration: LLRigBeats.glowIn.duration)
        return (llKey(p, [(0, 0), (0.55, 0.58), (1, 0.34)], .easeOut),
                llKey(p, [(0, 0.42), (1, 1)], .easeOut))
    }

    // MARK: Legs

    private func drawBackLegs(into ctx: inout GraphicsContext, t: Double) {
        ctx.drawLayer { lean in
            lean.llRotate(G.lean, about: G.pipeCentre)
            for (i, leg) in G.backLegs.enumerated() {
                drawLeg(
                    into: &lean, leg: leg, t: t,
                    delay: LLRigBeats.backLegs.delays[i], duration: LLRigBeats.backLegs.duration,
                    ease: .legBack, bobOffset: i == 0 ? 0 : 0.12,
                    body: LLRigPalette.legBack,
                    radius: G.legRadii.back, footRadius: G.legRadii.backFoot)
            }
        }
    }

    private func drawLeg(
        into ctx: inout GraphicsContext,
        leg: (CGRect, CGRect, CGPoint),
        t: Double, delay: Double, duration: Double, ease: LLEase,
        bobOffset: Double,
        body: LLRigRGB,
        radius: CGFloat, footRadius: CGFloat
    ) {
        let (bar, foot, origin) = leg
        ctx.drawLayer { g in
            let p = llClip(t, delay: delay, duration: duration)
            g.opacity = llKey(p, [(0, 0), (0.5, 1), (1, 1)], ease)

            // The drop: punch down past the mark, overshoot back, settle.
            let dy = llKey(p, [(0, -72), (0.5, 16), (0.76, -6), (1, 0)], ease)
            let sy = llKey(p, [(0, 0.42), (0.5, 1.14), (0.76, 0.94), (1, 1)], ease)
            g.translateBy(x: 0, y: dy)
            g.translateBy(x: origin.x, y: origin.y)
            g.scaleBy(x: 1, y: sy)
            g.translateBy(x: -origin.x, y: -origin.y)

            // Follow-through once it's standing.
            if sweep {
                let bob = llPhase(time - bobOffset, cycle: LLRigBeats.loop)
                g.translateBy(x: 0, y: llKey(bob, [(0, 0), (0.5, 7), (1, 0)], .easeInOut))
            }

            g.fill(Path(roundedRect: bar, cornerRadius: radius), with: .color(body.color()))
            g.fill(
                Path(roundedRect: foot, cornerRadius: footRadius),
                with: .color(LLRigPalette.accent.color()))
        }
    }

    // MARK: Pipe

    private func drawPipe(into ctx: inout GraphicsContext, t: Double) {
        let circle = CGRect(
            x: G.pipeCentre.x - G.pipeRadius, y: G.pipeCentre.y - G.pipeRadius,
            width: G.pipeRadius * 2, height: G.pipeRadius * 2)

        // Colour floods in *under* the line that drew it.
        ctx.drawLayer { fill in
            let p = llClip(t, delay: LLRigBeats.pipeFill.delay, duration: LLRigBeats.pipeFill.duration)
            fill.opacity = llKey(p, [(0, 0), (0.62, 1), (1, 1)], .fillPipe)
            fill.llScale(llKey(p, [(0, 0.86), (0.62, 1.045), (1, 1)], .fillPipe), about: G.pipeCentre)
            fill.fill(
                Path(ellipseIn: circle),
                with: .linearGradient(
                    LLRigPalette.gradient(LLRigPalette.pipe),
                    startPoint: CGPoint(x: circle.minX + circle.width * 0.1, y: circle.minY),
                    endPoint: CGPoint(x: circle.minX + circle.width * 0.9, y: circle.maxY)))
        }

        let drawn = LLEase.draw(
            llClip(t, delay: LLRigBeats.rimDraw.delay, duration: LLRigBeats.rimDraw.duration))
        guard drawn > 0 else { return }
        let cooled = LLEase.easeOut(
            llClip(t, delay: LLRigBeats.rimCool.delay, duration: LLRigBeats.rimCool.duration))
        let rim = LLRigRGB.lerp(LLRigPalette.accent, LLRigPalette.rimCool, cooled)
        ctx.stroke(
            llArcPath(centre: G.pipeCentre, radius: G.pipeRadius, from: 0, to: drawn),
            with: .color(rim.color()), style: StrokeStyle(lineWidth: 9))
    }

    /// The running head and its trail (design 4b/5a): one arc that stretches as
    /// it accelerates and pulls tight as it slows.
    private func drawSweep(into ctx: inout GraphicsContext) {
        let p = llPhase(time, cycle: LLRigBeats.loop)
        let spin = LLEase.spin(p)
        let accent = LLRigPalette.accent
        let style = StrokeStyle(lineWidth: 17, lineCap: .round)

        // Trail first, so the bright head rides over it.
        let trailPhase = llPhase(time + 0.16, cycle: LLRigBeats.loop)
        let trailLength = llKey(trailPhase, [(0, 0.09), (0.5, 0.27), (1, 0.09)], .easeInOut)
        ctx.stroke(
            llArcPath(centre: G.pipeCentre, radius: G.pipeRadius, from: spin, to: spin + trailLength),
            with: .color(accent.color(0.28)), style: style)

        let headLength = llKey(p, [(0, 0.09), (0.5, 0.27), (1, 0.09)], .easeInOut)
        ctx.stroke(
            llArcPath(centre: G.pipeCentre, radius: G.pipeRadius, from: spin, to: spin + headLength),
            with: .color(accent.color()), style: style)
    }

    // MARK: Board

    private func drawFrontLegsAndBoard(into ctx: inout GraphicsContext, t: Double) {
        ctx.drawLayer { lean in
            lean.llRotate(G.lean, about: G.pipeCentre)

            for (i, leg) in G.frontLegs.enumerated() {
                drawLeg(
                    into: &lean, leg: leg, t: t,
                    delay: LLRigBeats.frontLegs.delays[i], duration: LLRigBeats.frontLegs.duration,
                    ease: .legFront, bobOffset: i == 0 ? 0.06 : 0.18,
                    body: LLRigPalette.legFront,
                    radius: G.legRadii.front, footRadius: G.legRadii.frontFoot)
            }

            lean.drawLayer { tilt in
                if sweep {
                    let p = llPhase(time, cycle: LLRigBeats.loop)
                    tilt.llRotate(
                        llKey(p, [(0, 0), (0.5, -2.4), (1, 0)], .easeInOut), about: G.pipeCentre)
                }
                drawBoard(into: &tilt, t: t)
                drawPads(into: &tilt, t: t)
            }
        }
    }

    private func drawBoard(into ctx: inout GraphicsContext, t: Double) {
        let shape = Path(roundedRect: G.board, cornerRadius: G.boardRadius)

        ctx.drawLayer { fill in
            let p = llClip(t, delay: LLRigBeats.boardFill.delay, duration: LLRigBeats.boardFill.duration)
            fill.opacity = llKey(p, [(0, 0), (0.62, 1), (1, 1)], .fillBoard)
            fill.llScale(
                llKey(p, [(0, 0.86), (0.62, 1.045), (1, 1)], .fillBoard),
                about: CGPoint(x: G.board.midX, y: G.board.midY))
            fill.fill(
                shape,
                with: .linearGradient(
                    LLRigPalette.gradient(LLRigPalette.board),
                    startPoint: CGPoint(x: G.board.minX, y: G.board.minY),
                    endPoint: CGPoint(x: G.board.minX + G.board.width * 0.4, y: G.board.maxY)))
        }

        let drawn = LLEase.draw(
            llClip(t, delay: LLRigBeats.boardDraw.delay, duration: LLRigBeats.boardDraw.duration))
        guard drawn > 0 else { return }
        let cooled = LLEase.easeOut(
            llClip(t, delay: LLRigBeats.boardCool.delay, duration: LLRigBeats.boardCool.duration))
        let rim = LLRigRGB.lerp(LLRigPalette.accent, LLRigPalette.boardRimCool, cooled)
        ctx.stroke(
            drawn >= 1 ? shape : shape.trimmedPath(from: 0, to: drawn),
            with: .color(rim.color()), style: StrokeStyle(lineWidth: 7))
    }

    private func drawPads(into ctx: inout GraphicsContext, t: Double) {
        for (i, pad) in G.pads.enumerated() {
            ctx.drawLayer { g in
                let p = llClip(t, delay: LLRigBeats.pads.delays[i], duration: LLRigBeats.pads.duration)
                var opacity = llKey(p, [(0, 0), (0.55, 1), (1, 1)], .pop)
                var scale = llKey(p, [(0, 0), (0.55, 1.38), (0.78, 0.90), (1, 1)], .pop)

                if sweep {
                    // Each pad lights in turn — the interval marker, ticking.
                    let chase = llPhase(time - Double(i) * 0.42, cycle: LLRigBeats.loop)
                    opacity = llKey(
                        chase, [(0, 0.32), (0.10, 1), (0.30, 0.45), (0.62, 0.32), (1, 0.32)], .easeInOut)
                    scale = llKey(
                        chase, [(0, 1), (0.10, 1.55), (0.30, 1), (0.62, 1), (1, 1)], .easeInOut)
                }

                g.opacity = opacity
                g.llScale(scale, about: CGPoint(x: pad.midX, y: pad.midY))
                g.fill(
                    Path(roundedRect: pad, cornerRadius: G.padRadius),
                    with: .color(LLRigPalette.accent.color()))
            }
        }
    }

    // MARK: Lens

    private func drawLens(into ctx: inout GraphicsContext, t: Double) {
        let drawn = LLEase.drawLens(
            llClip(t, delay: LLRigBeats.lensDraw.delay, duration: LLRigBeats.lensDraw.duration))
        if drawn > 0 {
            ctx.stroke(
                llArcPath(centre: G.lensCentre, radius: G.lensRingRadius, from: 0, to: drawn),
                with: .color(LLRigPalette.accent.color()), style: StrokeStyle(lineWidth: 14))
        }

        let irisRect = CGRect(
            x: G.lensCentre.x - G.irisRadius, y: G.lensCentre.y - G.irisRadius,
            width: G.irisRadius * 2, height: G.irisRadius * 2)
        // Dimmed in gauge mode so the digits in front of it stay legible.
        let lensOpacity = style == .gauge ? 0.55 : 0.85

        ctx.drawLayer { g in
            let p = llClip(t, delay: LLRigBeats.iris.delay, duration: LLRigBeats.iris.duration)
            g.opacity = llKey(p, [(0, 0), (0.55, 1), (1, 1)], .irisOpen)
            var scale = llKey(p, [(0, 0), (0.55, 1.16), (0.80, 0.95), (1, 1)], .irisOpen)

            // The lens breathes with the sweep — but not in gauge mode, where a
            // moving aperture behind a number reads as a wobble.
            if sweep, style == .full {
                let breathe = llPhase(time, cycle: LLRigBeats.loop)
                scale *= llKey(
                    breathe, [(0, 1), (0.40, 0.87), (0.68, 1.04), (1, 1)], .easeInOut)
            }
            g.llScale(scale, about: G.lensCentre)

            g.fill(Path(ellipseIn: irisRect), with: .color(LLRigPalette.irisBase.color()))
            g.fill(
                Path(ellipseIn: irisRect),
                with: .linearGradient(
                    LLRigPalette.gradient(LLRigPalette.lens, opacity: lensOpacity),
                    startPoint: CGPoint(x: G.lensCentre.x, y: irisRect.minY),
                    endPoint: CGPoint(x: G.lensCentre.x, y: irisRect.maxY)))

            if style == .full, sweep {
                drawGlint(into: &g, opacity: 0.16)
            }
        }

        if style == .full, !sweep {
            let p = llClip(t, delay: LLRigBeats.glint.delay, duration: LLRigBeats.glint.duration)
            drawGlint(into: &ctx, opacity: LLEase.easeOut(p) * 0.16)
        }
    }

    private func drawGlint(into ctx: inout GraphicsContext, opacity: Double) {
        guard opacity > 0.001 else { return }
        let (centre, rx, ry, rotation) = G.glint
        let rect = CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2)
        let path = Path(ellipseIn: rect).applying(
            CGAffineTransform(translationX: centre.x, y: centre.y)
                .rotated(by: rotation * .pi / 180))
        ctx.fill(path, with: .color(.white.opacity(opacity)))
    }
}

// MARK: - Helpers

/// An arc as a fraction of the circle, starting at 12 o'clock and running
/// clockwise — the direction every draw-on in the design travels.
private func llArcPath(centre: CGPoint, radius: CGFloat, from: Double, to: Double) -> Path {
    Path { p in
        p.addArc(
            center: centre, radius: radius,
            startAngle: .degrees(-90 + from * 360),
            endAngle: .degrees(-90 + to * 360),
            clockwise: false)
    }
}

private extension GraphicsContext {
    mutating func llRotate(_ degrees: Double, about point: CGPoint) {
        guard degrees != 0 else { return }
        translateBy(x: point.x, y: point.y)
        rotate(by: .degrees(degrees))
        translateBy(x: -point.x, y: -point.y)
    }

    mutating func llScale(_ scale: Double, about point: CGPoint) {
        guard scale != 1 else { return }
        translateBy(x: point.x, y: point.y)
        scaleBy(x: scale, y: scale)
        translateBy(x: -point.x, y: -point.y)
    }
}
