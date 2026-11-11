import SwiftUI
import XCTest
@testable import Splits

@MainActor
final class HealthTests: XCTestCase {
    private let calendar = Calendar.current

    private func day(_ offset: Int, from start: Date = Date(timeIntervalSince1970: 1_790_000_000)) -> Day {
        let date = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: start))!
        return Day(date: GarminDate.string(date))
    }

    // MARK: HRV

    func testNormalRangeAndLevel() {
        // 70 steady mornings around 60 ms, then a week at 40 ms: the 7-day average falls below the range.
        let days = (0..<77).map { i -> Day in
            let d = day(i)
            d.hrvLastNight = i < 70 ? (i % 2 == 0 ? 58 : 62) : 40
            return d
        }
        let series = HRVAnalysis.series(HRVAnalysis.mornings(days))
        let last = try! XCTUnwrap(series.last)
        XCTAssertEqual(last.meanMs, 40, accuracy: 0.5)
        XCTAssertEqual(HRVAnalysis.level(last), .below)
        let before = try! XCTUnwrap(series.first { $0.date == days[69].day })
        XCTAssertEqual(HRVAnalysis.level(before), .within)
        XCTAssertEqual(before.lowMs!, 59, accuracy: 1.5)
        XCTAssertEqual(before.highMs!, 61, accuracy: 1.5)
    }

    func testNoRangeWithoutSixtyDays() {
        let days = (0..<10).map { i -> Day in let d = day(i); d.hrvLastNight = 50 + i; return d }
        let series = HRVAnalysis.series(HRVAnalysis.mornings(days))
        XCTAssertFalse(series.isEmpty)
        XCTAssertNil(HRVAnalysis.level(series.last!))
        XCTAssertEqual(Coach.hrvAssessment(days: days, activities: [])?.verdict, "Still learning your normal")
    }

    func testDriversFindHardDays() {
        // HRV is 20% lower the morning after every hard session.
        var activities: [Activity] = []
        let days = (0..<120).map { i -> Day in
            let d = day(i)
            d.hrvLastNight = i % 4 == 1 ? 48 : 60
            return d
        }
        for i in stride(from: 0, to: 120, by: 4) {
            let a = Activity(garminId: Int64(i))
            a.start = days[i].day.addingTimeInterval(18 * 3600)
            a.trainingLoad = 200
            activities.append(a)
        }
        for i in stride(from: 2, to: 120, by: 4) {
            let a = Activity(garminId: Int64(1000 + i))
            a.start = days[i].day.addingTimeInterval(18 * 3600)
            a.trainingLoad = 40
            activities.append(a)
        }
        let drivers = HRVAnalysis.drivers(days: days, activities: activities)
        let hard = try! XCTUnwrap(drivers.first { $0.label == "Hard day" })
        let rest = try! XCTUnwrap(drivers.first { $0.label == "Rest day" })
        XCTAssertLessThan(hard.percent, -10)
        XCTAssertGreaterThan(rest.percent, 0)
    }

    // MARK: Sleep

    private func night(_ offset: Int, bed: Double, wake: Double, need: Int? = 480) -> Day {
        let d = day(offset)
        let midnight = d.day
        d.sleepStart = midnight.addingTimeInterval(bed * 3600)
        d.sleepEnd = midnight.addingTimeInterval(wake * 3600)
        d.sleepSeconds = Int((wake - bed) * 3600)
        d.deepSeconds = d.sleepSeconds! / 5
        d.remSeconds = d.sleepSeconds! / 5
        d.lightSeconds = d.sleepSeconds! * 3 / 5
        d.sleepNeedMinutes = need
        return d
    }

    func testBedtimeAndWakeAroundMidnight() {
        let n = SleepAnalysis.nights([night(0, bed: -0.5, wake: 7.25)]).first!
        XCTAssertEqual(n.bedtime, -0.5, accuracy: 0.001)
        XCTAssertEqual(n.wake, 7.25, accuracy: 0.001)
        XCTAssertEqual(SleepAnalysis.clock(n.bedtime), "23:30")
        XCTAssertEqual(SleepAnalysis.clock(n.wake), "07:15")
    }

    func testSocialJetlagAndChronotype() {
        // Weekdays 23:00–07:00 (mid-sleep 03:00), weekends 01:00–10:00 (mid-sleep 05:30).
        let days = (0..<28).map { i -> Day in
            let weekday = calendar.component(.weekday, from: day(i).day)
            return weekday == 1 || weekday == 7 ? night(i, bed: 1, wake: 10) : night(i, bed: -1, wake: 7)
        }
        let clock = try! XCTUnwrap(SleepAnalysis.bodyClock(SleepAnalysis.nights(days)))
        XCTAssertEqual(clock.workdays, 3, accuracy: 0.01)
        XCTAssertEqual(clock.freeDays, 5.5, accuracy: 0.01)
        XCTAssertEqual(clock.socialJetlag, 2.5, accuracy: 0.01)
        // MSFsc = 5.5 − (9 − (5×8 + 2×9)/7) / 2 ≈ 5.14
        XCTAssertEqual(clock.chronotype, 5.5 - (9 - 58.0 / 7) / 2, accuracy: 0.01)
        XCTAssertEqual(clock.label, "Night owl")
    }

    func testDebtAddsUpAndLongNightsPayBack() {
        let now = day(14).day.addingTimeInterval(12 * 3600)
        // Ten 7-hour nights against an 8-hour need: 10 hours owed.
        let short = (5...14).map { night($0, bed: 0, wake: 7) }
        XCTAssertEqual(SleepAnalysis.debt(SleepAnalysis.nights(short), now: now)!, 10 * 3600, accuracy: 1)
        // Plus a 12-hour night: 4 hours paid back.
        let withLong = short + [night(4, bed: -2, wake: 10)]
        XCTAssertEqual(SleepAnalysis.debt(SleepAnalysis.nights(withLong), now: now)!, 6 * 3600, accuracy: 1)
    }

    func testRegularity() {
        let days = (0..<14).map { i in night(i, bed: i % 2 == 0 ? -1 : 0, wake: 7) }
        let r = try! XCTUnwrap(SleepAnalysis.regularity(SleepAnalysis.nights(days)))
        XCTAssertEqual(r.bedtimeSpread, 31, accuracy: 1.5)  // half an hour either way
        XCTAssertEqual(r.wakeSpread, 0, accuracy: 0.01)
    }

    func testSleepAssessmentWordsWithoutDashes() {
        let now = day(14).day.addingTimeInterval(12 * 3600)
        let days = (0...14).map { night($0, bed: 0.5, wake: 6.5) }
        let a = try! XCTUnwrap(Coach.sleepAssessment(days: days, now: now))
        XCTAssertEqual(a.verdict, "Short on sleep")
        XCTAssertTrue(a.advice.contains("earlier"))
        XCTAssertFalse((a.reasons + a.observations + [a.advice]).joined().contains("—"))
    }

    // MARK: Views

    func testStageBarsRender() {
        let n = SleepAnalysis.nights([night(0, bed: -0.5, wake: 7.25)]).first!
        let view = StageRanges(night: n, average: ["Deep": 15, "Light": 60, "REM": 22]).frame(width: 700)
        XCTAssertNotNil(ImageRenderer(content: view).nsImage)
    }
}

