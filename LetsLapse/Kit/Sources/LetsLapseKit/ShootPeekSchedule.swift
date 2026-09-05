import Foundation

/// What a scheduled peek counts against.
///
/// Two genuinely different questions, which is why this is a mode and not a
/// value. `interval` counts from the moment the shoot started, so a peek
/// always lands a whole period after the shutter opened. `clock` aligns to
/// the wall clock, so "every 5 minutes" means :00, :05, :10 whatever time the
/// run began — one rule the operator learns once, and one that makes every
/// camera in a fleet light up together.
public enum ShootPeekTrigger: String, Sendable, CaseIterable, Codable {
    case interval
    case clock

    public static let defaultTrigger: ShootPeekTrigger = .clock
}

/// When the blackout next lifts for a look.
///
/// Pure arithmetic with an injected `now`, like `HolyGrailAutoInterval` beside
/// it: the point of a schedule is that it can be reasoned about without a
/// camera, a clock or a running shoot.
public enum ShootPeekSchedule {

    /// How long the card stays up once a peek fires.
    public static let peekSeconds: TimeInterval = 15

    /// The periods the Settings row offers, in minutes. Each divides 60, which
    /// is what lets `clock` walk the grid by adding whole periods to the top
    /// of the hour without drifting off it.
    public static let everyMinutesChoices = [5, 10, 15]
    public static let defaultEveryMinutes = 5

    /// A peek this soon after the shutter opened is skipped.
    ///
    /// Only `clock` can produce one — a run started at 3:14:50 would otherwise
    /// flash its first card ten seconds in, which reads as a fault rather than
    /// as the schedule working. `interval`'s first candidate is a whole period
    /// out and can never be inside the window, but the rule is applied to both
    /// so there is one thing to remember rather than two.
    public static let openingGrace: TimeInterval = 60

    /// The next peek strictly after `now`, or nil if the period is nonsense.
    ///
    /// Strictly after: called at the instant a peek fires, this returns the one
    /// *following* it, which is what the card's footer needs to name.
    public static func next(
        after now: Date,
        runStartedAt: Date,
        trigger: ShootPeekTrigger,
        everyMinutes: Int,
        calendar: Calendar = .current
    ) -> Date? {
        guard everyMinutes > 0 else { return nil }
        let period = TimeInterval(everyMinutes * 60)
        let earliest = runStartedAt.addingTimeInterval(openingGrace)

        var candidate: Date
        switch trigger {
        case .interval:
            // Whole periods from the start, never the start itself: a run that
            // has only just begun is one period away from its first look.
            let elapsed = now.timeIntervalSince(runStartedAt)
            let steps = max(1.0, (elapsed / period).rounded(.down) + 1)
            candidate = runStartedAt.addingTimeInterval(steps * period)
        case .clock:
            // From the top of the hour rather than from midnight, so the walk
            // is bounded (at most twelve steps at 5 minutes) and so a DST
            // shift — which lands on an hour boundary — cannot skew the grid.
            guard let hourStart = calendar.dateInterval(of: .hour, for: now)?.start else {
                return nil
            }
            candidate = hourStart
            while candidate <= now { candidate.addTimeInterval(period) }
        }

        while candidate < earliest { candidate.addTimeInterval(period) }
        return candidate
    }
}
