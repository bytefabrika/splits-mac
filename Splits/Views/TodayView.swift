import Charts
import SwiftData
import SwiftUI

struct TodayView: View {
    @Query(sort: \Day.date, order: .reverse) private var allDays: [Day]
    @Query(sort: \Activity.start, order: .reverse) private var activities: [Activity]
    @Environment(\.format) private var format
    /// Today's Body Battery through the day. Fetched when the screen opens, not stored.
    @State private var batteryCurve: [(Date, Double)] = []

    private var days: [Day] { Array(allDays.prefix(14)) }
    private var today: Day? { allDays.first }
    /// Last night is stored on the day it ended.
    private var lastNight: Day? { allDays.prefix(2).first { $0.sleepSeconds != nil } }

    var body: some View {
        NavigationStack {
            content
                .navigationDestination(for: Int64.self) { id in
                    if let activity = activities.first(where: { $0.garminId == id }) { ActivityPage(activity: activity) }
                }
        }
        .task(id: allDays.first?.date) {
            let today = GarminDate.string(Date())
            let (path, query) = Endpoint.bodyBattery(from: today, to: today)
            if let days: [BodyBatteryDayDTO] = try? await GarminClient.shared.get(path, query: query) {
                batteryCurve = days.last?.levels ?? []
            }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if allDays.isEmpty {
                    ContentUnavailableView("Nothing here yet", systemImage: "arrow.triangle.2.circlepath",
                                           description: Text("Your data appears after the first sync."))
                } else {
                    Text(Date(), format: .dateTime.weekday(.wide).day().month(.wide))
                        .font(.title2.bold())

                    ReportCard(.daily, days: allDays, activities: activities)

                    CardGrid(cards: [
                        AnyView(sleepCard),
                        AnyView(hrvCard),
                        AnyView(bodyBatteryCard),
                        AnyView(metricCard("Resting heart rate", value: today?.restingHR.map { "\($0)" }, unit: "bpm",
                                           symbol: "heart", tint: .red, series: days.map { ($0.day, $0.restingHR.map(Double.init)) })),
                        AnyView(metricCard("Stress", value: today?.stressAvg.map { "\($0)" }, unit: "avg",
                                           symbol: "waveform.path.ecg", tint: .orange, series: days.map { ($0.day, $0.stressAvg.map(Double.init)) })),
                        AnyView(metricCard("Steps", value: today?.steps.map { $0.formatted() },
                                           unit: today?.stepGoal.map { "of \($0.formatted())" } ?? "",
                                           symbol: "shoeprints.fill", tint: .green, series: days.map { ($0.day, $0.steps.map(Double.init)) })),
                    ])


                    Text("Recent activities").font(.headline).padding(.top, 6)
                    VStack(spacing: 0) {
                        ForEach(activities.prefix(6)) { activity in
                            NavigationLink(value: activity.garminId) {
                                ActivityRow(activity: activity).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 1100, alignment: .leading)
            // Fill the scroll view and take hits everywhere, so the scroll wheel works over empty space too.
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .navigationTitle("Today")
    }

    private var sleepCard: some View {
        Card(title: "Sleep", symbol: "bed.double.fill", tint: .indigo) {
            if let night = lastNight, let seconds = night.sleepSeconds {
                HStack(alignment: .firstTextBaseline) {
                    Text(Format.hoursMinutes(seconds)).font(.title.bold())
                    if let score = night.sleepScore { Text("score \(score)").foregroundStyle(.secondary) }
                }
                SleepStages(day: night).frame(height: 10)
                if let start = night.sleepStart, let end = night.sleepEnd {
                    Text("\(start, format: .dateTime.hour().minute()) – \(end, format: .dateTime.hour().minute())")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("No sleep recorded last night").foregroundStyle(.secondary)
            }
        }
    }

    private var hrvCard: some View {
        Card(title: "HRV", symbol: "waveform.path", tint: .teal) {
            if let night = lastNight ?? today, let hrv = night.hrvLastNight {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(hrv)").font(.title.bold())
                    Text("ms last night").foregroundStyle(.secondary)
                    Spacer()
                    if let status = night.hrvStatus { StatusPill(text: Format.title(status), good: status == "BALANCED") }
                }
                if let weekly = night.hrvWeekly, let low = night.hrvBalancedLow, let high = night.hrvBalancedHigh {
                    Text("7-day average \(weekly) ms · your balanced range \(low)–\(high)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Sparkline(points: days.map { ($0.day, $0.hrvLastNight.map(Double.init)) }, tint: .teal)
            } else {
                Text("No HRV last night").foregroundStyle(.secondary)
            }
        }
    }

    private var bodyBatteryCard: some View {
        Card(title: "Energy", symbol: "bolt.heart.fill", tint: .blue) {
            if let today, let latest = today.bodyBatteryLatest {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(latest)").font(.title.bold())
                    Text("now").foregroundStyle(.secondary)
                }
                if batteryCurve.count > 1 {
                    Chart(batteryCurve, id: \.0) { point in
                        AreaMark(x: .value("Time", point.0), y: .value("Level", point.1))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(LinearGradient(colors: [.blue.opacity(0.5), .blue.opacity(0.05)], startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("Time", point.0), y: .value("Level", point.1))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(.blue)
                    }
                    .chartYScale(domain: 0...100)
                    .chartYAxis(.hidden)
                    .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 6)) { _ in AxisValueLabel(format: .dateTime.hour()) } }
                    .frame(height: 60)
                } else {
                    ProgressView(value: Double(latest), total: 100).tint(.blue)
                }
                Text("High \(today.bodyBatteryHigh ?? 0) · low \(today.bodyBatteryLow ?? 0) · +\(today.bodyBatteryCharged ?? 0) charged · −\(today.bodyBatteryDrained ?? 0) drained")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("No energy reading today").foregroundStyle(.secondary)
            }
        }
    }

    private func metricCard(_ title: String, value: String?, unit: String, symbol: String, tint: Color,
                            series: [(Date, Double?)]) -> some View {
        Card(title: title, symbol: symbol, tint: tint) {
            HStack(alignment: .firstTextBaseline) {
                Text(value ?? "–").font(.title.bold())
                Text(unit).foregroundStyle(.secondary)
            }
            Sparkline(points: series, tint: tint)
        }
    }
}

struct Card<Content: View>: View {
    let title: String
    let symbol: String
    let tint: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbol).foregroundStyle(tint)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minHeight: 150)
        .card()
    }
}

