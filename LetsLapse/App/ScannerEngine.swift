import Foundation
import LetsLapseKit
#if os(iOS)
import AVFoundation
import CoreVideo
#endif

// MARK: - The state machine

/// **Scanner** — the decision of *when* to fire, taken from the scene instead
/// of from a timer.
///
/// There are **two of those decisions**, not one with a filter on it, and which
/// one runs is chosen by the PAPER dial (`Trigger`).
///
/// ### Motion (PAPER = Auto) — "capture what happens"
///
/// The shooting loop it exists for: put the object down, take your hand out of
/// frame, hear the click, reach in, move it, take your hand out again, hear the
/// click. Thirty-six times around a turntable is the canonical photogrammetry
/// set, and every one of those frames is a pose the operator chose — so the
/// camera's whole job is to notice that the choosing has finished.
///
/// | State | Meaning |
/// |---|---|
/// | `settled` | Waiting. This pose is already captured; nothing to do until something moves. |
/// | `disturbed` | Motion — a hand entering the frame, the object being turned. |
/// | `reSettled` | The scene has gone still again. Fire, now. |
///
/// `reSettled` is momentary by construction: the engine emits its fire signal
/// and drops straight back to `settled`, because the frame it just took *is*
/// this pose. There is no state in which the engine is "ready to fire and
/// waiting" — readiness and firing are the same instant.
///
/// ### Rectangle (PAPER = A4 · Letter · 4×6 · Square) — "capture the page"
///
/// **Motion is irrelevant here, and treating it as the trigger was the bug.**
/// A document scan has no disturb/re-settle cycle to wait for: the page is put
/// down and stays put, which under the motion model is a scene that never
/// changes and therefore never fires. Worse, measured on a *handheld* phone
/// (2026-08-17, screen recording), the page's corners drift across the frame
/// with the operator's hand every single tick, so the motion machine re-armed
/// its window continuously and the HUD read "Settling…" for a whole recording
/// with one frame banked.
///
/// So the question changes from "has the scene stopped changing?" to "**is
/// there a page, and is it holding still?**":
///
/// | State | Meaning |
/// |---|---|
/// | `waitingForPage` | Nothing flat in view. Nothing to photograph. |
/// | `holding` | Corners found; they have stayed inside `documentStabilityThreshold` since `holdStartedAt`. Fire when the window is full. |
/// | `captured` | This page is banked. Nothing more until it is taken away — see below. |
///
/// The stability window is about **blur, not composition**: the corners are
/// re-detected on every frame and the ones stamped into the sidecar are the
/// fired frame's own, so a page that has shifted since the last shot is still
/// rectified correctly. All the window has to establish is that the page is not
/// moving *now*, which is why its threshold is looser than the turntable
/// path's — it has to sit above hand tremor and below a page being slid.
///
/// `captured` is what stops a page sitting on a desk from being photographed
/// twenty times — and it took three attempts to get right, each failing on a
/// real desk:
///
/// 1. A **time cooldown** re-armed on its own, so a stationary sheet was taken
///    again every couple of seconds.
/// 2. **"The corners moved far enough"** re-armed when the detector merely
///    re-acquired the same page a few percent off, which it does constantly.
/// 3. **"The rectangle went missing"** re-armed on a single dropped detection —
///    and the detector blinks on its own, 22 times in one run over a sheet that
///    never moved.
///
/// 4. **Absence alone** re-armed on a detector that goes quiet for *seconds*
///    over a page it is still pointed at — measured, with the frame difference
///    at 0.0014 against a 0.028 threshold, i.e. a scene where provably nothing
///    happened.
///
/// So a removal now has to be **seen happening**: the page out of sight for
/// `pageAbsenceDelay` *and* the frame having visibly changed since the capture
/// (`sceneChangedSinceCapture`). Lifting a sheet does both — a hand arrives, the
/// desk appears. A blinking detector over a still desk does neither, however
/// long it blinks. Put a page down and leave it, and exactly one frame exists of
/// it, however badly the detector behaves and however long the camera watches.
///
/// The order those states may be visited in is not an outcome of any of this —
/// it is a table (`legalPageTransitions`) that every move is checked against.
///
/// **The settle delay is wall-clock, not a frame count.** Preview frames arrive
/// at whatever rate the session and the light allow (a dark scene at a long
/// exposure delivers far fewer), so "still for 30 frames" means something
/// different every time the light changes. "Still since a moment 1.0 s ago"
/// means the same thing always. The engine takes the time with every
/// measurement rather than reading a clock itself, which is also what makes it
/// testable without waiting in real time.
///
/// The engine is deliberately not an actor and holds no I/O: it is called from
/// the camera's own serial queue, once per preview frame, and every field it
/// owns is confined to that queue by the caller. See `ScannerMotionAnalyzer`
/// for the measurement side.
final class ScannerEngine {

