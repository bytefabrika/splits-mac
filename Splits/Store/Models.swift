import Foundation
import SwiftData
import SwiftUI

/// An activity, as Garmin summarises it. SI units: metres, seconds, m/s.
@Model
final class Activity {
    @Attribute(.unique) var garminId: Int64
    var name: String
    var typeKey: String
    var start: Date
    var distance: Double
    var duration: Double
    var movingDuration: Double
    var elevationGain: Double
    var averageHR: Double?
    var maxHR: Double?
    var calories: Double?
    var averageSpeed: Double?
    var averagePower: Double?
    var aerobicEffect: Double?
    var anaerobicEffect: Double?
    var trainingLoad: Double?
    var cadence: Double?
    var steps: Int?
    var laps: Int?
    var isPR: Bool
    var isFavorite: Bool
    var minTemperature: Double?
    var maxTemperature: Double?
    /// Seconds in heart rate zones 1–5.
    var hrZones: [Double]
    /// The on-device model's take on this activity, kept once written.
    var coachNote: String?
    /// Where it started; nil for indoor activities and ones without GPS.
    var startLatitude: Double?
    var startLongitude: Double?

    init(garminId: Int64) {
        self.garminId = garminId
        name = ""
        typeKey = "other"
        start = .distantPast
        distance = 0
        duration = 0
        movingDuration = 0
        elevationGain = 0
        isPR = false
        isFavorite = false
        hrZones = []
    }

    var sport: Sport { Sport(typeKey: typeKey) }
    /// Seconds per km, for sports where pace makes sense.
    var paceSecondsPerKm: Double? { distance > 0 && movingDuration > 0 ? movingDuration / (distance / 1000) : nil }

    func update(from dto: ActivityDTO) {
        name = dto.activityName ?? ""
        typeKey = dto.activityType?.typeKey ?? "other"
        start = dto.startTimeLocal.flatMap(GarminDate.local) ?? start
        distance = dto.distance ?? 0
        duration = dto.duration ?? 0
        movingDuration = dto.movingDuration ?? dto.duration ?? 0
        elevationGain = dto.elevationGain ?? 0
        averageHR = dto.averageHR
        maxHR = dto.maxHR
        calories = dto.calories
        averageSpeed = dto.averageSpeed
        averagePower = dto.avgPower
        aerobicEffect = dto.aerobicTrainingEffect
        anaerobicEffect = dto.anaerobicTrainingEffect
        trainingLoad = dto.activityTrainingLoad
        cadence = dto.averageRunningCadenceInStepsPerMinute
        steps = dto.steps
        laps = dto.lapCount
        isPR = dto.isPR ?? false
        isFavorite = dto.isFavorite ?? false
        startLatitude = dto.startLatitude
        startLongitude = dto.startLongitude
        minTemperature = dto.minTemperature
        maxTemperature = dto.maxTemperature
        let zones = [dto.hrTimeInZone_1, dto.hrTimeInZone_2, dto.hrTimeInZone_3, dto.hrTimeInZone_4, dto.hrTimeInZone_5]
        hrZones = zones.contains { $0 != nil } ? zones.map { $0 ?? 0 } : []
    }
}

/// One calendar day of wellness data: sleep (the night that ended that morning), HRV, Body Battery, stress, steps.
@Model
final class Day {
    @Attribute(.unique) var date: String  // yyyy-MM-dd, the user's calendar day
    var restingHR: Int?
    var stressAvg: Int?
    var bodyBatteryHigh: Int?
    var bodyBatteryLow: Int?
    var bodyBatteryCharged: Int?
    var bodyBatteryDrained: Int?
    var bodyBatteryLatest: Int?
    var activeCalories: Int?
    var intensityModerate: Int?
    var intensityVigorous: Int?
    var respiration: Double?
    var steps: Int?
    var stepGoal: Int?
    var sleepSeconds: Int?
    var deepSeconds: Int?
    var lightSeconds: Int?
    var remSeconds: Int?
    var awakeSeconds: Int?
    var sleepScore: Int?
    var sleepQuality: String?
    var sleepStart: Date?
    var sleepEnd: Date?
    var hrvLastNight: Int?
    var hrvWeekly: Int?
    var hrvStatus: String?
    var hrvBalancedLow: Int?
    var hrvBalancedHigh: Int?

    init(date: String) { self.date = date }

    var day: Date { GarminDate.day(date) ?? .distantPast }
}

