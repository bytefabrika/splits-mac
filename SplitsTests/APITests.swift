import XCTest
@testable import Splits

/// Decoding the shapes Garmin's Personal API really returns (taken from real responses, values made up).
final class APITests: XCTestCase {
    func testIntradayHeartRate() throws {
        let json = """
        {"restingHeartRate": 57, "minHeartRate": 52, "maxHeartRate": 140,
         "heartRateValueDescriptors": [{"key": "timestamp", "index": 0}, {"key": "heartrate", "index": 1}],
         "heartRateValues": [[1794253080000, 69], [1794253200000, null], [1794253320000, 72]]}
        """
        let hr = try JSONDecoder().decode(DailyHeartRateDTO.self, from: Data(json.utf8))
        XCTAssertEqual(hr.restingHeartRate, 57)
        XCTAssertEqual(hr.values.map(\.1), [69, 72], "nulls are gaps")
        XCTAssertEqual(hr.values.first?.0, Date(timeIntervalSince1970: 1_794_253_080))
    }

    func testBodyBatteryDay() throws {
        let json = """
        [{"date": "2026-11-09", "charged": 30, "drained": 50,
          "bodyBatteryValuesArray": [[1794228480000, 44], [1794251160000, 15], [1794252000000, null]]}]
        """
        let days = try JSONDecoder().decode([BodyBatteryDayDTO].self, from: Data(json.utf8))
        XCTAssertEqual(days.first?.levels.map(\.1), [44, 15])
    }

    func testDailySummaryStress() throws {
        let json = """
        {"data": [{"calendarDate": "2026-11-09",
          "stress": {"avgLevel": 39, "maxLevel": 98, "qualifier": "balanced", "restDurationInMillis": 28500000,
                     "lowStressDurationInMillis": 5280000, "mediumStressDurationInMillis": 9060000,
                     "highStressDurationInMillis": 10380000, "activityDurationInMillis": 5400000},
          "heartRate": {"restingValue": 59}}]}
        """
        let s = try JSONDecoder().decode(DailySummariesDTO.self, from: Data(json.utf8)).data[0]
        XCTAssertEqual(s.stress?.avgLevel, 39)
        XCTAssertEqual(s.stress?.highStressDurationInMillis, 10_380_000)
        XCTAssertEqual(s.heartRate?.restingValue, 59)
    }

    func testNullCalendarDateOnEmptyNights() throws {
        let json = """
        [{"calendarDate": null, "sleepTimeSeconds": null}, {"calendarDate": "2026-11-09", "sleepTimeSeconds": 27600}]
        """
        let nights = try JSONDecoder().decode([SleepDTO].self, from: Data(json.utf8))
        XCTAssertNil(nights[0].calendarDate)
        XCTAssertEqual(nights[1].sleepTimeSeconds, 27600)
    }
}

final class CoachFactsTests: XCTestCase {
    func testWeeklyFactsCompareWithUsualWeeks() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func run(daysAgo: Double, km: Double, load: Double) -> Activity {
            let a = Activity(garminId: Int64(daysAgo * 10))
            a.typeKey = "running"
            a.start = now.addingTimeInterval(-daysAgo * 86_400)
            a.distance = km * 1000
            a.movingDuration = km * 330
            a.trainingLoad = load
            return a
        }
        let activities = [run(daysAgo: 1, km: 10, load: 120), run(daysAgo: 3, km: 21, load: 250), run(daysAgo: 12, km: 8, load: 90)]
        let day = Day(date: GarminDate.string(now.addingTimeInterval(-86_400)))
        day.sleepSeconds = 25_200
        day.hrvLastNight = 55
        let facts = Coach.weeklyFacts(activities: activities, days: [day], format: Format(units: "metric"), now: now)
        XCTAssertTrue(facts.contains("Activities this week: 2"), facts)
        XCTAssertTrue(facts.contains("Running: 2×"), facts)
        XCTAssertTrue(facts.contains("Training load this week 370"), facts)
        XCTAssertTrue(facts.contains("Average sleep 7 h 0 min"), facts)
        XCTAssertTrue(facts.contains("Overnight HRV averaged 55"), facts)
    }
}