struct StatusPill: View {
    let text: String
    let good: Bool
    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background((good ? Color.green : Color.orange).opacity(0.18), in: Capsule())
            .foregroundStyle(good ? .green : .orange)
    }
}

/// Deep, light, REM and awake as one bar.
struct SleepStages: View {
    let day: Day
    var body: some View {
        let parts: [(Int, Color)] = [(day.deepSeconds ?? 0, .indigo), (day.lightSeconds ?? 0, .blue),
                                     (day.remSeconds ?? 0, .purple), (day.awakeSeconds ?? 0, .pink)]
        let total = max(parts.reduce(0) { $0 + $1.0 }, 1)
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    Rectangle().fill(part.1).frame(width: max(geo.size.width * CGFloat(part.0) / CGFloat(total) - 2, 0))
                }
            }
            .clipShape(Capsule())
        }
        .help("Deep \(Format.hoursMinutes(day.deepSeconds ?? 0)) · light \(Format.hoursMinutes(day.lightSeconds ?? 0)) · REM \(Format.hoursMinutes(day.remSeconds ?? 0)) · awake \(Format.hoursMinutes(day.awakeSeconds ?? 0))")
    }
}

struct Sparkline: View {
    let points: [(Date, Double?)]
    let tint: Color
    var body: some View {
        Chart {
            ForEach(points.compactMap { p in p.1.map { (p.0, $0) } }, id: \.0) { point in
                LineMark(x: .value("Day", point.0), y: .value("Value", point.1))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(tint)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: .automatic(includesZero: false))
        .frame(height: 36)
    }
}

struct ChartCard<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        Panel(title: title, subtitle: subtitle) {
            content.frame(height: 200)
        }
    }
}

/// "Your week": the coach's check-in on the last 7 days. Kept for the day once written.
/// A few paragraphs from Apple's on-device model: this morning's briefing.
/// Written once a day and kept until tomorrow.
struct ReportCard: View {
    enum Kind {
        case daily

        var title: String { "Your day" }
        var subtitle: String { "Written by on-device AI, can be wrong" }
        var ask: String { "Brief me on today" }
        var waiting: String { "Looking at last night and your training…" }
        var symbol: String { "sun.horizon.fill" }
        var colors: [Color] { [.orange, .pink, .purple] }
        var instructions: String { Coach.dailyInstructions }
        func facts(_ activities: [Activity], _ days: [Day], _ format: Format) -> String {
            Coach.dailyFacts(activities: activities, days: days, format: format)
        }
    }

