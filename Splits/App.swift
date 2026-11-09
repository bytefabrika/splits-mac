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
