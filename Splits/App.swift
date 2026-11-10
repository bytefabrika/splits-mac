import MapKit
import SwiftData
import SwiftUI

@main
struct SplitsApp: App {
    let container: ModelContainer
    /// Today's live numbers for the menu bar and the widgets.
    @State private var live: LiveToday
    @State private var sync: Sync
    /// Syncs in the background, writes the morning briefing and notification, and feeds the widgets.
    @State private var mornings: Mornings

    init() {
        let container = try! ModelContainer(for: Activity.self, Day.self)
        self.container = container
        let live = LiveToday()
        let sync = Sync(context: container.mainContext)
        _live = State(initialValue: live)
        _sync = State(initialValue: sync)
        _mornings = State(initialValue: Mornings(sync: sync, live: live, context: container.mainContext))
        // The heatmap's route files, from before the Explorer replaced it.
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            try? FileManager.default.removeItem(at: support.appendingPathComponent("Routes", isDirectory: true))
        }
        #if DEBUG
        // `SPLITS_KEY=… Splits --sync-test` runs a full sync into a throwaway store and prints what came back.
        if CommandLine.arguments.contains("--sync-test") { DebugSync.run() }
        // `Splits --fit-test < activity.zip` decodes a Garmin download (ZIP or FIT) from stdin.
        if CommandLine.arguments.contains("--fit-test") { DebugSync.fit() }
        // `Splits --coach-test` writes a take on the newest activity in the real store and prints it. Saves nothing.
        if CommandLine.arguments.contains("--coach-test") { DebugSync.coach(container: container) }
        // `Splits --map-test < activity.zip > map.png`: the still map with the route drawn on, to check they line up.
        if CommandLine.arguments.contains("--map-test") { DebugSync.map() }
        // `Splits --countries-test` prints the countries of the activities in the real store.
        if CommandLine.arguments.contains("--countries-test") { DebugSync.countries(container: container) }
        // `SPLITS_KEY=… Splits --progress-test` prints aerobic form, streaks, and the bests of the 3 newest outdoor runs.
        if CommandLine.arguments.contains("--progress-test") { DebugSync.progress(container: container) }
        // `Splits --daily-test` prints this morning's facts and the briefing written from them. Saves nothing.
        if CommandLine.arguments.contains("--daily-test") { DebugSync.daily(container: container) }
        // `Splits --widget-test` prints the snapshot the widgets read.
        if CommandLine.arguments.contains("--widget-test") {
            if let s = WidgetSnapshot.load() {
                print("updated \(s.updated), battery \(s.bodyBattery ?? -1) (curve \(s.batteryCurve.count)), sleep \(s.sleepSeconds ?? -1), hrv \(s.hrv ?? -1), steps \(s.steps ?? -1)")
                print("week \(s.week.map { Int($0.metres) }), runs \(s.weekActivities)")
                print("briefing: \(s.briefingHeadline ?? "–") | \(s.verdict ?? "–") | \(s.plan ?? "–")")
            } else { print("no snapshot") }
            let context = container.mainContext
            let key = GarminDate.string(Date())
            do {
                let found = try context.fetch(FetchDescriptor<Day>(predicate: #Predicate { $0.date == key }))
                print("fetch \(key): \(found.count) days, sleep \(found.first?.sleepSeconds ?? -1), bb \(found.first?.bodyBatteryLatest ?? -1)")
            } catch { print("fetch failed: \(error)") }
            let all = (try? context.fetch(FetchDescriptor<Day>(sortBy: [SortDescriptor(\.date, order: .reverse)]))) ?? []
            print("newest days: \(all.prefix(3).map { "\($0.date) sleep \($0.sleepSeconds ?? -1)" })")
            print("defaults: \(UserDefaults.standard.string(forKey: DailyBriefing.dateKey) ?? "–") notified \(UserDefaults.standard.string(forKey: DailyBriefing.notifiedKey) ?? "–")")
            exit(0)
        }
        // `Splits --trends-test > trends.png`: the Trends calendar and summary with the real store, to look at.
        if CommandLine.arguments.contains("--trends-test") { DebugSync.trends(container: container) }
        // `Splits --card-test < activity.zip > card.png`: the share card for the newest activity, with that file's route.
        if CommandLine.arguments.contains("--card-test") { DebugSync.card(container: container) }
        #endif
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView(sync: sync)
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

    static func countries(container: ModelContainer) {
        let all = (try? ModelContext(container).fetch(FetchDescriptor<Activity>())) ?? []
        let points = all.compactMap { a -> Travels.Point? in
            guard !Sport.isIndoor(a.typeKey), let lat = a.startLatitude, let lon = a.startLongitude else { return nil }
            return Travels.Point(id: a.garminId, start: a.start, lat: lat, lon: lon, distance: a.distance)
        }
        let started = Date()
        let t = Travels(points: points)
        print("\(all.count) activities, \(points.count) with a start point, \(t.located) placed in \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
        for v in t.visits { print("  \(v.country.flag) \(v.country.name): \(v.count)×, first \(GarminDate.string(v.first))") }
        for y in t.years { print("  \(y.year): \(y.countries.map(\.name).joined(separator: ", "))") }
        print("  \(t.legs.count) crossings, \(t.cities.count) cities")
        for v in t.cities.sorted(by: { $0.count > $1.count }).prefix(25) { print("    \(v.country.flag) \(v.city.name): \(v.count)×") }
        for y in t.years { print("  \(y.year): \(y.cities) cities, \(y.newCities) new") }
        exit(0)
    }

    static func progress(container: ModelContainer) {
        let context = ModelContext(container)
        let all = (try? context.fetch(FetchDescriptor<Activity>(sortBy: [SortDescriptor(\.start, order: .reverse)]))) ?? []
        let days = (try? context.fetch(FetchDescriptor<Day>())) ?? []
        let resting = days.compactMap(\.restingHR).sorted()
        let format = Format(units: "metric")
        let form = AerobicForm(runs: all, resting: resting.isEmpty ? nil : Double(resting[resting.count / 2]))
        print("Form: \(form.points.count) runs, reference \(form.reference) bpm, resting \(Int(form.resting))")
        for months in [0, 3, 6, 12, 24, 36] {
            let d = Calendar.current.date(byAdding: .month, value: -months, to: Date())!
            print("  \(months) months ago: \(form.trend(at: d).map { format.pace(secondsPerKm: $0) } ?? "–")")
        }
        let s = Streaks(dates: all.map(\.start))
        print("Streaks: \(s.currentDays) days now, longest \(s.longestDays) (ended \(s.longestDaysEnd.map { GarminDate.string($0) } ?? "–")); \(s.currentWeeks) weeks with 3+, longest \(s.longestWeeks); this week \(s.thisWeek), best week \(s.bestWeek)")
        let runs = Array(Records.candidates(all).prefix(3))
        Task {
            let stored = await RecordStore.shared.all()
            let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.garminId, $0.start) })
            let efforts = stored.flatMap { id, bests in bests.compactMap { label, seconds in byID[id].map { (id, $0, label, seconds) } } }
            let predictor = RacePredictor(efforts: efforts)
            print("Records looked at: \(stored.count). Predictions (last \(predictor.months) months):")
            for p in predictor.predictions {
                print("  \(p.label): \(Format.duration(p.seconds)) from \(p.source.label) \(Format.duration(p.source.seconds)) on \(GarminDate.string(p.source.date))")
            }
            for r in runs {
                let started = Date()
                do {
                    try await RecordStore.shared.find(r.garminId)
                    let bests = await RecordStore.shared.all()[r.garminId] ?? [:]
                    print("  \(r.name) \(format.distance(r.distance)) (\(String(format: "%.1f", Date().timeIntervalSince(started))) s): " + Records.distances.compactMap { d in bests[d.label].map { "\(d.label) \(Format.duration($0))" } }.joined(separator: ", "))
                } catch { print("  \(r.garminId) failed: \(error)") }
            }
            await RecordStore.shared.flush()
            exit(0)
        }
        RunLoop.main.run()
    }

