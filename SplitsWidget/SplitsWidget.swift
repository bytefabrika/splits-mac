import SwiftUI
import WidgetKit

// The widgets only read the snapshot the app writes into the shared App Group folder. They never talk to
// Garmin, and have no network access: the app redraws them when it syncs.

struct Entry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: Date(), snapshot: .placeholder) }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: Date(), snapshot: context.isPreview ? (WidgetSnapshot.load() ?? .placeholder) : WidgetSnapshot.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let entry = Entry(date: Date(), snapshot: WidgetSnapshot.load())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(30 * 60))))
    }
}

@main
struct SplitsWidgets: WidgetBundle {
    var body: some Widget {
        BriefingWidget()
        BatteryWidget()
        WeekWidget()
    }
}

// MARK: Shared bits

private let batteryBlue = Color(red: 0.2, green: 0.55, blue: 1.0)
private let runOrange = Color(red: 1.0, green: 0.42, blue: 0.29)

private func hoursMinutes(_ seconds: Int) -> String {
    let m = (seconds + 30) / 60
    return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
}

private func distance(_ metres: Double, imperial: Bool, decimals: Int = 1) -> String {
    let v = imperial ? metres / 1609.344 : metres / 1000
    return "\(v.formatted(.number.precision(.fractionLength(decimals)))) \(imperial ? "mi" : "km")"
}

private func verdictColor(_ verdict: String?) -> Color {
    switch verdict {
    case "Well recovered": .green
    case "Partly recovered": .orange
    case "Not well recovered": .red
    case "Waiting for last night": .secondary
    default: .secondary
    }
}

private struct Empty: View {
    var message = "Open Splits to sync"
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "figure.run.circle").font(.title)
            Text(message).font(.caption).multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct Updated: View {
    let date: Date
    var body: some View {
        Text("Updated \(date.formatted(date: .omitted, time: .shortened))")
            .font(.system(size: 9)).foregroundStyle(.tertiary)
    }
}