    let kind: Kind
    let days: [Day]
    let activities: [Activity]
    @Environment(\.format) private var format
    @AppStorage private var savedDate: String
    @AppStorage private var savedText: String
    @AppStorage(DailyBriefing.hadSleepKey) private var hadSleep = false
    @State private var text = ""
    @State private var writing = false
    @State private var failure: String?
    @State private var status: Coach.Status

    init(_ kind: Kind, days: [Day], activities: [Activity]) {
        self.kind = kind
        // Checked here, not in onAppear: when the model isn't ready the card is empty, and an empty view
        // never appears, so it would never find out the model became ready.
        _status = State(initialValue: Coach.status)
        self.days = days
        self.activities = activities
        // "dailyBrief" rather than "daily": a new key, so a briefing in the old tone is written again.
        let key = "dailyBrief"
        _savedDate = AppStorage(wrappedValue: "", "\(key)ReportDate")
        _savedText = AppStorage(wrappedValue: "", "\(key)ReportText")
    }

    private var today: String { GarminDate.string(Date()) }
    /// The briefing waits for last night's sleep to sync, so it isn't written from yesterday's numbers.
    private var sleepSynced: Bool { days.contains { $0.date == today && $0.sleepSeconds != nil } }

    var body: some View {
        VStack { content }
            .task(id: "\(status == .ready)-\(sleepSynced)") {
                if kind == .daily, status == .ready, sleepSynced, savedDate != today || !hadSleep, !writing { await write() }
            }
    }

    @ViewBuilder private var content: some View {
        if status == .ready || (savedDate == today && !savedText.isEmpty) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(kind.title, systemImage: kind.symbol)
                        .font(.headline)
                        .foregroundStyle(LinearGradient(colors: kind.colors, startPoint: .leading, endPoint: .trailing))
                    Spacer()
                    Text(kind.subtitle).font(.caption2).foregroundStyle(.secondary)
                    if savedDate == today && !writing && status == .ready {
                        Button { Task { await write() } } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless)
                            .help("Write it again")
                    }
                }
                let shown = writing ? text : (savedDate == today ? savedText : "")
                if !shown.isEmpty {
                    let text = Coach.withoutDashes(shown)
                    let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
                    VStack(alignment: .leading, spacing: 8) {
                        // The model writes a one-line headline first: it reads as one.
                        if lines.count == 2 {
                            Text(DailyBriefing.headline(String(lines[0])))
                                .font(.title3.weight(.semibold))
                            Text(lines[1].trimmingCharacters(in: .whitespacesAndNewlines))
                        } else {
                            Text(text)
                        }
                    }
                    .textSelection(.enabled)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                } else if !writing {
                    HStack(spacing: 12) {
                        Button { Task { await write() } } label: { Label(kind.ask, systemImage: "wand.and.stars") }
                            .buttonStyle(.borderedProminent)
                            .tint(kind.colors[0])
                        if kind == .daily && !sleepSynced {
                            Text("Last night's sleep hasn't synced yet; it writes itself once it has.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if writing && text.isEmpty {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text(kind.waiting).foregroundStyle(.secondary) }
                }
                if let failure { Text(failure).font(.caption).foregroundStyle(.orange) }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(colors: kind.colors.map { $0.opacity(0.1) }, startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 14)
            )
        } else if kind == .daily, case .unavailable(let reason) = status {
            HStack(spacing: 10) {
                Image(systemName: kind.symbol).foregroundStyle(.secondary)
                Text("A daily briefing appears here once Apple Intelligence is ready. \(reason)")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Check again") { status = Coach.status }
            }
            .padding(12)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func write() async {
        writing = true
        failure = nil
        text = ""
        defer { writing = false }
        let facts = kind.facts(activities, days, format)
        let withSleep = sleepSynced
        do {
            try await Coach.write(facts: facts, instructions: kind.instructions, temperature: kind == .daily ? 0.4 : 0.6) { text = $0 }
            savedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            savedDate = today
            hadSleep = withSleep
            if NSApp?.isActive == true { UserDefaults.standard.set(today, forKey: DailyBriefing.notifiedKey) }
        } catch {
            failure = "Couldn't write it: \(error.localizedDescription)"
        }
    }
}
