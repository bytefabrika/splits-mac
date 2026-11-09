import CoreLocation
import Foundation

/// Activity files, downloaded once when an activity is first opened and kept on this Mac.
actor Tracks {
    static let shared = Tracks()

    private let client: GarminClient
    private let folder: URL
    private var memory: [Int64: Track] = [:]

    init(client: GarminClient = .shared,
         folder: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Activities", isDirectory: true)) {
        self.client = client
        self.folder = folder
    }

    func track(for id: Int64) async throws -> Track {
        if let cached = memory[id] { return cached }
        let file = folder.appendingPathComponent("\(id).fit")
        let fit: Data
        if let saved = try? Data(contentsOf: file) {
            fit = saved
        } else {
            let download = try await client.activityFile(id)
            fit = download.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04])
                ? try Zip.entries(download).first { $0.name.lowercased().hasSuffix(".fit") }?.data ?? Data()
                : download
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try fit.write(to: file, options: .atomic)
        }
        let track = try FIT.decode(fit)
        memory[id] = track
        return track
    }

    private var details: [Int64: ActivityDetailDTO] = [:]
    private var zones: [HeartRateZonesDTO]?

    /// The activity's extra numbers (stamina, sweat, Body Battery impact, running dynamics). Cached on disk.
    func detail(for id: Int64) async throws -> ActivityDetailDTO {
        if let cached = details[id] { return cached }
        let file = folder.appendingPathComponent("\(id).json")
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(ActivityDetailDTO.self, from: data) {
            details[id] = saved
            return saved
        }
        let detail: ActivityDetailDTO = try await client.get("/activity-service/activity/\(id)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(detail).write(to: file, options: .atomic)
        details[id] = detail
        return detail
    }

    /// The user's heart rate zones for a sport, falling back to their default zones. Fetched once per launch.
    func zones(for sport: Sport) async -> [Int] {
        if zones == nil { zones = try? await client.get("/biometric-service/heartRateZones/v2") }
        let key = sport == .run ? "RUNNING" : sport == .ride ? "CYCLING" : sport == .swim ? "SWIMMING" : "DEFAULT"
        let all = zones ?? []
        let match = all.first { $0.sport == key } ?? all.first { $0.sport == "DEFAULT" }
        return match?.floors.count == 5 ? match!.floors : []
    }

    func removeAll() {
        memory = [:]
        try? FileManager.default.removeItem(at: folder)
    }
}

/// What the activity screen shows, worked out from a track.
struct TrackAnalysis {
    struct Sample: Identifiable {
        let id: Int
        let km: Double
        let time: Double  // s since start
        let heartRate: Double?
        let speed: Double?
        let altitude: Double?
        let power: Double?
        let cadence: Double?
        let coordinate: CLLocationCoordinate2D?
    }

    struct Split: Identifiable {
        let id: Int        // 1-based km (or mile)
        let length: Double // m; the last one can be shorter
        let seconds: Double
        let averageHR: Double?
        let climb: Double
    }

    struct Best: Identifiable {
        let id: String
        let distance: Double
        let seconds: Double
    }

    let samples: [Sample]
    let route: [CLLocationCoordinate2D]
    let splits: [Split]
    let bests: [Best]

    /// A gap between records longer than this is a pause.
    static let pauseGap: TimeInterval = 15

    /// `splitLength`: 1000 m, or 1609.344 m for miles.
    init(_ track: Track, splitLength: Double = 1000, maxSamples: Int = 700) {
        let points = track.points
        let start = points.first?.time ?? Date()
        // Timer time: the watch stops recording while paused (lights, a coffee), so a long gap between two
        // records is a pause and doesn't count. Splits and best efforts use this, like the watch's own laps.
        var active = [Double](repeating: 0, count: points.count)
        for i in points.indices.dropFirst() {
            let gap = points[i].time.timeIntervalSince(points[i - 1].time)
            active[i] = active[i - 1] + (gap > Self.pauseGap ? 0 : max(gap, 0))
        }

        // Charts: an even spread of at most `maxSamples` points.
        let step = max(points.count / maxSamples, 1)
        var samples: [Sample] = []
        for (i, p) in points.enumerated() where i % step == 0 {
            samples.append(Sample(id: i, km: (p.distance ?? 0) / 1000, time: p.time.timeIntervalSince(start),
                                  heartRate: p.heartRate, speed: p.speed, altitude: p.altitude, power: p.power,
                                  cadence: p.cadence, coordinate: p.coordinate))
        }
        self.samples = samples

        // Map: every few metres is plenty.
        let fixes = points.compactMap(\.coordinate)
        let routeStep = max(fixes.count / 2500, 1)
        route = stride(from: 0, to: fixes.count, by: routeStep).map { fixes[$0] }

        // Splits from the distance stream, timed with timer time.
        var splits: [Split] = []
        var splitStart = points.indices.first
        var hrSum = 0.0, hrCount = 0.0, climb = 0.0
        var previousAltitude = points.first?.altitude
        for i in points.indices {
            let p = points[i]
            if let hr = p.heartRate { hrSum += hr; hrCount += 1 }
            if let a = p.altitude, let prev = previousAltitude, a > prev { climb += a - prev }
            previousAltitude = p.altitude ?? previousAltitude
            guard let d = p.distance, let s = splitStart, let sd = points[s].distance else { continue }
            if d - sd >= splitLength {
                splits.append(Split(id: splits.count + 1, length: d - sd, seconds: active[i] - active[s],
                                    averageHR: hrCount > 0 ? hrSum / hrCount : nil, climb: climb))
                splitStart = i
                hrSum = 0; hrCount = 0; climb = 0
            }
        }
        if let s = splitStart, let sd = points[s].distance, let lastIndex = points.indices.last,
           let ld = points[lastIndex].distance, ld - sd > splitLength * 0.1 {
            splits.append(Split(id: splits.count + 1, length: ld - sd, seconds: active[lastIndex] - active[s],
                                averageHR: hrCount > 0 ? hrSum / hrCount : nil, climb: climb))
        }
        self.splits = splits

        // Fastest stretches, with a two-pointer window over the distance stream.
        let stream = points.indices.compactMap { i in points[i].distance.map { (d: $0, t: active[i]) } }
        var bests: [Best] = []
        for (label, target) in [("1 km", 1000.0), ("5 km", 5000.0), ("10 km", 10_000.0), ("Half", 21_097.5), ("Marathon", 42_195.0)] {
            guard let total = stream.last?.d, total >= target else { continue }
            var fastest = Double.infinity
            var j = 0
            for i in stream.indices {
                while j < stream.count && stream[j].d - stream[i].d < target { j += 1 }
                if j == stream.count { break }
                fastest = min(fastest, stream[j].t - stream[i].t)
            }
            if fastest.isFinite { bests.append(Best(id: label, distance: target, seconds: fastest)) }
        }
        self.bests = bests
    }
}
