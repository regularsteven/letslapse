import XCTest
@testable import LetsLapseKit

/// The scheduled peek's arithmetic, pinned. No camera, no clock, no run —
/// the whole point of the schedule being a pure function.
final class ShootPeekScheduleTests: XCTestCase {

    /// A fixed calendar so the clock grid is reproducible wherever this runs.
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Prague")!
        return calendar
    }()

    private func date(_ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 5
        components.hour = hour; components.minute = minute; components.second = second
        components.timeZone = calendar.timeZone
        return calendar.date(from: components)!
    }

    private func next(
        _ trigger: ShootPeekTrigger,
        every: Int = 5,
        started: Date,
        now: Date
    ) -> Date? {
        ShootPeekSchedule.next(
            after: now, runStartedAt: started, trigger: trigger,
            everyMinutes: every, calendar: calendar)
    }

    // MARK: - Interval

    func testIntervalFirstPeekIsOnePeriodAfterTheStart() {
        let started = date(3, 14, 50)
        XCTAssertEqual(next(.interval, started: started, now: started), date(3, 19, 50))
    }

    func testIntervalWalksInWholePeriodsFromTheStart() {
        let started = date(3, 14, 50)
        // Mid-run, twelve and a bit minutes in: the next multiple of five.
        XCTAssertEqual(next(.interval, started: started, now: date(3, 27, 3)), date(3, 29, 50))
    }

    /// Called at the instant a peek fires, the answer is the one after it —
    /// which is the number the card's footer prints.
    func testIntervalIsStrictlyAfterNow() {
        let started = date(3, 14, 50)
        XCTAssertEqual(next(.interval, started: started, now: date(3, 19, 50)), date(3, 24, 50))
    }

    func testIntervalHonoursTheChosenPeriod() {
        let started = date(3, 0)
        XCTAssertEqual(next(.interval, every: 10, started: started, now: date(3, 4)), date(3, 10))
        XCTAssertEqual(next(.interval, every: 15, started: started, now: date(3, 4)), date(3, 15))
    }

    // MARK: - Clock

    /// The whole reason the mode exists: the grid does not care when the run
    /// began.
    func testClockAlignsToTheHourWhateverTimeTheRunStarted() {
        let started = date(3, 14, 50)
        XCTAssertEqual(next(.clock, started: started, now: date(3, 16)), date(3, 20))
        // A different start, the same answer.
        XCTAssertEqual(next(.clock, started: date(2, 3, 12), now: date(3, 16)), date(3, 20))
    }

    func testClockIsStrictlyAfterNowOnTheGrid() {
        XCTAssertEqual(next(.clock, started: date(3, 0), now: date(3, 20)), date(3, 25))
    }

    func testClockCrossesTheHour() {
        XCTAssertEqual(next(.clock, started: date(3, 0), now: date(3, 57, 30)), date(4, 0))
    }

    func testClockGridFollowsThePeriod() {
        XCTAssertEqual(next(.clock, every: 10, started: date(3, 0), now: date(3, 16)), date(3, 20))
        XCTAssertEqual(next(.clock, every: 15, started: date(3, 0), now: date(3, 16)), date(3, 30))
    }

    // MARK: - The opening grace

    /// A run started at 3:14:50 must not flash its first card ten seconds in.
    func testClockSkipsAPeekInsideTheFirstMinute() {
        let started = date(3, 14, 50)
        XCTAssertEqual(next(.clock, started: started, now: started), date(3, 20))
    }

    /// The boundary itself: a peek exactly 60 s after the start is allowed —
    /// the grace is "inside the first minute", not "the first minute and one".
    func testAPeekExactlyAtTheGraceBoundaryStands() {
        let started = date(3, 14)
        XCTAssertEqual(next(.clock, started: started, now: started), date(3, 15))
    }

    func testIntervalIsNeverAffectedByTheGrace() {
        // One period is always well past 60 s, so the grace can never bite.
        let started = date(3, 14, 50)
        XCTAssertEqual(next(.interval, started: started, now: started), date(3, 19, 50))
    }

    // MARK: - Guards

    func testANonsensePeriodHasNoSchedule() {
        XCTAssertNil(next(.clock, every: 0, started: date(3, 0), now: date(3, 1)))
        XCTAssertNil(next(.interval, every: -5, started: date(3, 0), now: date(3, 1)))
    }

    /// A schedule asked about before its run has begun still answers, rather
    /// than handing back the start instant itself.
    func testAQuestionAskedBeforeTheRunStartsStillMovesForward() {
        let started = date(3, 14, 50)
        let answer = next(.interval, started: started, now: date(3, 10))
        XCTAssertEqual(answer, date(3, 19, 50))
    }

    func testTheOfferedPeriodsAllDivideTheHour() {
        for minutes in ShootPeekSchedule.everyMinutesChoices {
            XCTAssertEqual(60 % minutes, 0, "\(minutes)m would drift off the clock grid")
        }
    }
}
