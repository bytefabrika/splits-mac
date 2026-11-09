import XCTest
@testable import Splits

final class StreakTests: XCTestCase {
    var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    func date(_ s: String) -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.date(from: s + " 08:00")!
    }

    func testDays() {
        // Mon 2 Nov 2026 is "today"; ran Sat, Sun (twice), and an older 4-day run.
        let s = Streaks(dates: ["2026-10-31", "2026-11-01", "2026-11-01", "2026-10-20", "2026-10-21", "2026-10-22", "2026-10-23"].map(date),
                        today: date("2026-11-02"), calendar: calendar)
        XCTAssertEqual(s.currentDays, 2)  // today not yet, so the streak runs to yesterday
        XCTAssertEqual(s.longestDays, 4)
        XCTAssertEqual(s.longestDaysEnd, calendar.startOfDay(for: date("2026-10-23")))
    }

    func testWeeks() {
        // Three weeks with 3 runs each, then this week with 1.
        let runs = ["2026-10-12", "2026-10-14", "2026-10-16",
                    "2026-10-19", "2026-10-20", "2026-10-25",
                    "2026-10-26", "2026-10-28", "2026-10-30",
                    "2026-11-02"].map(date)
        let s = Streaks(dates: runs, today: date("2026-11-03"), calendar: calendar)
        XCTAssertEqual(s.thisWeek, 1)
        XCTAssertEqual(s.currentWeeks, 3)
        XCTAssertEqual(s.longestWeeks, 3)
        XCTAssertEqual(s.bestWeek, 3)
        XCTAssertEqual(Streaks(dates: runs + [date("2026-11-03"), date("2026-11-03")], today: date("2026-11-03"), calendar: calendar).currentWeeks, 4)
    }

    func testPlausible() {
        XCTAssertTrue(Records.plausible(distance: 1000, seconds: 180))
        XCTAssertFalse(Records.plausible(distance: 1000, seconds: 120))  // 2:00 /km: a GPS jump
    }
}