    /// Which question the shutter is waiting on. Set once per run from the
    /// PAPER dial — a run does not change its mind halfway through, and the
    /// operator's stock is the declaration that decides it.
    enum Trigger: String, Equatable {
        /// Auto: the scene's own motion decides. Turntables, objects, street.
        case motion
        /// A named stock: a flat page holding still decides. Documents.
        case rectangle
    }

    enum State: String, Equatable {
        case settled
        case disturbed
        /// Transient — see the note above; the engine never rests here.
        case reSettled
        // Rectangle-trigger states.
        case waitingForPage
        case holding
        case captured
    }

    /// **The document trigger's only legal moves.** The order is the product
    /// requirement, so it is a structure rather than an outcome:
    ///
    ///     waitingForPage ──page seen──▶ holding ──window full──▶ captured
    ///            ▲                        │                         │
    ///            └────page removed────────┴───────page removed──────┘
    ///
    /// Two things this makes impossible rather than merely unlikely. A pose
    /// cannot be banked without a completed hold window before it, because
    /// `captured` is reachable only from `holding` and only through
    /// `didCapture`. And a run cannot go back to hunting for a page without
    /// passing through the banked state first, because `waitingForPage` is
    /// reachable only from `holding` or `captured` — never from itself, and
    /// never skipped.
    ///
    /// Anything else is refused and recorded in `lastRejectedTransition`, and
    /// trips an assertion in DEBUG. The states were being assigned from six
    /// places with nothing checking the edges; every ordering bug reported so
    /// far was a move that this table would not have allowed.
    private static let legalPageTransitions: [State: Set<State>] = [
        .waitingForPage: [.holding],
        .holding: [.waitingForPage, .captured],
        .captured: [.waitingForPage],
    ]

    // MARK: Tuning

    /// How long the scene must read as still before the shot is taken.
    ///
    /// The trade is entirely about the operator's hand: too short and the
    /// shutter catches fingers still withdrawing, too long and the loop feels
    /// like it has stalled. 1.0 s is comfortable at arm's length. The
    /// user-facing range is 0.5–3.0 s; exposing it is Phase 2 (see the class
    /// note on `motionThreshold`).
    static let defaultSettleDelay: TimeInterval = 1.0
    static let settleDelayRange: ClosedRange<TimeInterval> = 0.5...3.0

    /// Mean absolute frame difference, 0…1, above which the scene reads as
    /// moving.
    ///
    /// It is deliberately high, because the two failure modes are not
    /// symmetric: a threshold set too low turns sensor noise, a flickering bulb
    /// or an auto-exposure twitch into a permanent `disturbed` and the shoot
    /// never fires at all, where an over-eager one costs a frame the operator
    /// can delete. **Both halves of that have now been observed** (iPad Air 5,
    /// static indoor scene, 2026-08-16):
    ///
    /// | | |
    /// |---|---|
    /// | Scene noise floor | ~0.0059 median, 0.0056 min, 0.0131 max over 122 samples |
    /// | At 0.0015 | 100% of samples read as motion → stuck `disturbed` for 125 s, zero fires |
    /// | At 0.008 | ~6% read as motion → real disturb/settle cycles, fires normally |
    /// | At 0.028 (shipped) | 0 of 122 samples read as motion |
    /// | At 0.035 (the original guess) | 0 of 122 |
    ///
    /// The value set from that: **0.028**, ~4.7× the median noise floor and
    /// ~2.1× the worst excursion, with no false trigger anywhere in the sample.
    /// It came down from the original 0.035 deliberately. Both cleared the
    /// noise identically, so the extra margin there bought nothing measurable
    /// and cost sensitivity — and sensitivity is the side that is still
    /// unmeasured (see below), so the tie goes to catching the hand. Measure
    /// your own scene with the DEBUG hooks below: `CameraController` logs
    /// `scanner: mag=…` at 1 Hz through a run.
    ///
    /// **TODO (tuning): the upper bound is still unmeasured.** Nothing here
    /// says how high a *hand* crossing the frame reads, because that needs a
    /// person in front of the camera and the runs above had none. Until it is,
    /// the headroom above 0.028 is an assumption — a slow hand at arm's length
    /// filling little of a 64×48 grid is the case most likely to fall short of
    /// it. Confirm before this becomes a user-facing setting.
    static let defaultMotionThreshold: Float = 0.028

    /// How far a corner may travel, as a fraction of the frame, and still count
    /// as stationary — the rectangle path's equivalent of `motionThreshold`.
    ///
    /// It is a much more specific measurement than the frame difference is:
    /// four points on the object itself, rather than an average over
    /// everything the camera can see. That is the whole reason the path exists.
    /// A page being placed moves its corners tens of percent; a page lying
    /// still moves them by the detector's own jitter, which is a fraction of a
    /// percent on a well-lit edge and larger as contrast falls.
    ///
    /// **TODO (calibration): 2% is a starting value, not a measured one.** It
    /// wants the same treatment `defaultMotionThreshold` got — a real device
    /// over a real copy stand, logging the corner jitter of a stationary page
    /// at several light levels, and the jitter of one being placed. The two
    /// failure modes mirror the differencing threshold's: too tight and
    /// detector noise reads as a page that never settles, too loose and the
    /// shutter catches a page still sliding. Override in the field with
    /// `-scanner.cornerThreshold 0.01`.
    static let defaultCornerStabilityThreshold: Double = 0.02

