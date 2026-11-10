import Foundation

/// What the widgets show, written by the app into the shared App Group folder. The widgets never talk to
/// Garmin themselves: the app (or its menu bar) refreshes this when it syncs.
struct WidgetSnapshot: Codable {
    struct Point: Codable { let time: Date; let value: Double }
    struct WeekDay: Codable { let day: Date; let metres: Double; let seconds: Double }

    var updated: Date
    var imperial: Bool

    // Body Battery today
    var bodyBattery: Int?
    var bodyBatteryHigh: Int?
    var bodyBatteryLow: Int?
    var batteryCurve: [Point]

    // Last night
    var sleepSeconds: Int?
    var sleepScore: Int?
    var deepSeconds: Int?
    var lightSeconds: Int?
    var remSeconds: Int?
    var awakeSeconds: Int?
    var hrv: Int?
    var hrvStatus: String?

    // Today
    var steps: Int?
    var stepGoal: Int?
    var stressAverage: Int?

    // This week, Monday first
    var week: [WeekDay]
    var weekActivities: Int

    // This morning's briefing: the headline the model wrote, and the verdict and plan worked out in code.
    var briefingHeadline: String?
    var verdict: String?
    var plan: String?

    static let appGroup = "SH5W9F58G9.com.bytefabrika.splits"

    static var file: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("snapshot.json")
    }

    static func load() -> WidgetSnapshot? {
        guard let file, let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    func save() {
        guard let file = Self.file else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(self).write(to: file, options: .atomic)
    }

    static let placeholder = WidgetSnapshot(
        updated: Date(), imperial: false, bodyBattery: 72, bodyBatteryHigh: 88, bodyBatteryLow: 24,
        batteryCurve: (0..<24).map { Point(time: Calendar.current.startOfDay(for: Date()).addingTimeInterval(Double($0) * 1800), value: 30 + Double($0) * 2.4) },
        sleepSeconds: 26_400, sleepScore: 81, deepSeconds: 4_800, lightSeconds: 14_400, remSeconds: 6_000, awakeSeconds: 1_200,
        hrv: 62, hrvStatus: "BALANCED", steps: 7_412, stepGoal: 10_000, stressAverage: 28,
        week: (0..<7).map { WeekDay(day: Date().addingTimeInterval(Double($0 - 6) * 86_400), metres: [8000, 0, 10_000, 0, 6_000, 21_000, 0][$0], seconds: 3000) },
        weekActivities: 4,
        briefingHeadline: "🔋 Fully charged and ready to roll", verdict: "Well recovered",
        plan: "Room for a harder session today."
    )
}
