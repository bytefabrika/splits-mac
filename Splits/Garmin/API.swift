import Foundation

// What the Personal API returns, as far as Splits uses it. Every field is optional: Garmin leaves out
// what a device doesn't record, and extra fields are ignored. Units are always SI: metres, seconds, m/s.

struct ActivityDTO: Decodable {
    struct ActivityType: Decodable { let typeKey: String? }

    let activityId: Int64
    let activityName: String?
    let startTimeLocal: String?
    let activityType: ActivityType?
    let distance: Double?
    let duration: Double?
    let movingDuration: Double?
    let elevationGain: Double?
    let averageHR: Double?
    let maxHR: Double?
    let calories: Double?
    let averageSpeed: Double?
    let avgPower: Double?
    let aerobicTrainingEffect: Double?
    let anaerobicTrainingEffect: Double?
    let activityTrainingLoad: Double?
    let steps: Int?
    let lapCount: Int?
    let isPR: Bool?
    let isFavorite: Bool?
    let minTemperature: Double?
    let maxTemperature: Double?
    let averageRunningCadenceInStepsPerMinute: Double?
    let hrTimeInZone_1: Double?
    let hrTimeInZone_2: Double?
    let hrTimeInZone_3: Double?
    let hrTimeInZone_4: Double?
    let hrTimeInZone_5: Double?
}

struct DailySummariesDTO: Decodable {
    struct Day: Decodable {
        struct HeartRate: Decodable { let restingValue: Int?; let minValue: Int?; let maxValue: Int? }
        struct Stress: Decodable { let avgLevel: Int?; let maxLevel: Int?; let qualifier: String? }
        struct BodyBattery: Decodable {
            let minValue: Int?; let maxValue: Int?; let chargedValue: Int?; let drainedValue: Int?; let latestValue: Int?
        }
        struct Calories: Decodable { let burnedActive: Int?; let burnedTotal: Int? }
        struct Intensity: Decodable { let moderate: Int?; let vigorous: Int?; let goal: Int? }
        struct Respiration: Decodable { let avgValue: Double? }
        struct Movement: Decodable {
            struct Steps: Decodable { let count: Int?; let value: Int?; let goal: Int? }
            let steps: Steps?
        }

        let calendarDate: String?
        let heartRate: HeartRate?
        let stress: Stress?
        let bodyBattery: BodyBattery?
        let calories: Calories?
        let intensityMinutes: Intensity?
        let respiration: Respiration?
        let movement: Movement?
    }
    let data: [Day]
}

struct SleepDTO: Decodable {
    struct Score: Decodable { let value: Int?; let qualifierKey: String? }
    struct Scores: Decodable { let overall: Score? }

    /// Null on nights without sleep data.
    let calendarDate: String?
    let sleepTimeSeconds: Int?
    let deepSleepSeconds: Int?
    let lightSleepSeconds: Int?
    let remSleepSeconds: Int?
    let awakeSleepSeconds: Int?
    let sleepStartTimestampLocal: Double?
    let sleepEndTimestampLocal: Double?
    let avgHeartRate: Double?
    let averageRespirationValue: Double?
    let sleepScores: Scores?
}

struct HRVRangeDTO: Decodable {
    struct Summary: Decodable {
        struct Baseline: Decodable { let lowUpper: Int?; let balancedLow: Int?; let balancedUpper: Int? }
        let calendarDate: String?
        let weeklyAvg: Int?
        let lastNightAvg: Int?
        let lastNight5MinHigh: Int?
        let baseline: Baseline?
        let status: String?
    }
    let hrvSummaries: [Summary]
}

/// One day's Body Battery through the day: `[[timestamp ms (GMT), level], …]`.
struct BodyBatteryDayDTO: Decodable {
    let date: String?
    let bodyBatteryValuesArray: [[Double?]]?

    var levels: [(Date, Double)] {
        (bodyBatteryValuesArray ?? []).compactMap { pair in
            guard pair.count >= 2, let ms = pair[0], let level = pair[1] else { return nil }
            return (Date(timeIntervalSince1970: ms / 1000), level)
        }
    }
}

struct StepsDTO: Decodable {
    let calendarDate: String?
    let totalSteps: Int?
    let totalDistance: Int?
    let stepGoal: Int?
}

struct ProfileDTO: Decodable {
    let measurementSystem: String?
    let firstDayOfWeek: FirstDay?
    struct FirstDay: Decodable { let dayName: String? }
}

/// The endpoints Splits calls. Paths from Garmin's Personal API (see github.com/garmin/connect-personal-api-python).
enum Endpoint {
    static func activities(start: Int, limit: Int, from: String? = nil) -> (String, [String: String]) {
        var query = ["start": String(start), "limit": String(limit)]
        if let from { query["startDate"] = from }
        return ("/activitylist-service/activities/search/activities", query)
    }
    static func dailySummaries(from: String, to: String) -> (String, [String: String]) {
        ("/usersummary-service/v2/dailysummaries", ["startDate": from, "endDate": to])
    }
    static func sleep(from: String, to: String) -> (String, [String: String]) {
        ("/sleep-service/sleep/dailySleepSummariesByDate", ["startDate": from, "endDate": to])
    }
    static func hrv(from: String, to: String) -> (String, [String: String]) {
        ("/hrv-service/hrv/daily/\(from)/\(to)", [:])
    }
    static func steps(from: String, to: String) -> (String, [String: String]) {
        ("/usersummary-service/stats/steps/daily/\(from)/\(to)", [:])
    }
    static func bodyBattery(from: String, to: String) -> (String, [String: String]) {
        ("/wellness-service/wellness/bodyBattery/reports/daily", ["startDate": from, "endDate": to])
    }
    static let profile = ("/userprofile-service/userprofile/settings", [String: String]())
}
