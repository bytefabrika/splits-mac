import Charts
import SwiftData
import SwiftUI

/// Heart rate variability, read the way sports scientists read it: last night's curve, the 7-day average
/// against your own normal range, how much it swings, how it moves with resting heart rate, and what tends
/// to come before a low or high morning.
struct HRVView: View {
    enum Range: String, CaseIterable, Identifiable {
        case months3 = "3 months", months6 = "6 months", year = "1 year"
        var id: String { rawValue }
        var days: Int { switch self { case .months3: 91; case .months6: 182; case .year: 365 } }
    }

    @Query(sort: \Day.date) private var days: [Day]
    @Query(sort: \Activity.start) private var activities: [Activity]
    @State private var range: Range = .months3
    @State private var model: Model?
    /// The night shown in "Last night", as an index into the mornings with HRV. Nil is the newest.
    @State private var nightIndex: Int?

    struct Model {
        var mornings: [HRVAnalysis.Morning]
        var series: [HRVAnalysis.Point]
        var pairs: [HRVAnalysis.Pair]
        var drivers: [HRVAnalysis.Driver]
        var restingHR: [(date: Date, bpm: Int)]
        var loadRatio: Double?
    }

    private var since: Date { Calendar.current.date(byAdding: .day, value: -range.days, to: Date())! }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if let model, let latest = model.mornings.last {
                        InsightCard(key: "hrvTake", title: "Your HRV", symbol: "waveform.path.ecg", colors: [.teal, .blue, .indigo],
                                    night: GarminDate.string(latest.date)) {
                            Coach.hrvFacts(days: days, activities: activities)
                        }
                        summary(model)
                        lastNight(model)
                        trend(model)
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: 20) { swing(model); quadrant(model) }
                            VStack(alignment: .leading, spacing: 28) { swing(model); quadrant(model) }
                        }
                        drivers(model)
                        restingHR(model)
                        method
                    } else if model != nil {
                        ContentUnavailableView("No HRV yet", systemImage: "waveform.path.ecg",
                                               description: Text("HRV is measured while you sleep, on watches that support it. Wear yours to bed and it shows up here."))
                    }
                }
                .padding(24)
                .frame(maxWidth: 1240)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .defaultScrollAnchor(DebugFlags.scrollBottom ? .bottom : .top)
            .navigationTitle("HRV")
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
        .task(id: "\(days.count)-\(days.last?.date ?? "")-\(days.last?.hrvLastNight ?? 0)") {
            let mornings = HRVAnalysis.mornings(days)
            model = Model(mornings: mornings, series: HRVAnalysis.series(mornings), pairs: HRVAnalysis.pairs(days),
                          drivers: HRVAnalysis.drivers(days: days, activities: activities),
                          restingHR: days.compactMap { d in d.restingHR.map { (d.day, $0) } },
                          loadRatio: HRVAnalysis.loadRatio(activities))
        }
    }

    // MARK: Summary

    private func summary(_ model: Model) -> some View {
        let latest = model.series.last
        let last = model.mornings.last!
        let status = days.last { $0.hrvLastNight != nil }?.hrvStatus.map { Format.title($0.lowercased()) }
        var metrics = [Metric(label: "Last night", symbol: "moon.stars", tint: .teal, value: "\(Int(last.ms)) ms",
                              note: status.map { "status: \($0.lowercased())" })]
        if let latest {
            let range = latest.lowMs.flatMap { low in latest.highMs.map { "normal \(Int(low.rounded()))–\(Int($0.rounded())) ms" } }
            metrics.append(Metric(label: "7-day average", symbol: "chart.line.uptrend.xyaxis", tint: .teal,
                                  value: "\(Int(latest.meanMs.rounded())) ms", note: range ?? "normal range after 60 days"))
            metrics.append(Metric(label: "Day-to-day swing", symbol: "arrow.up.arrow.down", tint: .indigo,
                                  value: String(format: "%.1f%%", latest.cv),
                                  note: latest.usualCV.map { String(format: "usually %.1f%%", $0) }))
        }
        let resting = model.restingHR.suffix(7).map(\.bpm)
        if !resting.isEmpty {
            metrics.append(Metric(label: "Resting HR", symbol: "heart", tint: .red, value: "\(resting.reduce(0, +) / resting.count) bpm",
                                  note: "7-day average"))
        }
        if let ratio = model.loadRatio {
            metrics.append(Metric(label: "Training load", symbol: "flame", tint: .orange, value: String(format: "%.1f×", ratio),
                                  note: "this week against the usual week"))
        }
        return MetricRow(metrics: metrics).padding(.horizontal, 4)
    }

    // MARK: Last night

    private func lastNight(_ model: Model) -> some View {
        let index = min(nightIndex ?? model.mornings.count - 1, model.mornings.count - 1)
        let morning = model.mornings[index]
        let date = GarminDate.string(morning.date)
        let day = days.first { $0.date == date }
        return Panel(title: index == model.mornings.count - 1 ? "Last night" : morning.date.formatted(.dateTime.weekday(.wide).day().month(.wide)),
                     subtitle: "A reading every 5 minutes while you slept") {
            HStack(spacing: 2) {
                Button { nightIndex = max(index - 1, 0) } label: { Image(systemName: "chevron.left") }
                    .disabled(index == 0).help("The night before")
                Button { nightIndex = min(index + 1, model.mornings.count - 1) } label: { Image(systemName: "chevron.right") }
                    .disabled(index == model.mornings.count - 1).help("The night after")
            }
            .buttonStyle(.borderless)
        } content: {
            NightHRVChart(date: date, average: morning.ms, low: day?.hrvBalancedLow, high: day?.hrvBalancedHigh)
        }
    }

    // MARK: Trend

    private func trend(_ model: Model) -> some View {
        let since = since
        let points = model.series.filter { $0.date >= since }
        let mornings = model.mornings.filter { $0.date >= since }
        let banded = points.filter { $0.low != nil }
        let level = model.series.last.flatMap(HRVAnalysis.level)
        let subtitle = switch level {
        case .below: "The 7-day average is below your normal range"
        case .above: "The 7-day average is above your normal range"
        case .within: "The 7-day average is inside your normal range"
        case nil: "Your normal range appears after 60 days of nights"
        }
        return Panel(title: "Against your normal", subtitle: subtitle) {
            Chart {
                ForEach(banded) { p in
                    AreaMark(x: .value("Day", p.date), yStart: .value("Low", p.lowMs!), yEnd: .value("High", p.highMs!),
                             series: .value("s", "range"))
                        .foregroundStyle(.teal.opacity(0.15))
                }
                ForEach(mornings) { m in
                    PointMark(x: .value("Day", m.date), y: .value("ms", m.ms))
                        .symbolSize(14)
                        .foregroundStyle(.teal.opacity(0.4))
                }
                ForEach(points) { p in
                    LineMark(x: .value("Day", p.date), y: .value("ms", p.meanMs), series: .value("s", "7-day"))
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 2.5))
                        .foregroundStyle(.teal)
                }
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartYAxisLabel("ms")
            .frame(height: 220)
            Legend(items: [("7-day average", .teal, .line), ("Each morning", .teal.opacity(0.5), .dot), ("Normal range", .teal.opacity(0.25), .box)])
        }
    }

    // MARK: Swing

    private func swing(_ model: Model) -> some View {
        let since = since
        let points = model.series.filter { $0.date >= since }
        return Panel(title: "Day-to-day swing", subtitle: "How much HRV moves within a week") {
            Chart {
                ForEach(points) { p in
                    LineMark(x: .value("Day", p.date), y: .value("%", p.cv), series: .value("s", "cv"))
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(.indigo)
                }
                ForEach(points.filter { $0.usualCV != nil }) { p in
                    LineMark(x: .value("Day", p.date), y: .value("%", p.usualCV!), series: .value("s", "usual"))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(.secondary)
                }
            }
            .chartYAxisLabel("%")
            .frame(height: 200)
            Text("A sudden rise often comes with hard training, travel, illness or short nights. The dashed line is your usual.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Quadrant

    private func quadrant(_ model: Model) -> some View {
        let recent = Array(model.pairs.suffix(28))
        let clamp = { (x: Double) in min(max(x, -3), 3) }
        return Panel(title: "HRV and resting heart rate", subtitle: "The last 4 weeks, each against your normal") {
            Chart {
                RuleMark(x: .value("x", 0)).foregroundStyle(Color.secondary.opacity(0.5))
                RuleMark(y: .value("y", 0)).foregroundStyle(Color.secondary.opacity(0.5))
                ForEach(recent.indices, id: \.self) { i in
                    let p = recent[i]
                    let isLast = i == recent.count - 1
                    PointMark(x: .value("Resting HR", clamp(p.restingHR)), y: .value("HRV", clamp(p.hrv)))
                        .symbolSize(isLast ? 110 : 30)
                        .foregroundStyle(isLast ? Color.teal : Color.teal.opacity(0.15 + 0.5 * Double(i) / Double(max(recent.count, 1))))
                        .annotation(position: .trailing, spacing: 4) {
                            if isLast { Text("Last night").font(.caption2.weight(.semibold)) }
                        }
                }
            }
            .chartXScale(domain: -3...3)
            .chartYScale(domain: -3...3)
            .chartXAxis { AxisMarks(values: [-2, 0, 2]) { v in AxisGridLine(); AxisValueLabel { Text(axisLabel(v.as(Double.self) ?? 0, low: "lower", high: "higher")) } } }
            .chartYAxis { AxisMarks(values: [-2, 0, 2]) { v in AxisGridLine(); AxisValueLabel { Text(axisLabel(v.as(Double.self) ?? 0, low: "lower", high: "higher")) } } }
            .chartXAxisLabel("Resting heart rate", alignment: .center)
            .chartYAxisLabel("HRV")
            // The corners' names inside the plot, clear of the axis labels.
            .chartOverlay { proxy in
                GeometryReader { geo in
                    if let plot = proxy.plotFrame {
                        let frame = geo[plot]
                        ZStack {
                            corner("Recovered", .topLeading)
                            corner("Under strain", .bottomTrailing)
                            corner("Mixed", .topTrailing)
                            corner("Mixed", .bottomLeading)
                        }
                        .padding(6)
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                    }
                }
            }
            .frame(height: 200)
        }
    }

    private func axisLabel(_ v: Double, low: String, high: String) -> String { v == 0 ? "normal" : v < 0 ? low : high }

    private func corner(_ text: String, _ alignment: Alignment) -> some View {
        Text(text).font(.caption2).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .allowsHitTesting(false)
    }

    // MARK: Drivers

    private func drivers(_ model: Model) -> some View {
        let groups = ["Training the day before", "Bedtime", "Sleep", "Night"].filter { g in model.drivers.contains { $0.group == g } }
        return Panel(title: "What comes before a low or high morning",
                     subtitle: "Your mornings over the last year, against your normal at the time") {
            if groups.isEmpty {
                Text("This fills in after a couple of months of nights.").foregroundStyle(.secondary)
            } else {
                // Room past the longest bar for its label.
                let extent = max(5, (model.drivers.map { abs($0.percent) }.max() ?? 5).rounded(.up)) * 1.35
                CardGrid(minWidth: 300, spacing: 20, cards: groups.map { group in
                    let rows = model.drivers.filter { $0.group == group }
                    return AnyView(VStack(alignment: .leading, spacing: 6) {
                        Text(group).font(.subheadline.weight(.semibold))
                        Chart(rows) { d in
                            BarMark(x: .value("%", d.percent), y: .value("When", d.label))
                                .foregroundStyle(d.percent < 0 ? Color.orange : Color.teal)
                                .annotation(position: d.percent < 0 ? .leading : .trailing, spacing: 4) {
                                    Text("\(d.percent > 0 ? "+" : "")\(Int(d.percent.rounded()))%")
                                        .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                                }
                            RuleMark(x: .value("normal", 0)).foregroundStyle(Color.secondary.opacity(0.5))
                        }
                        .chartXScale(domain: -extent...extent)
                        .chartXAxis(.hidden)
                        .frame(height: CGFloat(rows.count) * 30)
                    })
                })
                Text("These go together; they don't prove one causes the other. Groups with fewer than 5 mornings are left out.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Resting heart rate

    private func restingHR(_ model: Model) -> some View {
        let since = since
        let points = model.restingHR.filter { $0.date >= since }
        let average = points.isEmpty ? nil : points.map(\.bpm).reduce(0, +) / points.count
        return ChartCard(title: "Resting heart rate", subtitle: average.map { "Average \($0) bpm" } ?? "") {
            Chart(points, id: \.date) { p in
                LineMark(x: .value("Day", p.date), y: .value("bpm", p.bpm))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(.red)
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartYAxisLabel("bpm")
        }
    }

    private var method: some View {
        Text("""
        How it's worked out: HRV is compared as ln(rMSSD). The 7-day average is set against your normal range, the mean of the 60 days before ± half a standard deviation, \
        the smallest change worth noticing (Plews et al. 2012, 2013). The swing is the coefficient of variation over 7 days. Resting heart rate and HRV are shown as \
        distance from your own normal (Buchheit 2014). Not medical advice.
        """)
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// One night's HRV, fetched from Garmin when shown.
struct NightHRVChart: View {
    let date: String
    let average: Double
    var low: Int?
    var high: Int?
    @State private var readings: [(Date, Double)]?

    var body: some View {
        Group {
            if let readings, !readings.isEmpty {
                let peak = readings.max { $0.1 < $1.1 }!
                Chart {
                    ForEach(readings, id: \.0) { r in
                        AreaMark(x: .value("Time", r.0), y: .value("ms", r.1))
                            .interpolationMethod(.catmullRom)
                            .foregroundStyle(LinearGradient(colors: [.teal.opacity(0.35), .teal.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("Time", r.0), y: .value("ms", r.1))
                            .interpolationMethod(.catmullRom)
                            .foregroundStyle(.teal)
                    }
                    RuleMark(y: .value("Average", average))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(.secondary)
                        .annotation(position: .top, alignment: .leading) {
                            Text("Average \(Int(average)) ms").font(.caption2).foregroundStyle(.secondary)
                        }
                    PointMark(x: .value("Time", peak.0), y: .value("ms", peak.1))
                        .foregroundStyle(.teal)
                        .annotation(position: .top) { Text("\(Int(peak.1)) ms").font(.caption2.weight(.semibold)) }
                }
                .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 1)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour()) } }
                .chartYAxisLabel("ms")
            } else if readings == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("No readings for this night.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: 200)
        .task(id: date) {
            readings = nil
            readings = await NightCache.hrv(date)
        }
    }
}

/// A small legend for charts that mix marks.
struct Legend: View {
    enum Kind { case line, dot, box }
    let items: [(String, Color, Kind)]

    var body: some View {
        HStack(spacing: 16) {
            ForEach(items.indices, id: \.self) { i in
                let (label, color, kind) = items[i]
                HStack(spacing: 6) {
                    switch kind {
                    case .line: Capsule().fill(color).frame(width: 14, height: 3)
                    case .dot: Circle().fill(color).frame(width: 7, height: 7)
                    case .box: RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 12, height: 10)
                    }
                    Text(label)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