    /// The rectangle trigger's own stability threshold: how far a corner may
    /// travel, as a fraction of the frame, during the hold window and still
    /// count as a page holding still.
    ///
    /// **Much looser than `defaultCornerStabilityThreshold`, deliberately, and
    /// the tight value is what broke document scanning.** That number describes
    /// a page on a copy stand under a phone that is not moving; a *handheld*
    /// scan moves the whole frame, so the corners of a perfectly still page
    /// drift with the operator's hand. At 2% that drift read as "the page is
    /// being moved" on every tick and the window never completed once in a full
    /// screen recording.
    ///
    /// 4.5% sits above hand tremor at arm's length and well below a page being
    /// placed or slid, which moves corners by tens of percent. It can afford to
    /// be loose because of what the window is *for*: it establishes that the
    /// page is not moving right now, so the frame isn't smeared — not that the
    /// page is where it was before. The corners that rectify the shot are the
    /// fired frame's own.
    ///
    /// **TODO (calibration):** measured only against one recording on an iPhone
    /// 16 Pro. It wants the treatment `defaultMotionThreshold` got — a run that
    /// logs corner travel for a still page held by hand, at several distances,
    /// against one being placed. Override in the field with
    /// `-scanner.documentThreshold 0.03`.
    static let defaultDocumentStabilityThreshold: Double = 0.045

    /// How long the rectangle must be **gone** before the next page may be
    /// taken.
    ///
    /// This one number is the whole re-arm rule, and everything else was wrong.
    /// A page photographed and left where it is must never be photographed
    /// again — the only thing that starts the next pose is the operator taking
    /// this one away. So the clock does not start at the capture; it starts
    /// when the page **disappears**, and until it has been gone this long the
    /// shutter stays shut however still and however detected the scene is.
    ///
    /// It has to be a *duration* rather than a single absent frame because the
    /// detector blinks. Measured on an iPhone 16 Pro over a stationary page
    /// (2026-08-17): 22 `rect=none` samples in one run where nothing moved at
    /// all, plus re-acquisitions that land the corners several percent from
    /// where they were. Treating either as "the page was removed" re-armed the
    /// machine, and the same sheet was photographed twenty times over.
    static let defaultPageAbsenceDelay: TimeInterval = 0.5

    /// How long after a capture a disappearance is ignored entirely.
    ///
    /// The shutter is itself a detector dropout: the preview stutters, AE
    /// steps, the operator's hand comes back into frame. Without this, a run
    /// could photograph a page, blink for half a second *because* it
    /// photographed it, call that a removal and take it again — the exact loop
    /// this is fixing, arrived at by a different road.
    static let defaultPostCaptureBlanking: TimeInterval = 0.6

    let settleDelay: TimeInterval
    let motionThreshold: Float
    let cornerStabilityThreshold: Double
    let documentStabilityThreshold: Double
    let pageAbsenceDelay: TimeInterval
    let postCaptureBlanking: TimeInterval

    /// Which decision this run's shutter is waiting on — set from the **PAPER**
    /// dial and fixed for the run.
    ///
    /// `Auto` means "photograph whatever settles", which is the turntable case.
    /// Naming a stock (A4, Letter, 4×6, Square) is a declaration that the
    /// operator is shooting documents, and that changes the trigger outright
    /// rather than filtering it: a page is not a scene that stops changing, and
    /// under the motion model a page put down and left alone is a scene that
    /// never fires. See the class note.
    let trigger: Trigger

    #if DEBUG
    /// Field-tuning overrides, read from `UserDefaults` so they can arrive as
    /// launch arguments on a device that is across a room:
    ///
    ///     devicectl … launch … -- -scanner.motionThreshold 0.002 -scanner.settleDelay 0.6
    ///
    /// This is the lever `defaultMotionThreshold`'s TODO asks for. The number
    /// there is a guess that wants a real device, a real turntable and a range
    /// of light levels before it moves, and none of that is reachable without
    /// being able to change it *while pointed at the thing*. It also makes the
    /// whole capture path — preview tap, downsample, difference, engine, fire,
    /// file, wire — testable against a scene that only drifts, by dropping the
    /// bar to where ambient movement clears it.
    ///
    /// DEBUG-only and deliberately not surfaced in Settings: a user-facing
    /// threshold is Phase 2, after the tuning this exists to serve.
    static func overriddenThreshold() -> Float? {
        guard UserDefaults.standard.object(forKey: "scanner.motionThreshold") != nil else { return nil }
        let value = Float(UserDefaults.standard.double(forKey: "scanner.motionThreshold"))
        return value > 0 ? value : nil
    }

