import MapKit
import SwiftData
import SwiftUI

@main
struct SplitsApp: App {
    let container: ModelContainer
    /// Today's live numbers for the menu bar.
    @State private var live = LiveToday()

    init() {
        container = try! ModelContainer(for: Activity.self, Day.self)
        #if DEBUG
        // `SPLITS_KEY=… Splits --sync-test` runs a full sync into a throwaway store and prints what came back.
        if CommandLine.arguments.contains("--sync-test") { DebugSync.run() }
        // `Splits --fit-test < activity.zip` decodes a Garmin download (ZIP or FIT) from stdin.
        if CommandLine.arguments.contains("--fit-test") { DebugSync.fit() }
        // `Splits --coach-test` writes a take on the newest activity in the real store and prints it. Saves nothing.
        if CommandLine.arguments.contains("--coach-test") { DebugSync.coach(container: container) }
        // `Splits --map-test < activity.zip > map.png`: the still map with the route drawn on, to check they line up.
        if CommandLine.arguments.contains("--map-test") { DebugSync.map() }
        // `SPLITS_KEY=… Splits --routes-test` builds routes for the 10 newest outdoor activities in the store.
        if CommandLine.arguments.contains("--routes-test") { DebugSync.routes(container: container) }
        // `Splits --card-test < activity.zip > card.png`: the share card for the newest activity, with that file's route.
        if CommandLine.arguments.contains("--card-test") { DebugSync.card(container: container) }
        // `Splits --story-test > story.png`: every Year in Sport slide for this year, side by side.
        if CommandLine.arguments.contains("--story-test") { DebugSync.story(container: container) }
        #endif
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
        }
        .modelContainer(container)
        .defaultSize(width: 1100, height: 720)

        MenuBarExtra {
            MenuBarPanel(live: live)
                .modelContainer(container)
        } label: {
            MenuBarLabel(live: live)
        }
        .menuBarExtraStyle(.window)

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

    static func map() {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        Task { @MainActor in
            let fitData = (try? Zip.entries(input).first { $0.name.lowercased().hasSuffix(".fit") }?.data) ?? input
            guard let track = try? FIT.decode(fitData) else { FileHandle.standardError.write(Data("bad file\n".utf8)); exit(1) }
            let analysis = TrackAnalysis(track)
            let size = CGSize(width: 900, height: 380)
            guard let rect = RouteSnapshot.fittedRect(analysis.route, size: size) else { exit(1) }
            let options = MKMapSnapshotter.Options()
            options.mapRect = rect
            options.size = size
            options.pointOfInterestFilter = .excludingAll
            let shot = try? await MKMapSnapshotter(options: options).start()
            let image = NSImage(size: size)
            image.lockFocus()
            shot?.image.draw(in: NSRect(origin: .zero, size: size))
            let path = NSBezierPath()
            for (i, c) in analysis.route.enumerated() {
                let p = MKMapPoint(c)
                // Same projection as RouteSnapshot; AppKit's y goes up, so flip it here.
                let point = NSPoint(x: (p.x - rect.minX) / rect.width * size.width,
                                    y: size.height - (p.y - rect.minY) / rect.height * size.height)
                if i == 0 { path.move(to: point) } else { path.line(to: point) }
            }
            NSColor.systemRed.setStroke()
            path.lineWidth = 3
            path.stroke()
            image.unlockFocus()
            let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
            FileHandle.standardOutput.write(png)
            exit(0)
        }
    }

    static func routes(container: ModelContainer) {
        Task { @MainActor in
            let all = (try? container.mainContext.fetch(FetchDescriptor<Activity>(sortBy: [SortDescriptor(\.start, order: .reverse)]))) ?? []
            let withCoordinates = all.filter { $0.startLatitude != nil }.count
            let picked = Array(all.filter { $0.distance > 0 && !Sport.isIndoor($0.typeKey) && [.run, .ride].contains($0.sport) }.prefix(10))
            print("activities \(all.count), with start coordinates \(withCoordinates), picked \(picked.count)")
            let started = Date()
            for a in picked {
                do { try await RouteStore.shared.build(a.garminId) } catch { print("  \(a.garminId) failed: \(error)") }
            }
            let routes = await RouteStore.shared.load(picked.map(\.garminId))
            for a in picked {
                print("  \(a.typeKey) \(Int(a.distance)) m → \(routes[a.garminId]?.count ?? 0) points")
            }
            print("took \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
            exit(0)
        }
    }

    static func card(container: ModelContainer) {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        Task { @MainActor in
            let fitData = (try? Zip.entries(input).first { $0.name.lowercased().hasSuffix(".fit") }?.data) ?? input
            let route = (try? FIT.decode(fitData)).map { TrackAnalysis($0).route } ?? []
            var latest = FetchDescriptor<Activity>(predicate: #Predicate { $0.distance > 20_000 }, sortBy: [SortDescriptor(\.start, order: .reverse)])
            latest.fetchLimit = 1
            guard let activity = try? container.mainContext.fetch(latest).first,
                  let png = ShareCard.png(activity: activity, route: route, format: Format(units: "metric")) else { exit(1) }
            FileHandle.standardOutput.write(png)
            exit(0)
        }
    }

    static func story(container: ModelContainer) {
        Task { @MainActor in
            let activities = (try? container.mainContext.fetch(FetchDescriptor<Activity>())) ?? []
            let days = (try? container.mainContext.fetch(FetchDescriptor<Day>())) ?? []
            let year = Calendar.current.component(.year, from: Date())
            let stats = YearStats(year: year, activities: activities, days: days)
            let format = Format(units: "metric")
            let count = YearStory(stats: stats, format: format).slideCount
            let size = CGSize(width: 820, height: 860), columns = 5
            let rows = (count + columns - 1) / columns
            let sheet = NSImage(size: CGSize(width: size.width * CGFloat(columns) / 2, height: size.height * CGFloat(rows) / 2))
            sheet.lockFocus()
            for i in 0..<count {
                let renderer = ImageRenderer(content: YearStory(stats: stats, format: format, startAt: i).frame(width: size.width, height: size.height))
                renderer.scale = 1
                guard let image = renderer.nsImage else { continue }
                let x = CGFloat(i % columns) * size.width / 2, y = CGFloat(rows - 1 - i / columns) * size.height / 2
                image.draw(in: NSRect(x: x, y: y, width: size.width / 2, height: size.height / 2))
            }
            sheet.unlockFocus()
            let png = NSBitmapImageRep(data: sheet.tiffRepresentation!)!.representation(using: .png, properties: [:])!
            FileHandle.standardOutput.write(png)
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
