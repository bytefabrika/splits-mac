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

final class RacePredictorTests: XCTestCase {
    func testRiegel() {
        let now = Date()
        let recent = now.addingTimeInterval(-10 * 86_400)
        let p = RacePredictor(efforts: [(1, recent, "10 km", 3000), (2, recent, "5 km", 1500), (3, recent, "1 km", 200)], now: now)
        XCTAssertEqual(p.months, 4)
        let byLabel = Dictionary(uniqueKeysWithValues: p.predictions.map { ($0.label, $0) })
        // 5 km in 25:00 predicts a 10 km of 25:00 × 2^1.06 ≈ 52:08, slower than the 50:00 run, so the 10 km wins.
        XCTAssertEqual(byLabel["10 km"]!.seconds, 3000, accuracy: 0.1)
        XCTAssertEqual(byLabel["5 km"]!.seconds, 3000 * pow(0.5, 1.06), accuracy: 0.1)
        XCTAssertEqual(byLabel["Half"]!.source.label, "10 km")
        // The 1 km never counts.
        XCTAssertFalse(p.predictions.contains { $0.source.label == "1 km" })
    }

    func testFallsBackToAYear() {
        let old = Date().addingTimeInterval(-200 * 86_400)
        let p = RacePredictor(efforts: [(1, old, "10 km", 3000)])
        XCTAssertEqual(p.months, 12)
        XCTAssertNil(RacePredictor(efforts: [(1, old, "5 km", 1500)]).predictions.first { $0.label == "Marathon" })
    }
}