    static func overriddenSettleDelay() -> TimeInterval? {
        guard UserDefaults.standard.object(forKey: "scanner.settleDelay") != nil else { return nil }
        let value = UserDefaults.standard.double(forKey: "scanner.settleDelay")
        return value > 0 ? value : nil
    }

    /// The same lever for the corner-stability threshold, and for the same
    /// reason: the number in `defaultCornerStabilityThreshold` is a guess until
    /// someone can change it while pointed at a page.
    static func overriddenCornerThreshold() -> Double? {
        guard UserDefaults.standard.object(forKey: "scanner.cornerThreshold") != nil else { return nil }
        let value = UserDefaults.standard.double(forKey: "scanner.cornerThreshold")
        return value > 0 ? value : nil
    }

    /// The lever for the document trigger's own threshold, which is the one
    /// number in this file measured against a single recording — see
    /// `defaultDocumentStabilityThreshold`'s TODO. A too-tight value here is
    /// exactly the bug that made document scanning never fire, so being able to
    /// walk it up and down in front of a real page matters more here than
    /// anywhere else: `-scanner.documentThreshold 0.03`.
    static func overriddenDocumentThreshold() -> Double? {
        guard UserDefaults.standard.object(forKey: "scanner.documentThreshold") != nil else { return nil }
        let value = UserDefaults.standard.double(forKey: "scanner.documentThreshold")
        return value > 0 ? value : nil
    }
    #endif

    // MARK: State

    private(set) var state: State = .settled
    /// When the scene was last seen moving. The settle window is measured from
    /// here, so any motion at all restarts it.
    private var lastMotionAt: Date?
    /// Whether the opening frame has been handed out yet.
    private var hasFiredFirstPose = false
    /// The most recent measurement, for the HUD.
    private(set) var lastMagnitude: Float = 0
    /// Every corner sample since the last disturbance, pruned to the settle
    /// window — "the last N frames" the stability test looks back over, kept as
    /// times rather than a count for the same reason the settle delay is wall
    /// clock: the preview's frame rate is not a constant.
    private var cornerSamples: [(time: Date, quad: NormalizedQuad)] = []
    /// Whether the last measurement had a rectangle in it — under the motion
    /// trigger, which of the two settle signals is deciding; under the rectangle
    /// trigger, simply whether there is a page in view.
    private(set) var isTrackingRectangle = false
    /// The rectangle trigger has nothing flat to photograph. Drawn by the HUD: a
    /// camera that is deliberately not firing has to say why, or the shoot reads
    /// as one that has hung.
    private(set) var isWaitingForRectangle = false
    /// When the current hold window began — the rectangle trigger's clock.
    private var holdStartedAt: Date?
    /// The quad the hold window is measured against. Held rather than compared
    /// pairwise so slow drift accumulates: a page creeping a millimetre a tick
    /// passes every frame-to-frame test and fails this one, which is the whole
    /// point of a window.
    private var holdReference: NormalizedQuad?
    /// When the rectangle was first missing, in the run of missing samples the
    /// engine is currently in. Nil whenever a page is in view. **The absence
    /// clock**: the only thing that re-arms a document run.
    private var absentSince: Date?
    /// When the last pose was taken, so the shutter's own dropout doesn't read
    /// as the page being removed. See `defaultPostCaptureBlanking`.
    private var capturedAt: Date?
    /// Whether anything has **visibly happened** since the last capture — the
    /// other half of "the page was removed", and the half that was missing.
    ///
    /// A page being lifted is a large visual event: a hand comes in, a whole
    /// sheet leaves, the desk appears. A detector losing a page it is still
    /// looking at is not an event at all. Measured on device (2026-08-17), a
    /// full re-capture cycle ran with the frame difference at 0.0014–0.0019
    /// against a 0.028 threshold — 15× below it — so nothing in that scene
    /// moved and the sheet was photographed again anyway.
    private var sceneChangedSinceCapture = false
    /// The last transition the machine refused, for the camera to log. Kept as a
    /// string rather than reported through a logger so the engine stays free of
    /// app dependencies and can be driven by a bare harness.
    private(set) var lastRejectedTransition: String?

