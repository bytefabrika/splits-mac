import Foundation
import Observation
import SwiftData

/// Pulls data from Garmin into the local store. The first sync takes the whole activity history and a year of
/// wellness data; later ones only ask for the last few days.
@MainActor
@Observable
final class Sync {
    enum State: Equatable {
        case idle
        case running(String)
        case failed(String)
    }

    /// Running totals while syncing, for the first-sync screen.
    struct Found: Equatable {
        var activities = 0
        var metres = 0.0
        var seconds = 0.0
        var nights = 0
        var oldest: Date?
        var sports: [Sport: Int] = [:]
    }

    private(set) var state: State = .idle
    private(set) var found = Found()
    private(set) var lastSync: Date?
    /// "metric" or "statute_us", from the Garmin profile.
    private(set) var units: String

    static let pageSize = 100
    static let wellnessDays = 365
    static let chunkDays = 28
    /// Re-read this many recent days on every sync: Garmin fills in last night's data during the morning.
    static let overlapDays = 3

    private let client: GarminClient
    private let context: ModelContext
    private let defaults: UserDefaults
    private let today: () -> Date

    init(client: GarminClient = .shared, context: ModelContext, defaults: UserDefaults = .standard,
         today: @escaping () -> Date = Date.init) {
        self.client = client
        self.context = context
        self.defaults = defaults
        self.today = today
        units = defaults.string(forKey: "units") ?? "metric"
        lastSync = defaults.object(forKey: "lastSync") as? Date
    }

    var isRunning: Bool { if case .running = state { true } else { false } }

