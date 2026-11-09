import Charts
import SwiftData
import SwiftUI

struct TodayView: View {
    @Query(sort: \Day.date, order: .reverse) private var allDays: [Day]
    @Query(sort: \Activity.start, order: .reverse) private var activities: [Activity]
    @Environment(\.format) private var format

    private var days: [Day] { Array(allDays.prefix(14)) }
    private var today: Day? { allDays.first }
    /// Last night is stored on the day it ended.
    private var lastNight: Day? { allDays.prefix(2).first { $0.sleepSeconds != nil } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if allDays.isEmpty {
                    ContentUnavailableView("Nothing here yet", systemImage: "arrow.triangle.2.circlepath",
                                           description: Text("Your data appears after the first sync."))
                } else {
                    Text(Date(), format: .dateTime.weekday(.wide).day().month(.wide))
                        .font(.title2.bold())

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 14)], spacing: 14) {
                        sleepCard
                        hrvCard
                        bodyBatteryCard
                        metricCard("Resting heart rate", value: today?.restingHR.map { "\($0)" }, unit: "bpm",
                                   symbol: "heart", tint: .red, series: days.map { ($0.day, $0.restingHR.map(Double.init)) })
                        metricCard("Stress", value: today?.stressAvg.map { "\($0)" }, unit: "avg",
                                   symbol: "waveform.path.ecg", tint: .orange, series: days.map { ($0.day, $0.stressAvg.map(Double.init)) })
                        metricCard("Steps", value: today?.steps.map { $0.formatted() },
                                   unit: today?.stepGoal.map { "of \($0.formatted())" } ?? "",
                                   symbol: "shoeprints.fill", tint: .green, series: days.map { ($0.day, $0.steps.map(Double.init)) })
                    }

                    Text("Recent activities").font(.headline).padding(.top, 6)
                    VStack(spacing: 0) {
                        ForEach(activities.prefix(6)) { activity in
                            ActivityRow(activity: activity)
                            Divider()
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 1100, alignment: .leading)
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
        Card(title: "Body Battery", symbol: "bolt.heart.fill", tint: .blue) {
            if let today, let latest = today.bodyBatteryLatest {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(latest)").font(.title.bold())
                    Text("now").foregroundStyle(.secondary)
                }
                ProgressView(value: Double(latest), total: 100).tint(.blue)
                Text("High \(today.bodyBatteryHigh ?? 0) · low \(today.bodyBatteryLow ?? 0) · +\(today.bodyBatteryCharged ?? 0) charged · −\(today.bodyBatteryDrained ?? 0) drained")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("No Body Battery today").foregroundStyle(.secondary)
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
            Label(title, systemImage: symbol).font(.subheadline.weight(.semibold)).foregroundStyle(tint)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
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