    init(
        settleDelay: TimeInterval = ScannerEngine.defaultSettleDelay,
        motionThreshold: Float = ScannerEngine.defaultMotionThreshold,
        cornerStabilityThreshold: Double = ScannerEngine.defaultCornerStabilityThreshold,
        documentStabilityThreshold: Double = ScannerEngine.defaultDocumentStabilityThreshold,
        pageAbsenceDelay: TimeInterval = ScannerEngine.defaultPageAbsenceDelay,
        postCaptureBlanking: TimeInterval = ScannerEngine.defaultPostCaptureBlanking,
        trigger: Trigger = .motion
    ) {
        self.trigger = trigger
        self.pageAbsenceDelay = pageAbsenceDelay
        self.postCaptureBlanking = postCaptureBlanking
        var resolvedDelay = settleDelay
        var resolvedThreshold = motionThreshold
        var resolvedCornerThreshold = cornerStabilityThreshold
        var resolvedDocumentThreshold = documentStabilityThreshold
        #if DEBUG
        resolvedDelay = ScannerEngine.overriddenSettleDelay() ?? resolvedDelay
        resolvedThreshold = ScannerEngine.overriddenThreshold() ?? resolvedThreshold
        resolvedCornerThreshold = ScannerEngine.overriddenCornerThreshold() ?? resolvedCornerThreshold
        resolvedDocumentThreshold = ScannerEngine.overriddenDocumentThreshold() ?? resolvedDocumentThreshold
        #endif
        self.cornerStabilityThreshold = resolvedCornerThreshold
        self.documentStabilityThreshold = resolvedDocumentThreshold
        // The delay is clamped to the range the UI will eventually offer; the
        // threshold deliberately isn't, because tuning it means being able to
        // go absurdly low on purpose and watch what fires.
        self.settleDelay = min(max(resolvedDelay, ScannerEngine.settleDelayRange.lowerBound),
                               ScannerEngine.settleDelayRange.upperBound)
        self.motionThreshold = resolvedThreshold
    }

    /// Arms the engine for a run, and — under the motion trigger — asks for the
    /// opening frame.
    ///
    /// **Motion:** the first pose is already framed, because the operator set it
    /// up before pressing the shutter, so it is captured immediately rather than
    /// made to wait for a disturb/re-settle cycle that would require them to
    /// touch a scene they had just finished arranging. Returns `true`, which the
    /// caller treats exactly like any other fire signal, so the opening frame
    /// goes through the same steadiness gate and the same capture path as every
    /// frame after it.
    ///
    /// **Rectangle:** returns `false` and opens on `waitingForPage`. There is
    /// nothing to photograph yet — the tap has only just been attached and the
    /// desk may be empty — and "the first pose is already framed" is an
    /// assumption about a turntable, not about a document shoot. A page already
    /// lying still in front of the camera is photographed as soon as the hold
    /// window it opens completes, which is a second later and correct, rather
    /// than instantly and possibly of a bare desk.
    @discardableResult
    func start(at time: Date) -> Bool {
        lastMotionAt = nil
        lastMagnitude = 0
        cornerSamples = []
        isTrackingRectangle = false
        isWaitingForRectangle = false
        holdStartedAt = nil
        holdReference = nil
        absentSince = nil
        capturedAt = nil
        sceneChangedSinceCapture = false
        lastRejectedTransition = nil
        hasFiredFirstPose = true
        switch trigger {
        case .motion:
            state = .settled
            return true
        case .rectangle:
            state = .waitingForPage
            isWaitingForRectangle = true
            return false
        }
    }

    /// One frame's worth of everything the camera can say about the scene: how
    /// different it is from the last frame, and where the flat object in it is
    /// — if there is one. Returns "the shutter should go".
    ///
    /// Which question that answers is `trigger`'s to decide, and the two are
    /// genuinely different machines rather than one with a filter on it:
    ///
    /// - **motion** — has the scene been disturbed and gone still again? A quad,
    ///   when there is one, sharpens the *settle* half of that test: four
    ///   corners standing still is a measurement of the object rather than of
    ///   the frame, so it sees a page creeping a millimetre a second, which a
    ///   frame difference averages into nothing, and ignores a shadow crossing
    ///   the desk, which a frame difference reads as motion. Anything disturbs
    ///   and only corners settle, deliberately: a hand crossing the frame, or a
    ///   page swapped for another in the same place, moves the frame without
    ///   moving the corners and should restart the window.
    /// - **rectangle** — is there a page, and is it holding still? Motion plays
    ///   no part. See `observePage`.
    @discardableResult
    func observe(magnitude: Float, quad: NormalizedQuad?, at time: Date) -> Bool {
        lastMagnitude = magnitude
        switch trigger {
        case .rectangle:
            return observePage(magnitude: magnitude, quad: quad, at: time)
        case .motion:
            return observeMotion(magnitude: magnitude, quad: quad, at: time)
        }
    }