    func run() async {
        guard !isRunning else { return }
        found = Found()
        do {
            state = .running("Checking your key…")
            _ = try await client.authenticate(force: true)
            if let profile: ProfileDTO = try? await client.get(Endpoint.profile.0) {
                units = profile.measurementSystem == "statute_us" ? "statute_us" : "metric"
                defaults.set(units, forKey: "units")
            }
            try await syncActivities()
            try await syncDays()
            lastSync = Date()
            defaults.set(lastSync, forKey: "lastSync")
            state = .idle
        } catch is CancellationError {
            state = .idle
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: Activities

    func syncActivities() async throws {
        // With history already here, only look from a little before the newest one we have.
        var newest = FetchDescriptor<Activity>(sortBy: [SortDescriptor(\.start, order: .reverse)])
        newest.fetchLimit = 1
        // Activities stored before start coordinates were kept need the whole list once more.
        let backfilled = defaults.bool(forKey: "coordinatesBackfilled")
        let from = backfilled ? (try context.fetch(newest).first?.start).map { GarminDate.string($0.addingTimeInterval(-2 * 86_400)) } : nil

        var start = 0, total = 0
        while true {
            state = .running(total == 0 ? "Loading activities…" : "Loading activities… \(total)")
            let (path, query) = Endpoint.activities(start: start, limit: Self.pageSize, from: from)
            let page: [ActivityDTO] = try await client.get(path, query: query)
            upsert(page)
            for dto in page {
                found.activities += 1
                found.metres += dto.distance ?? 0
                found.seconds += dto.movingDuration ?? dto.duration ?? 0
                found.sports[Sport(typeKey: dto.activityType?.typeKey ?? "other"), default: 0] += 1
                if let start = dto.startTimeLocal.flatMap(GarminDate.local), start < (found.oldest ?? .distantFuture) {
                    found.oldest = start
                }
            }
            total += page.count
            start += Self.pageSize
            if page.count < Self.pageSize || start > 20_000 { break }
        }
        try context.save()
        defaults.set(true, forKey: "coordinatesBackfilled")
    }

    func upsert(_ dtos: [ActivityDTO]) {
        let ids = dtos.map(\.activityId)
        let existing = (try? context.fetch(FetchDescriptor<Activity>(predicate: #Predicate { ids.contains($0.garminId) }))) ?? []
        var byId = Dictionary(existing.map { ($0.garminId, $0) }, uniquingKeysWith: { a, _ in a })
        for dto in dtos {
            let activity = byId[dto.activityId] ?? {
                let new = Activity(garminId: dto.activityId)
                context.insert(new)
                byId[dto.activityId] = new
                return new
            }()
            activity.update(from: dto)
        }
    }

    // MARK: Days

    func syncDays() async throws {
        let calendar = Calendar.current
        let end = calendar.startOfDay(for: today())
        var latest = FetchDescriptor<Day>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        latest.fetchLimit = 1
        let firstNeeded: Date
        if let last = try context.fetch(latest).first?.day {
            firstNeeded = calendar.date(byAdding: .day, value: -Self.overlapDays, to: last)!
        } else {
            firstNeeded = calendar.date(byAdding: .day, value: -(Self.wellnessDays - 1), to: end)!
        }

        // Newest chunk first, so "Today" fills in before the rest of the year.
        var chunkEnd = end
        var done = 0
        let totalDays = max(calendar.dateComponents([.day], from: firstNeeded, to: end).day ?? 0, 0) + 1
        while chunkEnd >= firstNeeded {
            let chunkStart = max(calendar.date(byAdding: .day, value: -(Self.chunkDays - 1), to: chunkEnd)!, firstNeeded)
            let from = GarminDate.string(chunkStart), to = GarminDate.string(chunkEnd)
            state = .running("Loading sleep, HRV and Body Battery… \(min(done * 100 / max(totalDays, 1), 99))%")
            try await syncDays(from: from, to: to)
            try context.save()
            done += Self.chunkDays
            chunkEnd = calendar.date(byAdding: .day, value: -1, to: chunkStart)!
        }
    }

    private func syncDays(from: String, to: String) async throws {
        let summaries: DailySummariesDTO = try await client.get(Endpoint.dailySummaries(from: from, to: to).0,
                                                                query: Endpoint.dailySummaries(from: from, to: to).1)
        for s in summaries.data {
            guard let date = s.calendarDate else { continue }
            let day = self.day(date)
            day.restingHR = s.heartRate?.restingValue
            day.stressAvg = s.stress?.avgLevel.flatMap { $0 >= 0 ? $0 : nil }
            day.bodyBatteryHigh = s.bodyBattery?.maxValue
            day.bodyBatteryLow = s.bodyBattery?.minValue
            day.bodyBatteryCharged = s.bodyBattery?.chargedValue
            day.bodyBatteryDrained = s.bodyBattery?.drainedValue
            day.bodyBatteryLatest = s.bodyBattery?.latestValue
            day.activeCalories = s.calories?.burnedActive
            day.intensityModerate = s.intensityMinutes?.moderate
            day.intensityVigorous = s.intensityMinutes?.vigorous
            day.respiration = s.respiration?.avgValue
        }

        let sleep: [SleepDTO] = try await client.get(Endpoint.sleep(from: from, to: to).0, query: Endpoint.sleep(from: from, to: to).1)
        for s in sleep where (s.sleepTimeSeconds ?? 0) > 0 {
            guard let date = s.calendarDate else { continue }
            found.nights += 1
            let day = self.day(date)
            day.sleepSeconds = s.sleepTimeSeconds
            day.deepSeconds = s.deepSleepSeconds
            day.lightSeconds = s.lightSleepSeconds
            day.remSeconds = s.remSleepSeconds
            day.awakeSeconds = s.awakeSleepSeconds
            day.sleepScore = s.sleepScores?.overall?.value
            day.sleepQuality = s.sleepScores?.overall?.qualifierKey
            day.sleepStart = s.sleepStartTimestampLocal.map(GarminDate.localMillis)
            day.sleepEnd = s.sleepEndTimestampLocal.map(GarminDate.localMillis)
        }

        let hrv: HRVRangeDTO = try await client.get(Endpoint.hrv(from: from, to: to).0)
        for h in hrv.hrvSummaries {
            guard let date = h.calendarDate else { continue }
            let day = self.day(date)
            day.hrvLastNight = h.lastNightAvg
            day.hrvWeekly = h.weeklyAvg
            day.hrvStatus = h.status
            day.hrvBalancedLow = h.baseline?.balancedLow
            day.hrvBalancedHigh = h.baseline?.balancedUpper
        }

        let steps: [StepsDTO] = try await client.get(Endpoint.steps(from: from, to: to).0)
        for s in steps {
            guard let date = s.calendarDate else { continue }
            let day = self.day(date)
            day.steps = s.totalSteps
            day.stepGoal = s.stepGoal
        }
    }

    private var dayCache: [String: Day] = [:]

    private func day(_ date: String) -> Day {
        if let cached = dayCache[date] { return cached }
        let found = (try? context.fetch(FetchDescriptor<Day>(predicate: #Predicate { $0.date == date })))?.first
        let day = found ?? { let d = Day(date: date); context.insert(d); return d }()
        dayCache[date] = day
        return day
    }
}
