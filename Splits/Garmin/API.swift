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
    let startLatitude: Double?
    let startLongitude: Double?
    let minTemperature: Double?
    let maxTemperature: Double?
    let averageRunningCadenceInStepsPerMinute: Double?
    let hrTimeInZone_1: Double?
    let hrTimeInZone_2: Double?
    let hrTimeInZone_3: Double?
    let hrTimeInZone_4: Double?
    let hrTimeInZone_5: Double?
}

/// The extra numbers on one activity (`/activity-service/activity/{id}`, `summaryDTO`). SI units; times in ms
/// for running dynamics, stride in cm, water in ml.
struct ActivityDetailDTO: Codable {
    struct Summary: Codable {
        let averageMovingSpeed: Double?
        let avgGradeAdjustedSpeed: Double?
        let recoveryHeartRate: Double?
        let waterEstimated: Double?
        let differenceBodyBattery: Double?
        let beginPotentialStamina: Double?
        let endPotentialStamina: Double?
        let directWorkoutFeel: Double?
        let directWorkoutRpe: Double?
        let groundContactTime: Double?
        let strideLength: Double?
        let verticalOscillation: Double?
        let verticalRatio: Double?
        let normalizedPower: Double?
        let maxPower: Double?
        let totalWork: Double?
        let averageTemperature: Double?
        let minHR: Double?
        let maxElevation: Double?
        let minElevation: Double?
        let moderateIntensityMinutes: Double?
        let vigorousIntensityMinutes: Double?
    }
    let summaryDTO: Summary?
    let locationName: String?
}

/// Heart rate zone floors, per sport ("DEFAULT", "RUNNING", "CYCLING"…).
struct HeartRateZonesDTO: Codable {
    let sport: String?
    let zone1Floor: Int?
    let zone2Floor: Int?
    let zone3Floor: Int?
    let zone4Floor: Int?
    let zone5Floor: Int?
    let maxHeartRateUsed: Int?

    var floors: [Int] { [zone1Floor, zone2Floor, zone3Floor, zone4Floor, zone5Floor].compactMap { $0 } }
}

struct DailySummariesDTO: Decodable {
    struct Day: Decodable {
        struct HeartRate: Decodable { let restingValue: Int?; let minValue: Int?; let maxValue: Int? }
        struct Stress: Decodable {
            let avgLevel: Int?; let maxLevel: Int?; let qualifier: String?
            let restDurationInMillis: Double?; let lowStressDurationInMillis: Double?
            let mediumStressDurationInMillis: Double?; let highStressDurationInMillis: Double?
            let activityDurationInMillis: Double?
        }
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
    let lowestRespirationValue: Double?
    let highestRespirationValue: Double?
    let awakeCount: Int?
    let avgSleepStress: Double?
    /// "NEGATIVE_LONG_BUT_NOT_ENOUGH_REM" and the like: Garmin's reason for the score.
    let sleepScoreFeedback: String?
    let sleepScores: Scores?
    /// Garmin's sleep need for that night in minutes: `baseline` is the usual, `actual` adjusted for training and HRV.
    struct Need: Decodable { let baseline: Int?; let actual: Int? }
    let sleepNeed: Need?
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
    let hrvSummaries: [Summary]?
}

/// One night's HRV: the summary plus a reading every 5 minutes while asleep (`/hrv-service/hrv/{date}`).
struct HRVNightDTO: Decodable {
    struct Reading: Decodable {
        let hrvValue: Int?
        /// "2026-11-08T23:29:59.0", UTC.
        let readingTimeGMT: String?
    }
    let hrvSummary: HRVRangeDTO.Summary?
    let hrvReadings: [Reading]?

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    var readings: [(Date, Double)] {
        (hrvReadings ?? []).compactMap { r in
            guard let value = r.hrvValue, let time = r.readingTimeGMT,
                  let date = Self.formatter.date(from: String(time.prefix(19))) else { return nil }
            return (date, Double(value))
        }
    }
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

/// `heartRateValues`: `[[timestamp ms (GMT), bpm], …]`.
struct DailyHeartRateDTO: Decodable {
    let restingHeartRate: Int?
    let minHeartRate: Int?
    let maxHeartRate: Int?
    let heartRateValues: [[Double?]]?

    var values: [(Date, Double)] {
        (heartRateValues ?? []).compactMap { pair in
            guard pair.count >= 2, let ms = pair[0], let bpm = pair[1] else { return nil }
            return (Date(timeIntervalSince1970: ms / 1000), bpm)
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
    /// One night with a reading every 5 minutes.
    static func hrvNight(_ date: String) -> String { "/hrv-service/hrv/\(date)" }
    static func steps(from: String, to: String) -> (String, [String: String]) {
        ("/usersummary-service/stats/steps/daily/\(from)/\(to)", [:])
    }
    /// `chunks` sets the resolution: 96 is a point every 6 minutes, 200 every 3. Without it there are only a few
    /// points a day.
    static func bodyBattery(from: String, to: String, chunks: Int = 96) -> (String, [String: String]) {
        ("/wellness-service/wellness/bodyBattery/reports/daily", ["startDate": from, "endDate": to, "chunks": String(chunks)])
    }
    /// Heart rate through one day, every 2 minutes.
    static func dailyHeartRate(_ date: String) -> (String, [String: String]) {
        ("/wellness-service/wellness/dailyHeartRate", ["date": date])
    }
    static let profile = ("/userprofile-service/userprofile/settings", [String: String]())
}