    /// Moves the document machine, or refuses to.
    ///
    /// Every rectangle-state change goes through here, which is the only reason
    /// the order in `legalPageTransitions` is a guarantee rather than a habit. A
    /// refused move leaves the state exactly as it was — a machine that has lost
    /// track of itself should stall visibly, in a state the HUD can name, rather
    /// than take a photograph it cannot justify.
    @discardableResult
    private func transition(to next: State) -> Bool {
        guard next != state else { return true }
        guard Self.legalPageTransitions[state]?.contains(next) == true else {
            // Recorded, never fatal. This ships in a Debug build that is being
            // used to scan real documents, and an assertion that trips mid-set
            // would take the shoot with it — the refusal is the enforcement,
            // and `CameraController` prints `REJECTED=…` so a field run says so.
            lastRejectedTransition = "\(state.rawValue)→\(next.rawValue)"
            return false
        }
        state = next
        isWaitingForRectangle = next == .waitingForPage
        return true
    }

    /// The **rectangle** trigger: a page, holding still, for the length of the
    /// window. No motion anywhere in it.
    ///
    /// Returns "the shutter should go now", and says so on every tick it remains
    /// true rather than on one edge — because the caller can refuse. A device
    /// that isn't steady enough vetoes the pose (see
    /// `CameraController.scannerDeviceIsSteady`), and a vetoed pose must not be
    /// silently lost: nothing here is committed until the caller confirms with
    /// `didCapture`, so the next steady tick takes the same page.
    private func observePage(magnitude: Float, quad: NormalizedQuad?, at time: Date) -> Bool {
        guard hasFiredFirstPose else { return false }

        // The shutter is itself a visual event and a detector dropout: the
        // preview stutters, AE steps, a hand comes back into frame. For as long
        // as the blanking lasts, neither signal below is evidence of anything.
        let blanked = capturedAt.map { time.timeIntervalSince($0) < postCaptureBlanking } ?? false
        if state == .captured, !blanked, magnitude > motionThreshold {
            sceneChangedSinceCapture = true
        }

        guard let quad else {
            isTrackingRectangle = false
            // **A missing rectangle is not a removed page.** The detector blinks
            // — measured at roughly every other sample over a sheet that never
            // moved, for stretches well past `pageAbsenceDelay` — so absence is
            // a duration rather than a sample, and even a long one is only half
            // the test.
            if blanked {
                absentSince = nil
                return false
            }
            let since = absentSince ?? time
            absentSince = since
            let gone = time.timeIntervalSince(since) >= pageAbsenceDelay
            guard gone else { return false }

            if state == .captured {
                // **Both signals, or nothing.** The page is out of sight AND
                // something visibly happened while it went. A blinking detector
                // over a still desk supplies the first and never the second,
                // which is exactly the run that photographed one sheet four
                // times: 0.0014 magnitude throughout, 15× under the threshold.
                guard sceneChangedSinceCapture else { return false }
                capturedAt = nil
                sceneChangedSinceCapture = false
            }
            holdStartedAt = nil
            holdReference = nil
            transition(to: .waitingForPage)
            return false
        }

        isTrackingRectangle = true
        absentSince = nil

        // A page already banked stays banked, however still it is and however
        // long it lies there. Nothing on this side of the branch can fire again:
        // only a removal re-arms the run, and a removal has to be *seen*
        // happening. Three earlier rules all failed here — a time cooldown, a
        // corner-jump test, and absence on its own.
        if state == .captured { return false }

        // Hold window: measured against the quad it started with, so slow drift
        // accumulates into a restart instead of passing frame by frame.
        guard let reference = holdReference, let started = holdStartedAt,
              reference.maxCornerDistance(to: quad) <= documentStabilityThreshold else {
            holdReference = quad
            holdStartedAt = time
            transition(to: .holding)
            return false
        }
        transition(to: .holding)
        // The fire signal is only ever raised from `holding`, which is what
        // makes "no capture without a completed window" structural: `didCapture`
        // refuses from anywhere else.
        return state == .holding && time.timeIntervalSince(started) >= settleDelay
    }

    /// The **motion** trigger — the Phase 1 machine, unchanged, with the corner
    /// path as its stronger settle signal when a quad happens to be there.
    private func observeMotion(magnitude: Float, quad: NormalizedQuad?, at time: Date) -> Bool {
        guard let quad else {
            cornerSamples = []
            isTrackingRectangle = false
            isWaitingForRectangle = false
            return motionMagnitude(magnitude, at: time)
        }

        isTrackingRectangle = true
        isWaitingForRectangle = false
        guard hasFiredFirstPose else { return false }

        let cornersMoved = cornerSamples.last
            .map { $0.quad.maxCornerDistance(to: quad) > cornerStabilityThreshold } ?? false
        cornerSamples.append((time: time, quad: quad))
        // The window is the settle delay, so a scene that has been still for a
        // minute holds a second's worth of samples, not a minute's.
        cornerSamples.removeAll { time.timeIntervalSince($0.time) > settleDelay }

        if magnitude > motionThreshold || cornersMoved {
            state = .disturbed
            lastMotionAt = time
            cornerSamples = [(time: time, quad: quad)]
            return false
        }

        guard state == .disturbed, let since = lastMotionAt else { return false }
        guard time.timeIntervalSince(since) >= settleDelay else { return false }
        // Every sample in the window against the newest, not just the newest
        // against the one before it: a page sliding slower than the per-frame
        // threshold passes that test on every frame and fails this one, which
        // is precisely the drift the corner path exists to catch.
        guard cornerSamples.allSatisfy({
            $0.quad.maxCornerDistance(to: quad) <= cornerStabilityThreshold
        }) else { return false }

        state = .settled
        lastMotionAt = nil
        cornerSamples = [(time: time, quad: quad)]
        return true
    }