/// Sports, from Garmin's activity type keys ("running", "indoor_cycling", "lap_swimming"…). Language-independent.
enum Sport: String, CaseIterable, Identifiable {
    case run, ride, swim, walk, hike, strength, mindful, racket, team, water, snow, other
    var id: String { rawValue }

    init(typeKey key: String) {
        switch true {
        case key.contains("run"): self = .run
        case key.contains("cycl") || key.contains("bik") || key.contains("ride") || key.contains("mountain"): self = .ride
        case key.contains("swim"): self = .swim
        case key.contains("hik"): self = .hike
        case key.contains("walk"): self = .walk
        case key.contains("strength") || key.contains("hiit") || key.contains("cardio") || key.contains("fitness"): self = .strength
        case key.contains("yoga") || key.contains("pilates") || key.contains("breath") || key.contains("meditation"):
            self = .mindful
        // Garmin's key for padel is "paddelball".
        case key.contains("padel") || key.contains("paddel") || key.contains("tennis") || key.contains("squash")
            || key.contains("badminton") || key.contains("pickleball"): self = .racket
        case key.contains("soccer") || key.contains("football") || key.contains("basketball") || key.contains("volleyball"):
            self = .team
        case key.contains("kayak") || key.contains("rowing") || key.contains("paddl") || key.contains("sail")
            || key.contains("boat") || key.contains("surf"): self = .water
        case key.contains("ski") || key.contains("snowboard") || key.contains("skating"): self = .snow
        default: self = .other
        }
    }

    var label: String {
        switch self {
        case .run: "Running"; case .ride: "Cycling"; case .swim: "Swimming"; case .walk: "Walking"; case .hike: "Hiking"
        case .strength: "Strength"; case .mindful: "Yoga & mindfulness"; case .racket: "Racket sports"
        case .team: "Team sports"; case .water: "On the water"; case .snow: "Snow"; case .other: "Other"
        }
    }

    var symbol: String {
        switch self {
        case .run: "figure.run"; case .ride: "figure.outdoor.cycle"; case .swim: "figure.pool.swim"; case .walk: "figure.walk"
        case .hike: "figure.hiking"; case .strength: "dumbbell"; case .mindful: "figure.yoga"; case .racket: "figure.tennis"
        case .team: "figure.soccer"; case .water: "figure.rower"; case .snow: "figure.skiing.downhill"
        case .other: "figure.mixed.cardio"
        }
    }

    var color: Color {
        switch self {
        case .run: Color(red: 1.0, green: 0.42, blue: 0.29)
        case .ride: Color(red: 1.0, green: 0.75, blue: 0.2)
        case .swim: Color(red: 0.24, green: 0.72, blue: 1.0)
        case .walk: Color(red: 0.45, green: 0.85, blue: 0.55)
        case .hike: Color(red: 0.35, green: 0.65, blue: 0.35)
        case .strength: Color(red: 0.72, green: 0.52, blue: 1.0)
        case .mindful: Color(red: 1.0, green: 0.55, blue: 0.78)
        case .racket: Color(red: 0.75, green: 0.95, blue: 0.24)
        case .team: Color(red: 0.2, green: 0.8, blue: 0.75)
        case .water: Color(red: 0.2, green: 0.5, blue: 0.95)
        case .snow: Color(red: 0.7, green: 0.85, blue: 1.0)
        case .other: .gray
        }
    }

    /// Has a route worth drawing: outdoors, with a GPS start.
    static func hasRoute(_ a: Activity) -> Bool {
        a.startLatitude != nil && a.distance > 0 && !isIndoor(a.typeKey)
    }

    /// Indoor activities have no real route or climbing.
    static func isIndoor(_ key: String) -> Bool {
        ["indoor", "virtual", "treadmill", "trainer"].contains { key.contains($0) }
    }
}

/// Garmin's date formats.
enum GarminDate {
    private static let localFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// "2026-11-07 13:03:39" (the activity's local time, shown as such).
    static func local(_ string: String) -> Date? { localFormatter.date(from: String(string.prefix(19))) }
    static func day(_ string: String) -> Date? { dayFormatter.date(from: string) }
    static func string(_ date: Date) -> String { dayFormatter.string(from: date) }
    /// Garmin's "local" millisecond timestamps are wall-clock time written as if it were UTC.
    static func localMillis(_ ms: Double) -> Date {
        let utc = Date(timeIntervalSince1970: ms / 1000)
        return utc.addingTimeInterval(-Double(TimeZone.current.secondsFromGMT(for: utc)))
    }
}
