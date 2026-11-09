import CoreLocation
import Foundation
import Observation

/// Every outdoor route, thinned to a point every ~15 m and kept as small binary files (Float32 lat/lon pairs),
/// for the heatmap. A route needs the activity's FIT file once; the FIT itself isn't kept unless the activity
/// was opened (that's `Tracks`' cache).
actor RouteStore {
    static let shared = RouteStore()
    static let spacing: Double = 15  // metres between kept points

    private let client: GarminClient
    private let folder: URL
    private let fitFolder: URL

    init(client: GarminClient = .shared,
         base: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]) {
        self.client = client
        folder = base.appendingPathComponent("Routes", isDirectory: true)
        fitFolder = base.appendingPathComponent("Activities", isDirectory: true)
    }

    /// Activities whose route has been worked out (including ones that turned out to have no GPS).
    func doneIDs() -> Set<Int64> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return Set(names.compactMap { Int64($0.replacingOccurrences(of: ".route", with: "")) })
    }

    func load(_ ids: [Int64]) -> [Int64: [CLLocationCoordinate2D]] {
        var routes: [Int64: [CLLocationCoordinate2D]] = [:]
        for id in ids {
            guard let data = try? Data(contentsOf: file(id)), data.count >= 8 else { continue }
            routes[id] = Self.decode(data)
        }
        return routes
    }

    /// Fetches, decodes and thins one route. An empty file marks "no GPS", so it isn't tried again.
    func build(_ id: Int64) async throws {
        if FileManager.default.fileExists(atPath: file(id).path) { return }
        let fit: Data
        if let cached = try? Data(contentsOf: fitFolder.appendingPathComponent("\(id).fit")) {
            fit = cached
        } else {
            let download = try await client.activityFile(id)
            fit = download.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04])
                ? try Zip.entries(download).first { $0.name.lowercased().hasSuffix(".fit") }?.data ?? Data()
                : download
        }
        let points = (try? FIT.decode(fit))?.points.compactMap(\.coordinate) ?? []
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.encode(Self.thin(points)).write(to: file(id), options: .atomic)
    }

    func removeAll() { try? FileManager.default.removeItem(at: folder) }

    private func file(_ id: Int64) -> URL { folder.appendingPathComponent("\(id).route") }

    /// Keeps a point once it's `spacing` metres from the last kept one (equirectangular distance: fine at this scale).
    static func thin(_ points: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        guard var last = points.first else { return [] }
        var kept = [last]
        for p in points.dropFirst() {
            let dLat = (p.latitude - last.latitude) * 111_320
            let dLon = (p.longitude - last.longitude) * 111_320 * cos(last.latitude * .pi / 180)
            if dLat * dLat + dLon * dLon >= spacing * spacing {
                kept.append(p)
                last = p
            }
        }
        if let end = points.last, kept.count > 1 { kept.append(end) }
        return kept
    }

    static func encode(_ points: [CLLocationCoordinate2D]) -> Data {
        var floats: [Float32] = []
        floats.reserveCapacity(points.count * 2)
        for p in points { floats.append(Float32(p.latitude)); floats.append(Float32(p.longitude)) }
        return floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func decode(_ data: Data) -> [CLLocationCoordinate2D] {
        data.withUnsafeBytes { raw in
            let floats = raw.bindMemory(to: Float32.self)
            return stride(from: 0, to: floats.count - 1, by: 2).map {
                CLLocationCoordinate2D(latitude: Double(floats[$0]), longitude: Double(floats[$0 + 1]))
            }
        }
    }
}

/// Fills the route store in the background, one activity at a time, and can be paused and resumed.
@MainActor
@Observable
final class RouteBuilder {
    static let shared = RouteBuilder()

    private(set) var done = 0
    private(set) var total = 0
    private(set) var running = false
    private(set) var problem: String?
    /// Bumped every few routes so the heatmap can redraw while it fills in.
    private(set) var version = 0
    private var task: Task<Void, Never>?

    var progress: Double { total > 0 ? Double(done) / Double(total) : 0 }
    var finished: Bool { total > 0 && done >= total }

    /// Counts what's missing without fetching anything.
    func refreshCounts(_ ids: [Int64]) async {
        let have = await RouteStore.shared.doneIDs()
        total = ids.count
        done = ids.filter { have.contains($0) }.count
    }

    func start(_ ids: [Int64]) {
        guard !running else { return }
        running = true
        problem = nil
        task = Task {
            let have = await RouteStore.shared.doneIDs()
            total = ids.count
            done = ids.filter { have.contains($0) }.count
            for id in ids where !have.contains(id) {
                if Task.isCancelled { break }
                do {
                    try await RouteStore.shared.build(id)
                    done += 1
                    if done % 20 == 0 { version += 1 }
                } catch is CancellationError {
                    break
                } catch {
                    problem = error.localizedDescription
                    break
                }
            }
            version += 1
            running = false
        }
    }

    func pause() {
        task?.cancel()
        task = nil
        running = false
        version += 1
    }
}
