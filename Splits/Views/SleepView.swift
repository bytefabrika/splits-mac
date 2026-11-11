import Charts
import SwiftData
import SwiftUI

/// Sleep beyond the score: last night against Garmin's optimal ranges, sleep debt against your sleep need,
/// how regular your nights are, your body clock (social jetlag and chronotype), and the stages over time.
struct SleepView: View {
    enum Range: String, CaseIterable, Identifiable {
        case days30 = "30 nights", days90 = "90 nights", year = "1 year"
        var id: String { rawValue }
        var days: Int { switch self { case .days30: 30; case .days90: 90; case .year: 365 } }
    }

    @Query(sort: \Day.date) private var days: [Day]
    @State private var range: Range = .days30
    @State private var nights: [SleepAnalysis.Night]?
    @State private var nightIndex: Int?

    private var since: Date { Calendar.current.date(byAdding: .day, value: -range.days, to: Calendar.current.startOfDay(for: Date()))! }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if let nights, let last = nights.last {
                        InsightCard(key: "sleepTake", title: "Your sleep", symbol: "moon.zzz.fill", colors: [.indigo, .purple, .pink],
                                    night: GarminDate.string(last.date)) {
                            Coach.sleepFacts(days: days)
                        }
                        night(nights)
                        debt(nights)
                        let shown = nights.filter { $0.date > since }
                        schedule(shown)
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: 20) { bodyClock(nights); stages(shown) }
                            VStack(alignment: .leading, spacing: 28) { bodyClock(nights); stages(shown) }
                        }
                        nightly(shown)
                        method
                    } else if nights != nil {
                        ContentUnavailableView("No sleep yet", systemImage: "moon.zzz",
                                               description: Text("Wear your watch to bed and sync in the morning."))
                    }
                }
                .padding(24)
                .frame(maxWidth: 1240)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .defaultScrollAnchor(DebugFlags.scrollBottom ? .bottom : .top)
            .navigationTitle("Sleep")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Range", selection: $range) {
                        ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("How far back the charts go")
                }
            }
        }
        .task(id: "\(days.count)-\(days.last?.date ?? "")-\(days.last?.sleepSeconds ?? 0)") {
            nights = SleepAnalysis.nights(days)
        }
    }

    // MARK: One night

    private func night(_ nights: [SleepAnalysis.Night]) -> some View {
        let index = min(nightIndex ?? nights.count - 1, nights.count - 1)
        let n = nights[index]
        let date = GarminDate.string(n.date)
        let day = days.first { $0.date == date }
        let isLast = index == nights.count - 1
        var metrics = [Metric(label: "Asleep", symbol: "bed.double", tint: .indigo, value: Format.hoursMinutes(Int(n.asleep)),
                              note: n.need.map { "needed \(Format.hoursMinutes(Int($0)))" })]
        if let score = n.score {
            metrics.append(Metric(label: "Score", symbol: "star", tint: .yellow, value: "\(score)",
                                  note: day?.sleepQuality.map { Format.title($0.lowercased()) }))
        }
        metrics.append(Metric(label: "Asleep to awake", symbol: "clock", tint: .purple,
                              value: "\(SleepAnalysis.clock(n.bedtime))–\(SleepAnalysis.clock(n.wake))",
                              note: n.efficiency.map { "asleep \(Int($0.rounded()))% of the time" }))
        if let breathing = day?.sleepRespiration {
            let range = day?.sleepRespirationLow.flatMap { low in day?.sleepRespirationHigh.map { "\(Int(low))–\(Int($0)) a minute" } }
            metrics.append(Metric(label: "Breathing", symbol: "lungs", tint: .cyan, value: "\(Int(breathing.rounded())) brpm", note: range))
        }
        if let stress = day?.sleepStress {
            metrics.append(Metric(label: "Sleep stress", symbol: "waveform.path", tint: .orange, value: "\(Int(stress.rounded()))",
                                  note: day?.awakeCount.map { $0 == 1 ? "woke once" : "woke \($0) times" }))
        }
        let title = isLast ? "Last night" : "Night to \(n.date.formatted(.dateTime.weekday(.wide).day().month(.wide)))"
        return Panel(title: title) {
            HStack(spacing: 2) {
                Button { nightIndex = max(index - 1, 0) } label: { Image(systemName: "chevron.left") }
                    .disabled(index == 0).help("The night before")
                Button { nightIndex = min(index + 1, nights.count - 1) } label: { Image(systemName: "chevron.right") }
                    .disabled(isLast).help("The night after")
            }
            .buttonStyle(.borderless)
        } content: {
            MetricRow(metrics: metrics)
            Divider()
            StageRanges(night: n, average: SleepAnalysis.stageShares(Array(nights.suffix(30))))
            Divider()
            Text("Heart rate").font(.subheadline.weight(.semibold))
            NightHeartRateChart(date: date, start: n.start, end: n.end)
        }
    }

    // MARK: Debt

    private func debt(_ nights: [SleepAnalysis.Night]) -> some View {
        let start = Calendar.current.date(byAdding: .day, value: -14, to: Calendar.current.startOfDay(for: Date()))!
        let balance = SleepAnalysis.balance(nights.filter { $0.date > start })
        let owed = SleepAnalysis.debt(nights)
        let subtitle = owed.map { $0 < 30 * 60 ? "No sleep debt over the last 14 nights" : "\(Format.hoursMinutes(Int($0))) short over the last 14 nights" }
            ?? "Against the sleep need your watch works out each night"
        return Panel(title: "Sleep debt", subtitle: subtitle) {
            if balance.isEmpty {
                Text("Your watch hasn't given a sleep need for these nights.").foregroundStyle(.secondary)
            } else {
                Chart(balance, id: \.date) { b in
                    BarMark(x: .value("Night", b.date, unit: .day), y: .value("Hours", b.seconds / 3600))
                        .foregroundStyle(b.seconds < 0 ? Color.orange : Color.indigo)
                        .cornerRadius(3)
                    RuleMark(y: .value("Need", 0)).foregroundStyle(Color.secondary.opacity(0.6))
                }
                .chartYAxis {
                    AxisMarks { v in
                        AxisGridLine()
                        AxisValueLabel { Text(signedHours(v.as(Double.self) ?? 0)) }
                    }
                }
                .chartXAxis { AxisMarks(values: .stride(by: .day, count: 2)) { _ in AxisValueLabel(format: .dateTime.weekday(.abbreviated)) } }
                .frame(height: 170)
                Text("Above the line: more than you needed. Below: short. A long night pays some of it back.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func signedHours(_ h: Double) -> String {
        if h == 0 { return "need" }
        let minutes = Int((abs(h) * 60).rounded())
        return (h > 0 ? "+" : "−") + (minutes >= 60 ? "\(minutes / 60)h\(minutes % 60 > 0 ? String(format: "%02d", minutes % 60) : "")" : "\(minutes)m")
    }

    // MARK: Schedule

    private func schedule(_ nights: [SleepAnalysis.Night]) -> some View {
        let r = SleepAnalysis.regularity(nights)
        let low = (nights.map(\.bedtime).min() ?? -1).rounded(.down) - 0.5
        let high = (nights.map(\.wake).max() ?? 8).rounded(.up) + 0.5
        let subtitle = r.map { r in
            let spread = Int(r.bedtimeSpread.rounded())
            return "Bedtime moves by about \(spread) minutes from night to night: \(spread < 30 ? "very regular" : spread < 60 ? "fairly regular" : "irregular")"
        } ?? ""
        return Panel(title: "When you sleep", subtitle: subtitle) {
            if let r {
                MetricRow(metrics: [
                    Metric(label: "Usual bedtime", symbol: "moon", tint: .indigo, value: SleepAnalysis.clock(r.bedtime),
                           note: "± \(Int(r.bedtimeSpread.rounded())) min"),
                    Metric(label: "Usual wake-up", symbol: "sunrise", tint: .orange, value: SleepAnalysis.clock(r.wake),
                           note: "± \(Int(r.wakeSpread.rounded())) min"),
                ])
            }
            Chart {
                ForEach(nights) { n in
                    // Negative, so the evening is at the top and the morning at the bottom.
                    BarMark(x: .value("Night", n.date, unit: .day), yStart: .value("Asleep", -n.bedtime), yEnd: .value("Awake", -n.wake))
                        .foregroundStyle(n.isFreeDay ? Color.purple.opacity(0.7) : Color.indigo)
                        .cornerRadius(2)
                }
                if let r {
                    RuleMark(y: .value("Bedtime", -r.bedtime)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(.secondary)
                    RuleMark(y: .value("Wake", -r.wake)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(.secondary)
                }
            }
            .chartYScale(domain: -high ... -low)
            .chartYAxis {
                AxisMarks(values: .stride(by: 2)) { v in
                    AxisGridLine()
                    AxisValueLabel { Text(SleepAnalysis.clock(-(v.as(Double.self) ?? 0))) }
                }
            }
            .frame(height: 220)
            Legend(items: [("Weeknights", .indigo, .box), ("Before a weekend day", .purple.opacity(0.7), .box)])
        }
    }

    // MARK: Body clock

    private func bodyClock(_ nights: [SleepAnalysis.Night]) -> some View {
        let clock = SleepAnalysis.bodyClock(Array(nights.suffix(60)))
        return Panel(title: "Your body clock", subtitle: "The last 60 nights, weekdays against weekends") {
            if let c = clock {
                let jetlag = Int((abs(c.socialJetlag) * 60).rounded())
                MetricRow(metrics: [
                    Metric(label: "Social jetlag", symbol: "airplane", tint: .purple,
                           value: jetlag >= 60 ? "\(jetlag / 60) h \(jetlag % 60) min" : "\(jetlag) min",
                           note: c.socialJetlag >= 0 ? "later on weekends" : "earlier on weekends"),
                    Metric(label: "Chronotype", symbol: c.chronotype < 3.5 ? "sunrise" : c.chronotype < 5 ? "sun.max" : "moon.stars",
                           tint: .indigo, value: c.label, note: "mid-sleep \(SleepAnalysis.clock(c.chronotype)) on free days"),
                ])
                Chart {
                    window("Weekdays", mid: c.workdays, length: c.workdaySleep, color: .indigo)
                    window("Weekends", mid: c.freeDays, length: c.freeDaySleep, color: .purple.opacity(0.7))
                }
                .chartXScale(domain: (min(c.workdays - c.workdaySleep / 2, c.freeDays - c.freeDaySleep / 2) - 1).rounded(.down)...(max(c.workdays + c.workdaySleep / 2, c.freeDays + c.freeDaySleep / 2) + 1).rounded(.up))
                .chartXAxis {
                    AxisMarks(values: .stride(by: 2)) { v in
                        AxisGridLine()
                        AxisValueLabel { Text(SleepAnalysis.clock(v.as(Double.self) ?? 0)) }
                    }
                }
                .frame(height: 90)
                Text("The dot is the middle of your sleep. Social jetlag is how far it moves on weekends; an hour or more feels like flying a time zone every week.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("This needs a few weeks of weekday and weekend nights.").foregroundStyle(.secondary)
            }
        }
    }

    @ChartContentBuilder
    private func window(_ label: String, mid: Double, length: Double, color: Color) -> some ChartContent {
        BarMark(xStart: .value("Asleep", mid - length / 2), xEnd: .value("Awake", mid + length / 2), y: .value("When", label))
            .foregroundStyle(color)
            .cornerRadius(4)
        PointMark(x: .value("Mid-sleep", mid), y: .value("When", label))
            .foregroundStyle(.white)
            .symbolSize(70)
    }

    // MARK: Stages

    private func stages(_ nights: [SleepAnalysis.Night]) -> some View {
        let shares = SleepAnalysis.stageShares(nights)
        return Panel(title: "Sleep stages", subtitle: "Your average share of the night against the optimal range") {
            if shares.isEmpty {
                Text("No stages for these nights.").foregroundStyle(.secondary)
            } else {
                ForEach(SleepAnalysis.optimal, id: \.stage) { o in
                    StageBar(stage: o.stage, share: shares[o.stage] ?? 0, low: o.low, high: o.high, average: nil)
                }
            }
        }
    }

    private func nightly(_ nights: [SleepAnalysis.Night]) -> some View {
        let stages: [(String, Color, KeyPath<SleepAnalysis.Night, Double>)] = [
            ("Deep", StageBar.color("Deep"), \.deep), ("Light", StageBar.color("Light"), \.light),
            ("REM", StageBar.color("REM"), \.rem), ("Awake", StageBar.color("Awake"), \.awake),
        ]
        let average = nights.isEmpty ? nil : nights.map(\.asleep).reduce(0, +) / Double(nights.count)
        return ChartCard(title: "Night by night", subtitle: average.map { "Average \(Format.hoursMinutes(Int($0))) asleep" } ?? "") {
            Chart {
                ForEach(nights) { night in
                    ForEach(stages, id: \.0) { name, _, path in
                        BarMark(x: .value("Night", night.date, unit: .day), y: .value("Hours", night[keyPath: path] / 3600))
                            .foregroundStyle(by: .value("Stage", name))
                    }
                }
                if let average {
                    RuleMark(y: .value("Average", average / 3600))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(.secondary)
                }
            }
            .chartForegroundStyleScale(domain: stages.map(\.0), range: stages.map(\.1))
            .chartYAxisLabel("hours")
        }
    }

    private var method: some View {
        Text("""
        How it's worked out: sleep need and the optimal stage ranges come from your watch's sleep data, the need worked out each night from your usual need, training and HRV. Sleep debt adds up the last 14 nights \
        (two weeks of short nights add up, Van Dongen et al. 2003). Regularity is the standard deviation of bedtime and wake-up. Social jetlag is mid-sleep \
        on weekends minus weekdays (Wittmann et al. 2006); chronotype is weekend mid-sleep corrected for catching up on sleep (Roenneberg et al. 2004). \
        Not medical advice.
        """)
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Last night's stages, each against Garmin's optimal range, with the 30-night average as a tick.
struct StageRanges: View {
    let night: SleepAnalysis.Night
    let average: [String: Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(SleepAnalysis.optimal, id: \.stage) { o in
                let seconds = o.stage == "Deep" ? night.deep : o.stage == "Light" ? night.light : night.rem
                StageBar(stage: o.stage, share: night.share(seconds), low: o.low, high: o.high, average: average[o.stage],
                         minutes: Int(seconds / 60))
            }
            if night.awake > 0 {
                Text("Awake \(Format.hoursMinutes(Int(night.awake))) during the night.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct StageBar: View {
    let stage: String
    let share: Double
    let low: Double
    let high: Double
    let average: Double?
    var minutes: Int?

    static func color(_ stage: String) -> Color {
        switch stage {
        case "Deep": .indigo
        case "Light": .blue
        case "REM": .purple
        default: .pink
        }
    }

    private var verdict: String { share < low ? "below the range" : share > high ? "above the range" : "in range" }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(stage).font(.subheadline.weight(.semibold))
                Text(minutes.map { "\(Format.hoursMinutes($0 * 60)) · \(Int(share.rounded()))%" } ?? "\(Int(share.rounded()))%")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            .frame(width: 110, alignment: .leading)
            // 0–70% across: every optimal range fits, and the bars stay comparable.
            GeometryReader { geo in
                let scale = geo.size.width / 70
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary).frame(height: 8)
                    Capsule().fill(Self.color(stage).opacity(0.22))
                        .frame(width: (high - low) * scale, height: 14)
                        .offset(x: low * scale)
                    Capsule().fill(Self.color(stage)).frame(width: max(min(share, 70) * scale, 4), height: 8)
                    if let average {
                        Rectangle().fill(.primary.opacity(0.6)).frame(width: 2, height: 16)
                            .offset(x: min(average, 70) * scale - 1)
                            .help("Your 30-night average: \(Int(average.rounded()))%")
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 18)
            Text(verdict).font(.caption).foregroundStyle(share < low || share > high ? .orange : .secondary)
                .frame(width: 100, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(stage) \(Int(share.rounded())) percent, \(verdict); optimal \(Int(low)) to \(Int(high)) percent")
    }
}

/// Heart rate through one night, fetched from Garmin when shown.
struct NightHeartRateChart: View {
    let date: String
    let start: Date
    let end: Date
    @State private var values: [(Date, Double)]?

    /// Tens around the night's lowest and highest, with room for the "Lowest" label below.
    static func domain(_ low: Double, _ high: Double) -> ClosedRange<Double> {
        let bottom: Double = ((low - 10) / 10).rounded(.down) * 10
        let top: Double = ((high + 5) / 10).rounded(.up) * 10
        return bottom...top
    }

    var body: some View {
        Group {
            if let values, !values.isEmpty {
                let lowest = values.min { $0.1 < $1.1 }!
                let highest = values.max { $0.1 < $1.1 }!
                Chart {
                    ForEach(values, id: \.0) { v in
                        LineMark(x: .value("Time", v.0), y: .value("bpm", v.1))
                            .interpolationMethod(.catmullRom)
                            .foregroundStyle(.red)
                    }
                    PointMark(x: .value("Time", lowest.0), y: .value("bpm", lowest.1))
                        .foregroundStyle(.red)
                        .annotation(position: .bottom) { Text("Lowest \(Int(lowest.1))").font(.caption2.weight(.semibold)) }
                }
                .chartYScale(domain: Self.domain(lowest.1, highest.1))
                .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 1)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour()) } }
                .chartYAxisLabel("bpm")
            } else if values == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("No heart rate for this night.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: 160)
        .task(id: date) {
            values = nil
            values = await NightCache.heartRate(date, from: start, to: end)
        }
    }
}
