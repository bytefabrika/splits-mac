import Foundation
import Observation

// MARK: Personal records

/// Every outdoor run's fastest 1 km, 5 km, 10 km, half and marathon, found once from its file and kept in
/// one small JSON file. The files themselves aren't kept (that would be hundreds of MB).
actor RecordStore {
    static let shared = RecordStore()

    /// Activity → distance label → seconds. An empty entry means looked at, nothing usable (no GPS, too short).
    private var bests: [Int64: [String: Double]]
    private let file: URL

    init(folder: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]) {
        file = folder.appendingPathComponent("Bests.json")
        bests = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([Int64: [String: Double]].self, from: $0) } ?? [:]
    }

    func all() -> [Int64: [String: Double]] { bests }
    func doneIDs() -> Set<Int64> { Set(bests.keys) }

    func find(_ id: Int64) async throws {
        let track = try await Tracks.shared.track(for: id, keep: false)
        var found: [String: Double] = [:]
        for best in TrackAnalysis(track, maxSamples: 1).bests where Records.plausible(distance: best.distance, seconds: best.seconds) {
            found[best.id] = best.seconds
        }
        bests[id] = found
        save()
    }

    func removeAll() {
        bests = [:]
        try? FileManager.default.removeItem(at: file)
    }

    private var unsaved = 0
    /// Saves every 10 finds, and at the end; losing a few on a crash only means finding them again.
    private func save(force: Bool = false) {
        unsaved += 1
        guard force || unsaved >= 10 else { return }
        unsaved = 0
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(bests).write(to: file, options: .atomic)
    }

    func flush() { save(force: true) }
}

/// Goes through the runs that haven't been looked at yet, one at a time, in the background.
@MainActor @Observable
final class RecordFinder {
    static let shared = RecordFinder()

    private(set) var running = false
    private(set) var done = 0
    private(set) var total = 0
    /// Bumped as results come in, so views reload.
    private(set) var version = 0
    private(set) var failed = 0
    private var task: Task<Void, Never>?

    var finished: Bool { total > 0 && done >= total }

    func start(_ ids: [Int64]) {
        guard !running else { return }
        running = true
        task = Task {
            let have = await RecordStore.shared.doneIDs()
            let todo = ids.filter { !have.contains($0) }
            total = ids.count
            done = ids.count - todo.count
            failed = 0
            for (i, id) in todo.enumerated() {
                if Task.isCancelled { break }
                do { try await RecordStore.shared.find(id) } catch { failed += 1 }
                done += 1
                if i % 10 == 9 { version += 1 }
            }
            await RecordStore.shared.flush()
            version += 1
            running = false
        }
    }

    func pause() {
        task?.cancel()
        task = nil
        running = false
    }

    func count(_ ids: [Int64]) async {
        let have = await RecordStore.shared.doneIDs()
        total = ids.count
        done = ids.filter { have.contains($0) }.count
    }
}

enum Records {
    static let distances: [(label: String, metres: Double)] = [
        ("1 km", 1000), ("5 km", 5000), ("10 km", 10_000), ("Half", 21_097.5), ("Marathon", 42_195),
    ]

    /// GPS can jump: a "best km" faster than 2:30 /km is a glitch, not a record.
    static func plausible(distance: Double, seconds: Double) -> Bool {
        seconds > 0 && distance / seconds < 6.7
    }

    /// Runs worth looking through: outdoors (a treadmill's distance comes from the watch's guess) and at least 1 km.
    static func candidates(_ activities: [Activity]) -> [Activity] {
        activities.filter { $0.sport == .run && !Sport.isIndoor($0.typeKey) && $0.distance >= 1000 }
    }
}

// MARK: Aerobic form

/// How fast you run at the same heart rate. Speed above resting heart rate scales roughly with heart rate,
/// so each run's pace is scaled to one reference heart rate; hills count as extra distance.
struct AerobicForm {
    struct Point: Identifiable {
        let id: Int64
        let date: Date
        /// Seconds per km at the reference heart rate.
        let pace: Double
        /// The 30-day median up to this run: the line.
        var trend: Double = 0
    }

    let reference: Int
    let resting: Double
    let points: [Point]

    init(runs: [Activity], resting: Double?) {
        let rest = resting ?? 55
        self.resting = rest
        let usable = runs.filter {
            $0.sport == .run && !Sport.isIndoor($0.typeKey) && $0.distance >= 3000 && $0.movingDuration >= 900
                && ($0.averageHR ?? 0) >= rest + 30
        }
        // The heart rate you usually run at, to the nearest 5, so the number means something to you.
        let hrs = usable.compactMap(\.averageHR).sorted()
        let median = hrs.isEmpty ? 150 : hrs[hrs.count / 2]
        let reference = Int((median / 5).rounded() * 5)
        self.reference = reference

        var points: [Point] = usable.sorted { $0.start < $1.start }.compactMap { a in
            guard let hr = a.averageHR, a.movingDuration > 0 else { return nil }
            // Each metre climbed costs about as much as 6 m on the flat.
            let effective = a.distance + 6 * a.elevationGain
            let speed = effective / a.movingDuration * (Double(reference) - rest) / (hr - rest)
            guard speed > 1.5, speed < 7 else { return nil }
            return Point(id: a.garminId, date: a.start, pace: 1000 / speed)
        }
        var window: [Point] = []
        for i in points.indices {
            window.append(points[i])
            let cutoff = points[i].date.addingTimeInterval(-30 * 86_400)
            window.removeAll { $0.date < cutoff }
            let sorted = window.map(\.pace).sorted()
            points[i].trend = sorted[sorted.count / 2]
        }
        self.points = points
    }