    /// Folds one motion measurement into the machine. Returns `true` on the
    /// single tick where the scene has just finished re-settling — the caller's
    /// cue to fire.
    ///
    /// This is the frame-differencing path: the whole story in Phase 1, and the
    /// fallback since — `observe(magnitude:quad:at:)` is what the camera calls
    /// now, and it comes here whenever there is no rectangle to watch instead.
    ///
    /// Note what this does *not* do: it never gates on the device being steady.
    /// That is a second, independent signal (`SteadinessMonitor`) and the caller
    /// requires both, because a still scene shot from a wobbling phone is a
    /// blurred frame that a solver will happily accept and then reconstruct
    /// badly. Keeping the two apart means neither can mask the other.
    @discardableResult
    func motionMagnitude(_ value: Float, at time: Date) -> Bool {
        lastMagnitude = value
        guard hasFiredFirstPose else { return false }

        if value > motionThreshold {
            state = .disturbed
            lastMotionAt = time
            return false
        }

        // Below threshold. Only a scene that was disturbed can re-settle;
        // a quiet scene that was already settled has nothing to report.
        guard state == .disturbed, let since = lastMotionAt else { return false }
        guard time.timeIntervalSince(since) >= settleDelay else { return false }

        // reSettled is passed through rather than rested in: the frame about to
        // be taken is this pose, so the engine is already waiting for the next
        // disturbance by the time the caller sees the signal.
        state = .settled
        lastMotionAt = nil
        return true
    }

    /// The frame asked for by the last `true` from `observe` has been taken.
    ///
    /// The rectangle trigger needs telling, because it is the only one that
    /// holds a *state* about the page it just photographed — and because the
    /// caller can refuse a fire (an unsteady device vetoes the pose). Nothing is
    /// committed inside `observe`, so a vetoed pose keeps the window satisfied
    /// and the same page is taken as soon as the phone is still. Confirming is
    /// what starts the cooldown and what makes this page "banked" until it
    /// changes.
    ///
    /// A no-op under the motion trigger, whose own fire path has already moved
    /// the machine on — there, a vetoed pose comes round again with the next
    /// disturbance, which is the operator's next move anyway.
    func didCapture(at time: Date) {
        guard trigger == .rectangle else { return }
        // Structural, not defensive: a pose that did not come out of a
        // completed hold window is a pose nothing asked for, and banking it
        // would let `captured` appear before `holding` — the ordering the HUD
        // was reported showing. Refused and recorded instead.
        guard state == .holding else {
            lastRejectedTransition = "didCapture from \(state.rawValue)"
            return
        }
        capturedAt = time
        absentSince = nil
        sceneChangedSinceCapture = false
        holdStartedAt = nil
        holdReference = nil
        transition(to: .captured)
    }

    /// How far through the current window the run is, 0…1 — the progress the HUD
    /// draws. Nil when nothing is running towards a shot.
    ///
    /// One number for both triggers because it means the same thing in both: how
    /// much of the wait is done. Under motion that is the settle window since the
    /// last disturbance; under the rectangle trigger it is the hold window since
    /// the page last moved.
    func settleProgress(at time: Date) -> Double? {
        switch trigger {
        case .motion:
            guard state == .disturbed, let since = lastMotionAt else { return nil }
            return min(max(time.timeIntervalSince(since) / settleDelay, 0), 1)
        case .rectangle:
            guard state == .holding, let since = holdStartedAt else { return nil }
            return min(max(time.timeIntervalSince(since) / settleDelay, 0), 1)
        }
    }

    /// Ends the run. A stopped engine fires nothing — `start` is the only thing
    /// that re-arms it.
    func stop() {
        state = trigger == .rectangle ? .waitingForPage : .settled
        lastMotionAt = nil
        hasFiredFirstPose = false
        lastMagnitude = 0
        cornerSamples = []
        isTrackingRectangle = false
        isWaitingForRectangle = false
        holdStartedAt = nil
        holdReference = nil
        absentSince = nil
        capturedAt = nil
        sceneChangedSinceCapture = false
    }
}

// MARK: - Measurement

#if os(iOS)

