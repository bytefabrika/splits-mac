import AppKit
import Foundation
import Observation
import SwiftData
import UserNotifications
import WidgetKit

/// This morning's briefing, kept in UserDefaults for the day. The Today card and the morning service both
/// write it; whichever gets there first.
@MainActor
enum DailyBriefing {
    static let dateKey = "dailyBriefReportDate", textKey = "dailyBriefReportText", notifiedKey = "dailyBriefNotified"
    /// Whether today's briefing was written with last night's sleep in. One written before (from the button)
    /// is written again once the sleep arrives.
    static let hadSleepKey = "dailyBriefHadSleep"

    static var today: String { GarminDate.string(Date()) }

    static var text: String? {
        let d = UserDefaults.standard
        guard d.string(forKey: dateKey) == today, let text = d.string(forKey: textKey), !text.isEmpty else { return nil }
        return text
    }

    /// The model's first line, without markdown or quotes: "🌙 Partly recovered, HRV drama!"
    static func headline(_ text: String) -> String {
        let first = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        return Coach.withoutDashes(first.trimmingCharacters(in: CharacterSet(charactersIn: "#*\"“”_ ")))
    }

    static func facts(_ context: ModelContext, format: Format) -> String {
        let activities = (try? context.fetch(FetchDescriptor<Activity>(sortBy: [SortDescriptor(\.start, order: .reverse)]))) ?? []
        let since = GarminDate.string(Calendar.current.date(byAdding: .day, value: -15, to: Date())!)
        let days = (try? context.fetch(FetchDescriptor<Day>(predicate: #Predicate { $0.date >= since }, sortBy: [SortDescriptor(\.date, order: .reverse)]))) ?? []
        return Coach.dailyFacts(activities: activities, days: days, format: format)
    }

    static func sleepSynced(_ context: ModelContext) -> Bool {
        let today = today
        let day = try? context.fetch(FetchDescriptor<Day>(predicate: #Predicate { $0.date == today })).first
        return day?.sleepSeconds != nil
    }

    /// No briefing today yet, or only one from before last night's sleep had synced.
    static func needsWriting(_ context: ModelContext) -> Bool {
        text == nil || (!UserDefaults.standard.bool(forKey: hadSleepKey) && sleepSynced(context))
    }

    static func write(_ context: ModelContext, format: Format) async throws {
        var text = ""
        let hadSleep = sleepSynced(context)
        try await Coach.write(facts: facts(context, format: format), instructions: Coach.dailyInstructions, temperature: 0.4) { text = $0 }
        save(text.trimmingCharacters(in: .whitespacesAndNewlines), hadSleep: hadSleep)
    }

    static func save(_ text: String, hadSleep: Bool) {
        let d = UserDefaults.standard
        d.set(text, forKey: textKey)
        d.set(today, forKey: dateKey)
        d.set(hadSleep, forKey: hadSleepKey)
        // Written while you're looking at the app: you've seen it, no notification needed.
        if NSApp?.isActive == true { d.set(today, forKey: notifiedKey) }
    }
}

/// Keeps things fresh while Splits runs (the menu bar keeps it running with the window closed): syncs about
/// hourly, more often in the morning until last night's sleep is in, then writes the daily briefing, sends it as
/// a notification, and updates the widgets.
@MainActor
@Observable
final class Mornings {
    private let sync: Sync
    private let live: LiveToday
    private let context: ModelContext
    private var timer: Timer?
    private var busy = false
    private var observer: NSObjectProtocol?
    private var pendingSnapshot: Task<Void, Never>?

    static let notifyKey = "morningNotification"
    static var notifyEnabled: Bool { UserDefaults.standard.object(forKey: notifyKey) as? Bool ?? true }

    init(sync: Sync, live: LiveToday, context: ModelContext) {
        self.sync = sync
        self.live = live
        self.context = context
        // Unit tests and the debug command-line modes launch the app too; leave Garmin alone then.
        let args = CommandLine.arguments.dropFirst()
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              !args.contains(where: { $0.hasSuffix("-test") }) else { return }
        // Redraw the widgets whenever new data comes in, a second later so a sync and a live refresh landing
        // together only write once.
        observer = NotificationCenter.default.addObserver(forName: .splitsDataChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.pendingSnapshot?.cancel()
                self.pendingSnapshot = Task {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { return }
                    self.writeSnapshot(format: Format(units: self.sync.units))
                }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 10 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        Task {
            try? await Task.sleep(for: .seconds(8))
            await tick()
        }
    }

    func tick() async {
        guard !busy, Keychain.readKey() != nil else { return }
        busy = true
        defer { busy = false }
        let hour = Calendar.current.component(.hour, from: Date())
        let morning = (4..<14).contains(hour)
        let format = Format(units: sync.units)

        // A sync already under way (the window's sync on launch): wait for it rather than skip the morning.
        while sync.isRunning { try? await Task.sleep(for: .seconds(2)) }
        let age = sync.lastSync.map { Date().timeIntervalSince($0) } ?? .infinity
        let waitingForSleep = morning && !DailyBriefing.sleepSynced(context)
        if !sync.isRunning, age > 3600 || (waitingForSleep && age > 15 * 60) { await sync.run() }
        await live.refresh()

        if morning, DailyBriefing.needsWriting(context), DailyBriefing.sleepSynced(context), Coach.status == .ready {
            try? await DailyBriefing.write(context, format: format)
        }
        if morning, let text = DailyBriefing.text, Self.notifyEnabled, UserDefaults.standard.bool(forKey: DailyBriefing.hadSleepKey),
           UserDefaults.standard.string(forKey: DailyBriefing.notifiedKey) != DailyBriefing.today {
            await notify(text, format: format)
        }
        writeSnapshot(format: format)
    }

    private func notify(_ text: String, format: Format) async {
        UserDefaults.standard.set(DailyBriefing.today, forKey: DailyBriefing.notifiedKey)
        if NSApp?.isActive == true { return }
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        let content = UNMutableNotificationContent()
        content.title = DailyBriefing.headline(text)
        content.body = Coach.dailyAssessment(DailyBriefing.facts(context, format: format))?.plan ?? ""
        content.sound = .default
        try? await center.add(UNNotificationRequest(identifier: "briefing-\(DailyBriefing.today)", content: content, trigger: nil))
    }

    /// What the widgets show, into the shared App Group folder, then asks them to redraw.
    func writeSnapshot(format: Format) {
        let calendar = Calendar.current
        let todayKey = DailyBriefing.today
        let today = try? context.fetch(FetchDescriptor<Day>(predicate: #Predicate { $0.date == todayKey })).first
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: Date())!.start
        let runs = ((try? context.fetch(FetchDescriptor<Activity>(predicate: #Predicate { $0.start >= weekStart })) ) ?? [])
            .filter { $0.sport == .run }
        let week = (0..<7).map { i -> WidgetSnapshot.WeekDay in
            let day = calendar.date(byAdding: .day, value: i, to: weekStart)!
            let those = runs.filter { calendar.isDate($0.start, inSameDayAs: day) }
            return WidgetSnapshot.WeekDay(day: day, metres: those.reduce(0) { $0 + $1.distance }, seconds: those.reduce(0) { $0 + $1.activeSeconds })
        }
        let curve = live.battery
        let step = max(curve.count / 96, 1)
        let assessment = DailyBriefing.text.flatMap { _ in Coach.dailyAssessment(DailyBriefing.facts(context, format: format)) }

        let snapshot = WidgetSnapshot(
            updated: Date(), imperial: format.imperial,
            bodyBattery: live.currentBattery ?? today?.bodyBatteryLatest,
            bodyBatteryHigh: today?.bodyBatteryHigh, bodyBatteryLow: today?.bodyBatteryLow,
            batteryCurve: stride(from: 0, to: curve.count, by: step).map { WidgetSnapshot.Point(time: curve[$0].0, value: curve[$0].1) },
            sleepSeconds: today?.sleepSeconds, sleepScore: today?.sleepScore, deepSeconds: today?.deepSeconds,
            lightSeconds: today?.lightSeconds, remSeconds: today?.remSeconds, awakeSeconds: today?.awakeSeconds,
            hrv: today?.hrvLastNight, hrvStatus: today?.hrvStatus,
            steps: live.steps ?? today?.steps, stepGoal: live.stepGoal ?? today?.stepGoal,
            stressAverage: live.stress.average ?? today?.stressAvg,
            week: week, weekActivities: runs.count,
            // A headline written before last night synced would talk about nothing; the widget waits instead.
            briefingHeadline: UserDefaults.standard.bool(forKey: DailyBriefing.hadSleepKey) ? DailyBriefing.text.map(DailyBriefing.headline) : nil,
            verdict: assessment?.verdict, plan: assessment?.plan)
        snapshot.save()
        WidgetCenter.shared.reloadAllTimelines()
    }
}