    /// The trend now and at a date in the past (the nearest run before it).
    var now: Double? { points.last?.trend }
    func trend(at date: Date) -> Double? { points.last { $0.date <= date }?.trend }
}

// MARK: Streaks

struct Streaks {
    /// Days in a row with an activity, up to today (or yesterday, so today isn't lost before you've gone out).
    var currentDays = 0
    var longestDays = 0
    var longestDaysEnd: Date?
    /// Weeks in a row with at least `perWeek` activities.
    var currentWeeks = 0
    var longestWeeks = 0
    var thisWeek = 0
    var bestWeek = 0
    let perWeek: Int

    init(dates: [Date], perWeek: Int = 3, today: Date = Date(), calendar: Calendar = .current) {
        self.perWeek = perWeek
        let days = Set(dates.map { calendar.startOfDay(for: $0) })
        let start = calendar.startOfDay(for: today)

        // Daily.
        var run = 0
        var previous: Date?
        for day in days.sorted() {
            if let previous, calendar.date(byAdding: .day, value: 1, to: previous) == day { run += 1 } else { run = 1 }
            if run > longestDays { longestDays = run; longestDaysEnd = day }
            previous = day
        }
        var cursor = days.contains(start) ? start : calendar.date(byAdding: .day, value: -1, to: start)!
        while days.contains(cursor) {
            currentDays += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
        }

        // Weekly.
        var perWeekCount: [Date: Int] = [:]
        for d in dates { perWeekCount[calendar.dateInterval(of: .weekOfYear, for: d)!.start, default: 0] += 1 }
        let thisWeekStart = calendar.dateInterval(of: .weekOfYear, for: today)!.start
        thisWeek = perWeekCount[thisWeekStart] ?? 0
        bestWeek = perWeekCount.values.max() ?? 0
        if let first = perWeekCount.keys.min() {
            var week = first, streak = 0
            while week <= thisWeekStart {
                if (perWeekCount[week] ?? 0) >= perWeek { streak += 1; longestWeeks = max(longestWeeks, streak) }
                else if week != thisWeekStart { streak = 0 }
                week = calendar.date(byAdding: .weekOfYear, value: 1, to: week)!
            }
        }
        // Current: this week counts once it's reached the goal; until then the streak runs up to last week.
        var week = thisWeek >= perWeek ? thisWeekStart : calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeekStart)!
        while (perWeekCount[week] ?? 0) >= perWeek {
            currentWeeks += 1
            week = calendar.date(byAdding: .weekOfYear, value: -1, to: week)!
        }
    }
}

// MARK: Race predictions

/// Race times from your best recent efforts, with Riegel's formula: T₂ = T₁ × (D₂ / D₁)^1.06.
/// Efforts inside training runs are rarely all-out, so each race takes the fastest prediction from any of them.
struct RacePredictor {
    struct Source {
        let label: String
        let metres: Double
        let seconds: Double
        let date: Date
        let activity: Int64
    }

    struct Prediction: Identifiable {
        let label: String
        let metres: Double
        let seconds: Double
        let source: Source
        var id: String { label }
    }

    static let exponent = 1.06
    static let targets: [(label: String, metres: Double)] = [("5 km", 5000), ("10 km", 10_000), ("Half", 21_097.5), ("Marathon", 42_195)]

    let predictions: [Prediction]
    /// How far back the efforts go: 4 months, or a year when there's nothing more recent.
    let months: Int

    init(efforts: [(activity: Int64, date: Date, label: String, seconds: Double)], now: Date = Date()) {
        let distances = Dictionary(uniqueKeysWithValues: Records.distances.map { ($0.label, $0.metres) })
        func sources(since months: Int) -> [Source] {
            let cutoff = Calendar.current.date(byAdding: .month, value: -months, to: now)!
            // 1 km is too short to say much about a 10 km or longer.
            return efforts.compactMap { e in
                guard e.date >= cutoff, let m = distances[e.label], m >= 5000 else { return nil }
                return Source(label: e.label, metres: m, seconds: e.seconds, date: e.date, activity: e.activity)
            }
        }
        var list = sources(since: 4)
        var months = 4
        if list.isEmpty { list = sources(since: 12); months = 12 }
        self.months = months
        predictions = Self.targets.compactMap { target in
            // From longer efforts it scales down well; from much shorter ones the marathon gets optimistic,
            // so a source has to be at least a quarter of the race.
            let usable = list.filter { $0.metres >= target.metres / 4 }
            let best = usable.map { s in (s, s.seconds * pow(target.metres / s.metres, Self.exponent)) }.min { $0.1 < $1.1 }
            return best.map { Prediction(label: target.label, metres: target.metres, seconds: $0.1, source: $0.0) }
        }
    }
}
