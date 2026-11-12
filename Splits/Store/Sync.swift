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
        // On the first-sync screen a retry carries on from what is already stored, rather than counting from zero.
        found = lastSync == nil ? stored() : Found()
        do {
            state = .running("Checking your key…")
            _ = try await client.authenticate(force: true)
            if let profile: ProfileDTO = try? await client.get(Endpoint.profile.0) {
                units = profile.measurementSystem == "statute_us" ? "statute_us" : "metric"
                defaults.set(units, forKey: "units")
            }
            try await syncActivities()
            try await syncDays()
            try await backfillSleepDetails()
            lastSync = Date()
            defaults.set(lastSync, forKey: "lastSync")
            state = .idle
            NotificationCenter.default.post(name: .splitsDataChanged, object: nil)
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
            // No body at all (204) means no activities. Any other shape we can't read still stops the sync.
            let page: [ActivityDTO] = try await client.get(path, query: query, as: [ActivityDTO]?.self) ?? []
            let added = upsert(page)
            for dto in page where added.contains(dto.activityId) {
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

    /// Returns the ids that are new to the store.
    @discardableResult
    func upsert(_ dtos: [ActivityDTO]) -> Set<Int64> {
        let ids = dtos.map(\.activityId)
        let existing = (try? context.fetch(FetchDescriptor<Activity>(predicate: #Predicate { ids.contains($0.garminId) }))) ?? []
        var byId = Dictionary(existing.map { ($0.garminId, $0) }, uniquingKeysWith: { a, _ in a })
        var added = Set<Int64>()
        for dto in dtos {
            let activity = byId[dto.activityId] ?? {
                let new = Activity(garminId: dto.activityId)
                context.insert(new)
                byId[dto.activityId] = new
                added.insert(dto.activityId)
                return new
            }()
            activity.update(from: dto)
        }
        return added
    }

    /// The totals for the first-sync screen, from what is already stored.
    private func stored() -> Found {
        var found = Found()
        for a in (try? context.fetch(FetchDescriptor<Activity>())) ?? [] {
            found.activities += 1
            found.metres += a.distance
            found.seconds += a.movingDuration > 0 ? a.movingDuration : a.duration
            found.sports[a.sport, default: 0] += 1
            if a.start < (found.oldest ?? .distantFuture) { found.oldest = a.start }
        }
        found.nights = (try? context.fetchCount(FetchDescriptor<Day>(predicate: #Predicate { ($0.sleepSeconds ?? 0) > 0 }))) ?? 0
        return found
    }

    // MARK: Days

    /// How far back the wellness days have been read, so a first sync that stops part way carries on from there.
    static let reachedBackKey = "daysReachedBack"

    func syncDays() async throws {
        let calendar = Calendar.current
        let end = calendar.startOfDay(for: today())
        let yearStart = calendar.date(byAdding: .day, value: -(Self.wellnessDays - 1), to: end)!
        var latest = FetchDescriptor<Day>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        latest.fetchLimit = 1

        // Newest first, so "Today" fills in before the rest of the year.
        var ranges: [(from: Date, to: Date, back: Bool)] = []
        let reachedBack: Date
        if let last = try context.fetch(latest).first?.day {
            let recent = min(calendar.date(byAdding: .day, value: -Self.overlapDays, to: last)!, end)
            ranges.append((recent, end, false))
            // Stores from before this was kept read the year once more, to fill any gap an error left.
            reachedBack = defaults.object(forKey: Self.reachedBackKey) as? Date ?? recent
        } else {
            // A first sync reads every sleep field already.
            defaults.set(true, forKey: "sleepDetailsBackfilled")
            reachedBack = calendar.date(byAdding: .day, value: 1, to: end)!
        }
        if reachedBack > yearStart {
            ranges.append((yearStart, calendar.date(byAdding: .day, value: -1, to: reachedBack)!, true))
        }

        func days(_ from: Date, _ to: Date) -> Int { (calendar.dateComponents([.day], from: from, to: to).day ?? 0) + 1 }
        let totalDays = ranges.reduce(0) { $0 + days($1.from, $1.to) }
        var done = 0
        for range in ranges {
            var chunkEnd = range.to
            while chunkEnd >= range.from {
                let chunkStart = max(calendar.date(byAdding: .day, value: -(Self.chunkDays - 1), to: chunkEnd)!, range.from)
                state = .running("Loading sleep, HRV and energy… \(min(done * 100 / max(totalDays, 1), 99))%")
                try await syncDays(from: GarminDate.string(chunkStart), to: GarminDate.string(chunkEnd))
                try context.save()
                if range.back { defaults.set(chunkStart, forKey: Self.reachedBackKey) }
                done += days(chunkStart, chunkEnd)
                chunkEnd = calendar.date(byAdding: .day, value: -1, to: chunkStart)!
            }
        }
        if defaults.object(forKey: Self.reachedBackKey) == nil, let oldest = ranges.map(\.from).min() {
            defaults.set(oldest, forKey: Self.reachedBackKey)
        }
    }

    private func syncDays(from: String, to: String) async throws {
        let summaries: DailySummariesDTO? = try await wellness(Endpoint.dailySummaries(from: from, to: to))
        for s in summaries?.data ?? [] {
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

        try await syncSleep(from: from, to: to)

        let hrv: HRVRangeDTO? = try await wellness(Endpoint.hrv(from: from, to: to))
        for h in hrv?.hrvSummaries ?? [] {
            guard let date = h.calendarDate else { continue }
            let day = self.day(date)
            day.hrvLastNight = h.lastNightAvg
            day.hrvWeekly = h.weeklyAvg
            day.hrvStatus = h.status
            day.hrvBalancedLow = h.baseline?.balancedLow
            day.hrvBalancedHigh = h.baseline?.balancedUpper
        }

        let steps: [StepsDTO]? = try await wellness(Endpoint.steps(from: from, to: to))
        for s in steps ?? [] {
            guard let date = s.calendarDate else { continue }
            let day = self.day(date)
            day.steps = s.totalSteps
            day.stepGoal = s.stepGoal
        }
    }

    private func syncSleep(from: String, to: String) async throws {
        let sleep: [SleepDTO]? = try await wellness(Endpoint.sleep(from: from, to: to))
        for s in sleep ?? [] where (s.sleepTimeSeconds ?? 0) > 0 {
            guard let date = s.calendarDate else { continue }
            let day = self.day(date)
            if (day.sleepSeconds ?? 0) == 0 { found.nights += 1 }
            day.sleepSeconds = s.sleepTimeSeconds
            day.deepSeconds = s.deepSleepSeconds
            day.lightSeconds = s.lightSleepSeconds
            day.remSeconds = s.remSleepSeconds
            day.awakeSeconds = s.awakeSleepSeconds
            day.sleepScore = s.sleepScores?.overall?.value
            day.sleepQuality = s.sleepScores?.overall?.qualifierKey
            day.sleepStart = s.sleepStartTimestampLocal.map(GarminDate.localMillis)
            day.sleepEnd = s.sleepEndTimestampLocal.map(GarminDate.localMillis)
            day.sleepNeedMinutes = s.sleepNeed?.actual
            day.sleepNeedBaseline = s.sleepNeed?.baseline
            day.sleepRespiration = s.averageRespirationValue
            day.sleepRespirationLow = s.lowestRespirationValue
            day.sleepRespirationHigh = s.highestRespirationValue
            day.sleepStress = s.avgSleepStress
            day.awakeCount = s.awakeCount
            day.sleepFeedback = s.sleepScoreFeedback
        }
    }

    /// Nights stored before sleep need, breathing and sleep stress were kept: read the year's sleep once more.
    private func backfillSleepDetails() async throws {
        guard !defaults.bool(forKey: "sleepDetailsBackfilled") else { return }
        let calendar = Calendar.current
        let end = calendar.startOfDay(for: today())
        var chunkEnd = end
        for chunk in 0..<(Self.wellnessDays / Self.chunkDays + 1) {
            let chunkStart = calendar.date(byAdding: .day, value: -(Self.chunkDays - 1), to: chunkEnd)!
            state = .running("Loading sleep details… \(chunk * 100 / (Self.wellnessDays / Self.chunkDays + 1))%")
            try await syncSleep(from: GarminDate.string(chunkStart), to: GarminDate.string(chunkEnd))
            try context.save()
            chunkEnd = calendar.date(byAdding: .day, value: -1, to: chunkStart)!
        }
        defaults.set(true, forKey: "sleepDetailsBackfilled")
    }

    /// A wellness answer, or nil when there is none. Garmin answers with no body at all (204) for a stretch without
    /// HRV, sleep or steps, such as days before the watch could record them. A shape we can't read is also skipped:
    /// one missing day is better than a first sync that can't finish.
    private func wellness<T: Decodable>(_ endpoint: (String, [String: String])) async throws -> T? {
        do {
            return try await client.get(endpoint.0, query: endpoint.1, as: T?.self)
        } catch GarminError.unexpected(let path, let detail) {
            print("Skipped \(path): \(detail)")
            return nil
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