/// Turns the preview stream into the single scalar `ScannerEngine` consumes:
/// the mean absolute difference between consecutive frames, normalised to 0…1.
///
/// **Why it downsamples first, and hard.** Frame differencing answers "did
/// anything in this scene move", which is a question about the whole frame, not
/// about detail. A 64×48 thumbnail answers it as well as 4032×3024 does, costs
/// four thousand times less arithmetic, and — the part that matters more —
/// *averages sensor noise away for free*, so the threshold can sit near where
/// real motion starts instead of above where noise ends. Downsampling is the
/// noise filter here, not just the optimisation.
///
/// Luma only, from the green-ish middle of BGRA: a colour difference buys
/// nothing for "did it move" and triples the work.
///
/// iOS-only, and not by omission — this rides an `AVCaptureVideoDataOutput`
/// tap, and macOS's capture screen has no such preview path (nor manual
/// exposure to lock, which Scanner requires; see `startScanner`).
final class ScannerMotionAnalyzer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    /// The grid the difference is computed on. 64×48 is 4:3, which every
    /// still-capture format the app runs the Scanner in already is, so the
    /// sampling grid never distorts the frame it measures.
    static let gridWidth = 64
    static let gridHeight = 48

    /// The tap's own queue, matching the other preview taps in
    /// `CameraController` (test card, Watch framing).
    let queue = DispatchQueue(label: "letslapse.scanner.motion")

    /// Called on `queue` with each new magnitude, the flat object in frame (if
    /// any) and the wall-clock moment both describe. The camera hops to its
    /// session queue from here.
    ///
    /// The pair travels together rather than as two callbacks because the
    /// engine folds them into one decision: they must describe the same
    /// instant, or a settle could be judged against a rectangle seen half a
    /// second ago.
    var onSample: ((Float, NormalizedQuad?, Date) -> Void)?

    /// Finds the page/document/print, when there is one. Owned by the camera
    /// (which keeps its orientation current) and driven from here, off the same
    /// frames the differencing uses — one tap, two questions. Nil leaves the
    /// analyzer in its Phase 1 behaviour exactly.
    var rectangleDetector: RectangleDetector?

    /// Previous frame's luma grid. Nil until the second frame — the first has
    /// nothing to be different from and is skipped rather than reported as a
    /// full-frame change, which would open every run with a false disturb.
    private var previous: [Float]?

    /// Ceiling on how often frames are measured. The preview can deliver 30–60
    /// a second and the settle window is a full second wide, so 20 Hz is a
    /// generous sampling of it and leaves the camera's queue alone the rest of
    /// the time.
    private static let minimumSampleInterval: TimeInterval = 0.05
    private var lastSampledAt = Date.distantPast

    /// Drops the frame history, so the next frame starts a fresh comparison.
    /// Called when a run starts and when the session reconfigures (a lens or
    /// format change moves every pixel and would otherwise read as motion).
    func reset() {
        queue.async {
            self.previous = nil
            self.rectangleDetector?.reset()
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = Date()
        guard now.timeIntervalSince(lastSampledAt) >= Self.minimumSampleInterval,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastSampledAt = now
        // Detection first, and synchronously, while the sample buffer still
        // guarantees these pixels: the quad it produces has to describe the
        // same frame the difference below does.
        rectangleDetector?.detect(in: buffer, at: now)
        guard let grid = Self.lumaGrid(from: buffer) else { return }
        defer { previous = grid }
        guard let previous, previous.count == grid.count else { return }

        var sum: Float = 0
        for index in 0..<grid.count {
            sum += abs(grid[index] - previous[index])
        }
        let magnitude = sum / Float(grid.count)
        onSample?(magnitude, rectangleDetector?.quad(at: now), now)
    }

    /// Point-samples a BGRA pixel buffer down to the fixed grid, returning
    /// luma in 0…1.
    ///
    /// Point sampling rather than box-averaging is deliberate: an averaging
    /// resample would blur away exactly the small, high-contrast changes (a
    /// hand's edge crossing the frame) that this is trying to detect, and the
    /// grid is already coarse enough that noise averages out across the *sum*
    /// over 3,072 cells even though no single cell is averaged.
    private static func lumaGrid(from buffer: CVPixelBuffer) -> [Float]? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else {
            return nil
        }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard width >= gridWidth, height >= gridHeight else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)

        var grid = [Float](repeating: 0, count: gridWidth * gridHeight)
        for gridY in 0..<gridHeight {
            let sourceY = gridY * height / gridHeight
            let row = pixels.advanced(by: sourceY * bytesPerRow)
            for gridX in 0..<gridWidth {
                let sourceX = gridX * width / gridWidth
                let pixel = row.advanced(by: sourceX * 4)
                // BGRA. Rec. 601 luma weights — the differencing only needs a
                // perceptually sane scalar, not a colour-managed one.
                let blue = Float(pixel[0])
                let green = Float(pixel[1])
                let red = Float(pixel[2])
                grid[gridY * gridWidth + gridX] =
                    (0.299 * red + 0.587 * green + 0.114 * blue) / 255
            }
        }
        return grid
    }
}

#endif
