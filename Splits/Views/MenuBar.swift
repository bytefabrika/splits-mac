import Charts
import Observation
import SwiftData
import SwiftUI

/// Today, live, for the menu bar: Body Battery and heart rate through the day, stress, steps.
/// Fetched straight from Garmin (three requests) when the panel opens and every 15 minutes; not stored.
@MainActor
@Observable
final class LiveToday {
    struct Stress {
        var average: Int?
        var rest = 0.0, low = 0.0, medium = 0.0, high = 0.0, activity = 0.0
        var total: Double { rest + low + medium + high + activity }
    }

    private(set) var battery: [(Date, Double)] = []
    private(set) var heartRate: [(Date, Double)] = []
    private(set) var restingHR: Int?
    private(set) var stress = Stress()
    private(set) var steps: Int?
    private(set) var stepGoal: Int?
    private(set) var updated: Date?
    private(set) var problem: String?
    private var refreshing = false
    private var timer: Timer?

    var currentBattery: Int? { battery.last.map { Int($0.1) } }

    init() {
        // Unit tests launch the app too; they shouldn't call Garmin.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        Task { await refresh() }
    }

    /// Skips if the last refresh was under a minute ago.
    func refresh(force: Bool = false) async {
        guard !refreshing, Keychain.readKey() != nil else { return }
        if !force, let updated, Date().timeIntervalSince(updated) < 60 { return }
        refreshing = true
        defer { refreshing = false }
        let client = GarminClient.shared
        let today = GarminDate.string(Date())
        do {
            let (bbPath, bbQuery) = Endpoint.bodyBattery(from: today, to: today)
            let bb: [BodyBatteryDayDTO] = try await client.get(bbPath, query: bbQuery)
            battery = bb.last?.levels ?? []

            let (hrPath, hrQuery) = Endpoint.dailyHeartRate(today)
            let hr: DailyHeartRateDTO = try await client.get(hrPath, query: hrQuery)
            heartRate = hr.values
            restingHR = hr.restingHeartRate

            let (sPath, sQuery) = Endpoint.dailySummaries(from: today, to: today)
            let summary: DailySummariesDTO = try await client.get(sPath, query: sQuery)
            if let s = summary.data.last?.stress {
                stress = Stress(average: s.avgLevel.flatMap { $0 >= 0 ? $0 : nil },
                                rest: s.restDurationInMillis ?? 0, low: s.lowStressDurationInMillis ?? 0,
                                medium: s.mediumStressDurationInMillis ?? 0, high: s.highStressDurationInMillis ?? 0,
                                activity: s.activityDurationInMillis ?? 0)
            }
            let (stPath, _) = Endpoint.steps(from: today, to: today)
            let steps: [StepsDTO] = try await client.get(stPath)
            self.steps = steps.last?.totalSteps
            stepGoal = steps.last?.stepGoal
            updated = Date()
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// The menu bar item: a bolt and the current Body Battery.
struct MenuBarLabel: View {
    let live: LiveToday
    var body: some View {
        if let level = live.currentBattery {
            Label("\(level)", systemImage: "bolt.heart.fill").labelStyle(.titleAndIcon)
        } else {
            Image(systemName: "bolt.heart")
        }
    }
}

struct MenuBarPanel: View {
    let live: LiveToday
    @Query(sort: \Day.date, order: .reverse) private var days: [Day]
    @Environment(\.openWindow) private var openWindow

    private var lastNight: Day? { days.prefix(2).first { $0.sleepSeconds != nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Today").font(.headline)
                Spacer()
                if let updated = live.updated {
                    Text("Updated \(updated, format: .dateTime.hour().minute())").font(.caption).foregroundStyle(.secondary)
                }
                Button { Task { await live.refresh(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh from Garmin")
            }

            battery
            heartRate
            stress
            HStack(alignment: .top, spacing: 12) {
                sleep
                steps
            }

            if let problem = live.problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).lineLimit(2)
            }
            Divider()
            HStack {
                Button("Open Splits") {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "main")
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 340)
        .task { await live.refresh() }
    }

    private var battery: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label("Body Battery", systemImage: "bolt.heart.fill").font(.subheadline.weight(.semibold)).foregroundStyle(.blue)
                Spacer()
                Text(live.currentBattery.map(String.init) ?? "–").font(.system(size: 26, weight: .bold, design: .rounded))
            }
            Chart(live.battery, id: \.0) { point in
                AreaMark(x: .value("Time", point.0), yStart: .value("Base", 0), yEnd: .value("Level", point.1))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [.blue.opacity(0.45), .blue.opacity(0.05)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Time", point.0), y: .value("Level", point.1))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(.blue)
            }
            .chartYScale(domain: 0...100)
            .chartXScale(domain: dayRange)
            .chartYAxis { AxisMarks(values: [0, 50, 100]) { _ in AxisGridLine() } }
            .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 6)) { _ in AxisValueLabel(format: .dateTime.hour()) } }
            .frame(height: 70)
        }
    }

    private var heartRate: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label("Heart rate", systemImage: "heart.fill").font(.subheadline.weight(.semibold)).foregroundStyle(.red)
                Spacer()
                if let last = live.heartRate.last { Text("\(Int(last.1)) bpm").font(.callout.weight(.semibold)) }
                if let resting = live.restingHR { Text("resting \(resting)").font(.caption).foregroundStyle(.secondary) }
            }
            Chart {
                ForEach(live.heartRate, id: \.0) { point in
                    LineMark(x: .value("Time", point.0), y: .value("bpm", point.1))
                        .foregroundStyle(.red)
                        .lineStyle(StrokeStyle(lineWidth: 1.2))
                }
                if let resting = live.restingHR {
                    RuleMark(y: .value("Resting", resting))
                        .foregroundStyle(.red.opacity(0.4))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartXScale(domain: dayRange)
            .chartYAxis(.hidden)
            .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 6)) { _ in AxisValueLabel(format: .dateTime.hour()) } }
            .frame(height: 60)
        }
    }

    private var stress: some View {
        let s = live.stress
        let parts: [(String, Double, Color)] = [("Rest", s.rest, .blue), ("Low", s.low, .yellow.opacity(0.8)),
                                                 ("Medium", s.medium, .orange), ("High", s.high, .red), ("Active", s.activity, .gray)]
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label("Stress", systemImage: "waveform.path.ecg").font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                Spacer()
                if let avg = s.average { Text("avg \(avg)").font(.callout.weight(.semibold)) }
            }
            if s.total > 0 {
                GeometryReader { geo in
                    let shown = parts.filter { $0.1 > 0 }
                    let room = geo.size.width - CGFloat(max(shown.count - 1, 0)) * 2
                    HStack(spacing: 2) {
                        ForEach(shown, id: \.0) { part in
                            Rectangle().fill(part.2).frame(width: room * part.1 / s.total)
                        }
                    }
                }
                .frame(height: 10)
                .clipShape(Capsule())
                HStack(spacing: 10) {
                    ForEach(parts.filter { $0.1 > 0 }, id: \.0) { part in
                        HStack(spacing: 4) {
                            Circle().fill(part.2).frame(width: 6, height: 6)
                            Text("\(part.0) \(Format.hoursMinutes(Int(part.1 / 1000)))").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var sleep: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Last night", systemImage: "bed.double.fill").font(.subheadline.weight(.semibold)).foregroundStyle(.indigo)
            if let night = lastNight, let seconds = night.sleepSeconds {
                Text(Format.hoursMinutes(seconds)).font(.title3.bold())
                HStack(spacing: 6) {
                    if let score = night.sleepScore { Text("score \(score)") }
                    if let hrv = night.hrvLastNight { Text("· HRV \(hrv)") }
                }
                .font(.caption).foregroundStyle(.secondary)
                SleepStages(day: night).frame(height: 6)
            } else {
                Text("–").font(.title3.bold())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Steps", systemImage: "shoeprints.fill").font(.subheadline.weight(.semibold)).foregroundStyle(.green)
            Text(live.steps.map { $0.formatted() } ?? "–").font(.title3.bold())
            if let goal = live.stepGoal, goal > 0 {
                ProgressView(value: min(Double(live.steps ?? 0), Double(goal)), total: Double(goal)).tint(.green)
                Text("goal \(goal.formatted())").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dayRange: ClosedRange<Date> {
        let start = Calendar.current.startOfDay(for: Date())
        return start...start.addingTimeInterval(86_400)
    }
}