final class RepTests: XCTestCase {
    private func lap(_ metres: Double, _ paceSeconds: Double) -> Lap {
        var l = Lap()
        l.distance = metres
        l.moving = metres / 1000 * paceSeconds
        return l
    }

    func testTempoRepeatsAreFound() {
        // Warm-up, 3 km rep, 500 m jog, 3 km rep, cool-down: the real tempo session that read as "uneven".
        let laps = [lap(1000, 395), lap(1000, 324), lap(1000, 328), lap(1000, 330), lap(500, 422),
                    lap(1000, 349), lap(1000, 371), lap(1000, 347), lap(500, 360), lap(20, 283)]
        let reps = try! XCTUnwrap(Coach.reps(laps))
        XCTAssertEqual(reps.count, 2)
        XCTAssertEqual(reps[0].distance, 3000)
        XCTAssertEqual(reps[0].seconds / 3, 327.3, accuracy: 0.5)
    }

    func testSteadyRunAndSlowStartAreNotReps() {
        XCTAssertNil(Coach.reps((0..<8).map { i in lap(1000, 330 + Double(i % 3) * 6) }))
        XCTAssertNil(Coach.reps([lap(1000, 400)] + (0..<7).map { _ in lap(1000, 330) }))
    }

    func testIntervalsWithJogs() {
        let laps = [lap(2000, 360)] + (0..<5).flatMap { _ in [lap(800, 250), lap(400, 420)] } + [lap(1500, 370)]
        XCTAssertEqual(Coach.reps(laps)?.count, 5)
    }
}