/// Body Battery through the day as a filled curve, 0–100.
private struct Curve: View {
    let points: [WidgetSnapshot.Point]
    var body: some View {
        GeometryReader { geo in
            if points.count > 1, let start = points.first?.time {
                let dayStart = Calendar.current.startOfDay(for: start)
                let x = { (t: Date) in t.timeIntervalSince(dayStart) / 86_400 * geo.size.width }
                let y = { (v: Double) in geo.size.height * (1 - v / 100) }
                let line = Path { p in
                    for (i, pt) in points.enumerated() {
                        let point = CGPoint(x: x(pt.time), y: y(pt.value))
                        if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
                    }
                }
                var area = line
                let _ = area.addLine(to: CGPoint(x: x(points.last!.time), y: geo.size.height))
                let _ = area.addLine(to: CGPoint(x: x(points[0].time), y: geo.size.height))
                area.fill(LinearGradient(colors: [batteryBlue.opacity(0.45), batteryBlue.opacity(0.05)], startPoint: .top, endPoint: .bottom))
                line.stroke(batteryBlue, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

// MARK: Briefing

struct BriefingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "briefing", provider: Provider()) { entry in
            BriefingView(entry: entry).containerBackground(for: .widget) {
                LinearGradient(colors: [.orange.opacity(0.18), .pink.opacity(0.12), .purple.opacity(0.14)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .configurationDisplayName("Your day")
        .description("This morning's briefing: how you recovered and what today could look like.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct BriefingView: View {
    let entry: Entry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let s = entry.snapshot {
            VStack(alignment: .leading, spacing: family == .systemSmall ? 4 : 8) {
                if let verdict = s.verdict {
                    Text(verdict.uppercased())
                        .font(.system(size: 10, weight: .heavy)).tracking(0.8)
                        .foregroundStyle(verdictColor(verdict))
                } else {
                    Label("YOUR DAY", systemImage: "sun.horizon.fill")
                        .font(.system(size: 10, weight: .heavy)).foregroundStyle(.orange)
                }
                Text(s.briefingHeadline ?? "The briefing appears once last night's sleep has synced.")
                    .font(family == .systemSmall ? .callout.weight(.bold) : .title3.weight(.bold))
                    .lineLimit(family == .systemSmall ? 4 : 3)
                    .minimumScaleFactor(0.8)
                if let plan = s.plan, family != .systemSmall {
                    Text(plan).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
                if family != .systemSmall {
                    HStack(spacing: 14) {
                        if let sleep = s.sleepSeconds { stat("bed.double.fill", .indigo, hoursMinutes(sleep), s.sleepScore.map { "score \($0)" }) }
                        if let hrv = s.hrv { stat("waveform.path.ecg", .teal, "\(hrv) ms", "HRV") }
                        if let bb = s.bodyBattery { stat("bolt.heart.fill", batteryBlue, "\(bb)", "battery") }
                    }
                }
                if family == .systemLarge, s.batteryCurve.count > 1 {
                    Curve(points: s.batteryCurve).frame(height: 70)
                }
                if family != .systemSmall { Updated(date: s.updated) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Empty()
        }
    }

    private func stat(_ symbol: String, _ tint: Color, _ value: String, _ label: String?) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(value).font(.callout.weight(.bold)).monospacedDigit()
            if let label { Text(label).font(.caption2).foregroundStyle(.secondary) }
        }
    }
}

// MARK: Body Battery

struct BatteryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "battery", provider: Provider()) { entry in
            BatteryView(entry: entry).containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Body Battery")
        .description("Your Body Battery now, and through the day.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct BatteryView: View {
    let entry: Entry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let s = entry.snapshot, let bb = s.bodyBattery {
            VStack(alignment: .leading, spacing: 4) {
                Label("Body Battery", systemImage: "bolt.heart.fill")
                    .font(.caption.weight(.bold)).foregroundStyle(batteryBlue)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(bb)").font(.system(size: 40, weight: .heavy, design: .rounded)).monospacedDigit()
                    if family == .systemMedium, let high = s.bodyBatteryHigh {
                        Text("high \(high)" + (s.bodyBatteryLow.map { " · low \($0)" } ?? ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if family == .systemMedium, let steps = s.steps {
                        VStack(alignment: .trailing, spacing: 0) {
                            Text(steps.formatted()).font(.callout.weight(.bold)).monospacedDigit()
                            Text(s.stepGoal.map { "of \($0.formatted()) steps" } ?? "steps").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                Curve(points: s.batteryCurve)
                Updated(date: s.updated)
            }
        } else {
            Empty(message: entry.snapshot == nil ? "Open Splits to sync" : "No Body Battery from your watch yet today")
        }
    }
}

// MARK: This week

struct WeekWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "week", provider: Provider()) { entry in
            WeekView(entry: entry).containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Running this week")
        .description("Your running this week, day by day.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct WeekView: View {
    let entry: Entry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let s = entry.snapshot, s.week.count == 7 {
            let total = s.week.reduce(0) { $0 + $1.metres }
            let most = max(s.week.map(\.metres).max() ?? 0, 1)
            let today = Calendar.current.startOfDay(for: Date())
            VStack(alignment: .leading, spacing: 6) {
                Label("This week", systemImage: "figure.run")
                    .font(.caption.weight(.bold)).foregroundStyle(runOrange)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(distance(total, imperial: s.imperial, decimals: total >= 100_000 ? 0 : 1))
                        .font(.system(size: family == .systemSmall ? 24 : 30, weight: .heavy, design: .rounded)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.7)
                    if family == .systemMedium {
                        Text("\(s.weekActivities) \(s.weekActivities == 1 ? "run" : "runs")").font(.callout).foregroundStyle(.secondary)
                    }
                }
                HStack(alignment: .bottom, spacing: family == .systemSmall ? 5 : 10) {
                    ForEach(Array(s.week.enumerated()), id: \.offset) { _, day in
                        let isToday = Calendar.current.isDate(day.day, inSameDayAs: today)
                        VStack(spacing: 3) {
                            GeometryReader { geo in
                                VStack {
                                    Spacer(minLength: 0)
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(day.metres > 0 ? runOrange : Color.secondary.opacity(0.2))
                                        .frame(height: day.metres > 0 ? max(4, geo.size.height * day.metres / most) : 3)
                                }
                            }
                            Text(day.day.formatted(.dateTime.weekday(.narrow)))
                                .font(.system(size: 9, weight: isToday ? .heavy : .regular))
                                .foregroundStyle(isToday ? .primary : .secondary)
                        }
                    }
                }
            }
        } else {
            Empty()
        }
    }
}