    static func daily(container: ModelContainer) {
        let context = ModelContext(container)
        let activities = (try? context.fetch(FetchDescriptor<Activity>(sortBy: [SortDescriptor(\.start, order: .reverse)]))) ?? []
        let days = (try? context.fetch(FetchDescriptor<Day>(sortBy: [SortDescriptor(\.date, order: .reverse)]))) ?? []
        let facts = Coach.dailyFacts(activities: activities, days: days, format: Format(units: "metric"))
        print(facts + "\n---")
        Task { @MainActor in
            do {
                var last = ""
                try await Coach.write(facts: facts, instructions: Coach.dailyInstructions, temperature: 0.4) { last = $0 }
                print(last)
            } catch { print("Coach: \(error) – \(Coach.status)") }
            exit(0)
        }
        RunLoop.main.run()
    }

    @MainActor
    static func trends(container: ModelContainer) {
        let all = (try? ModelContext(container).fetch(FetchDescriptor<Activity>())) ?? []
        let year = all.filter { $0.start > Date().addingTimeInterval(-365 * 86_400) }
        let format = Format(units: "metric")
        let view = VStack(alignment: .leading, spacing: 28) {
            Panel(title: "Summary", subtitle: "The last 1 year") {
                MetricRow(metrics: [
                    Metric(label: "Activities", symbol: "figure.mixed.cardio", tint: Sport.run.color, value: year.count.formatted()),
                    Metric(label: "Distance", symbol: "point.topleft.down.to.point.bottomright.curvepath", tint: Sport.ride.color, value: format.distance(year.reduce(0) { $0 + $1.distance }, decimals: 0)),
                    Metric(label: "Time moving", symbol: "stopwatch", tint: Sport.swim.color, value: "259 h"),
                    Metric(label: "Climbed", symbol: "mountain.2", tint: Sport.hike.color, value: "7,403 m"),
                    Metric(label: "Sleep", symbol: "bed.double", tint: .indigo, value: "6 h 43 min", note: "a night on average"),
                    Metric(label: "HRV", symbol: "waveform.path.ecg", tint: .teal, value: "75 ms", note: "overnight average"),
                ])
            }
            ActivityCalendar(activities: all)
            Panel(title: "Records", subtitle: "In the last 1 year") {
                HStack { RecordCell(title: "Longest run", value: "32.75 km", activity: all.first); RecordCell(title: "Biggest climb", value: "1,204 m", activity: all.last) }
            }
        }
        .padding(24)
        .frame(width: 1180)
        .background(Color(nsColor: .windowBackgroundColor))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1.5
        if let tiff = renderer.nsImage?.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            FileHandle.standardOutput.write(png)
        }
        exit(0)
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
