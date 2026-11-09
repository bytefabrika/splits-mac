import SwiftData
import SwiftUI

@main
struct SplitsApp: App {
    let container: ModelContainer

    init() {
        container = try! ModelContainer(for: Activity.self, Day.self)
        #if DEBUG
        // `SPLITS_KEY=… Splits --sync-test` runs a full sync into a throwaway store and prints what came back.
        if CommandLine.arguments.contains("--sync-test") { DebugSync.run() }
        // `Splits --fit-test < activity.zip` decodes a Garmin download (ZIP or FIT) from stdin.
        if CommandLine.arguments.contains("--fit-test") { DebugSync.fit() }
        // `Splits --coach-test` writes a take on the newest activity in the real store and prints it. Saves nothing.
        if CommandLine.arguments.contains("--coach-test") { DebugSync.coach(container: container) }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(container)
        .defaultSize(width: 1100, height: 720)

        Settings {
            SettingsView()
                .modelContainer(container)
        }
    }
}

#if DEBUG
enum DebugSync {
    static func fit() {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let started = Date()
        do {
            let fitData = input.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04])
                ? try Zip.entries(input).first { $0.name.lowercased().hasSuffix(".fit") }?.data ?? Data()
                : input
            let track = try FIT.decode(fitData)
            let p = track.points
            print("decoded \(fitData.count) bytes in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            print("points \(p.count), with GPS \(p.filter { $0.coordinate != nil }.count), HR \(p.filter { $0.heartRate != nil }.count), altitude \(p.filter { $0.altitude != nil }.count), power \(p.filter { $0.power != nil }.count), cadence \(p.filter { $0.cadence != nil }.count)")
            print("time \(p.first?.time.description ?? "-") → \(p.last?.time.description ?? "-")")
            print("distance \(p.compactMap(\.distance).max() ?? 0) m, max HR \(p.compactMap(\.heartRate).max() ?? 0), altitude \(p.compactMap(\.altitude).min() ?? 0)…\(p.compactMap(\.altitude).max() ?? 0) m")
            if let c = p.first(where: { $0.coordinate != nil })?.coordinate { print(String(format: "first GPS fix %.3f, %.3f", c.latitude, c.longitude)) }
            let analysis = TrackAnalysis(track)
            print("our splits: " + analysis.splits.prefix(6).map { Format.duration($0.seconds) }.joined(separator: ", "))
            print("watch laps: " + track.laps.prefix(6).map { Format.duration($0.moving ?? 0) }.joined(separator: ", "))
            print("bests: " + analysis.bests.map { "\($0.id) \(Format.duration($0.seconds))" }.joined(separator: ", "))
            print("laps \(track.laps.count): " + track.laps.prefix(3).map { "\(Int($0.distance ?? 0)) m in \(Int($0.moving ?? 0)) s, HR \(Int($0.averageHR ?? 0))" }.joined(separator: " | "))
        } catch {
            print("failed: \(error)")
        }
        exit(0)
    }

    static func coach(container: ModelContainer) {
        Task { @MainActor in
            print("model status: \(Coach.status)")
            var latest = FetchDescriptor<Activity>(predicate: #Predicate { $0.distance > 1000 }, sortBy: [SortDescriptor(\.start, order: .reverse)])
            latest.fetchLimit = 1
            guard let activity = try? container.mainContext.fetch(latest).first else { print("no activities in the store"); exit(0) }
            var recentQuery = FetchDescriptor<Activity>(sortBy: [SortDescriptor(\.start, order: .reverse)])
            recentQuery.fetchLimit = 60
            let recent = (try? container.mainContext.fetch(recentQuery)) ?? []
            let date = GarminDate.string(activity.start)
            let morning = (try? container.mainContext.fetch(FetchDescriptor<Day>(predicate: #Predicate { $0.date == date })))?.first
            let analysis = (try? await Tracks.shared.track(for: activity.garminId)).map { TrackAnalysis($0) }
            let facts = Coach.facts(activity: activity, analysis: analysis, recent: recent, morning: morning, format: Format(units: "metric"))
            print("---- facts (\(facts.count) chars) ----\n\(facts)\n---- take ----")
            let started = Date()
            var final = ""
            do {
                try await Coach.write(facts: facts) { final = $0 }
                print(final)
                print("---- \(String(format: "%.1f", Date().timeIntervalSince(started))) s, \(final.split(separator: " ").count) words")
            } catch {
                print("failed: \(error)")
            }
            exit(0)
        }
    }

    static func run() {
        let key = ProcessInfo.processInfo.environment["SPLITS_KEY"]
        Task { @MainActor in
            let container = try! ModelContainer(for: Activity.self, Day.self,
                                                configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            let sync = Sync(client: GarminClient(key: { key }), context: container.mainContext,
                            defaults: UserDefaults(suiteName: "splits-sync-test")!)
            let started = Date()
            await sync.run()
            let activities = try! container.mainContext.fetch(FetchDescriptor<Activity>(sortBy: [SortDescriptor(\.start)]))
            let days = try! container.mainContext.fetch(FetchDescriptor<Day>(sortBy: [SortDescriptor(\.date)]))
            print("state: \(sync.state)  units: \(sync.units)  took \(Int(Date().timeIntervalSince(started)))s")
            print("activities: \(activities.count), first \(activities.first?.start.description ?? "-"), last \(activities.last?.start.description ?? "-")")
            print("sports: \(Dictionary(grouping: activities, by: \.sport.rawValue).mapValues(\.count))")
            print("types: \(Set(activities.map(\.typeKey)).sorted())")
            print("days: \(days.count), \(days.first?.date ?? "-") → \(days.last?.date ?? "-")")
            print("with sleep \(days.filter { $0.sleepSeconds != nil }.count), hrv \(days.filter { $0.hrvLastNight != nil }.count), body battery \(days.filter { $0.bodyBatteryHigh != nil }.count), resting HR \(days.filter { $0.restingHR != nil }.count), steps \(days.filter { $0.steps != nil }.count)")
            if let d = days.last(where: { $0.sleepSeconds != nil }) {
                print("latest night \(d.date): sleep \(d.sleepSeconds! / 60) min, score \(d.sleepScore ?? -1), HRV \(d.hrvLastNight ?? -1) (\(d.hrvStatus ?? "-")), BB \(d.bodyBatteryLow ?? -1)–\(d.bodyBatteryHigh ?? -1), start \(d.sleepStart?.description ?? "-")")
            }
            exit(0)
        }
    }
}
#endif
