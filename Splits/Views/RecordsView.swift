import Charts
import SwiftData
import SwiftUI

/// Fastest 1 km, 5 km, 10 km, half and marathon, from inside every outdoor run (not just whole runs of that
/// length), how they've improved, and the best of each year.
struct RecordsView: View {
    struct Effort: Identifiable {
        let activity: Int64
        let date: Date
        let name: String
        let label: String
        let seconds: Double
        var id: String { "\(activity)-\(label)" }
    }

    @Query(sort: \Activity.start, order: .reverse) private var activities: [Activity]
    @Environment(\.format) private var format
    @State private var efforts: [Effort] = []
    @State private var distance = "5 km"
    private var finder: RecordFinder { .shared }

    private var runs: [Activity] { Records.candidates(activities) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if !finder.finished || finder.running { progress }
                    cards
                    if !efforts.isEmpty { predictions }
                    if !efforts.isEmpty {
                        progression
                        byYear
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .navigationTitle("Records")
            .navigationDestination(for: Int64.self) { id in
                if let activity = activities.first(where: { $0.garminId == id }) { ActivityPage(activity: activity) }
            }
        }
        .task(id: activities.count) {
            let ids = runs.map(\.garminId)
            await finder.count(ids)
            if !finder.finished { finder.start(ids) }
        }
        .task(id: "\(finder.version)-\(activities.count)") { await load() }
    }

    private func load() async {
        let all = await RecordStore.shared.all()
        let byID = Dictionary(uniqueKeysWithValues: runs.map { ($0.garminId, $0) })
        var list: [Effort] = []
        for (id, bests) in all {
            guard let a = byID[id] else { continue }
            let name = a.name.isEmpty ? Format.title(a.typeKey) : a.name
            for (label, seconds) in bests { list.append(Effort(activity: id, date: a.start, name: name, label: label, seconds: seconds)) }
        }
        efforts = list.sorted { $0.date < $1.date }
    }

    // MARK: Progress

    private var progress: some View {
        HStack(spacing: 14) {
            ProgressView(value: Double(finder.done), total: Double(max(finder.total, 1)))
                .frame(width: 160)
            VStack(alignment: .leading, spacing: 2) {
                Text(finder.running ? "Looking through your runs: \(finder.done) of \(finder.total)" : "\(finder.done) of \(finder.total) runs looked through")
                    .font(.callout.weight(.semibold)).monospacedDigit()
                Text("Each run's file is downloaded once to find its fastest stretches; only the times are kept. About half a second a run.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(finder.running ? "Pause" : "Continue") {
                if finder.running { finder.pause() } else { finder.start(runs.map(\.garminId)) }
            }
        }
        .padding(14)
        .card()
    }

    // MARK: Cards

    private func best(_ label: String, in list: [Effort]? = nil) -> Effort? {
        (list ?? efforts).filter { $0.label == label }.min { $0.seconds < $1.seconds }
    }

    private func pace(_ e: Effort) -> String {
        let metres = Records.distances.first { $0.label == e.label }?.metres ?? 1000
        return format.pace(secondsPerKm: e.seconds / metres * 1000)
    }

    /// Five records side by side, each one opening the run it came from.
    private var cards: some View {
        Panel(title: "Personal records", subtitle: "The fastest stretch inside any outdoor run") {
            Grid(alignment: .topLeading, horizontalSpacing: 0) {
                GridRow {
                    ForEach(Array(Records.distances.enumerated()), id: \.element.label) { i, d in
                        let e = best(d.label)
                        HStack(spacing: 0) {
                            if i > 0 { Divider().padding(.horizontal, 8) }
                            NavigationLink(value: e?.activity ?? 0) {
                                RecordColumn(title: d.label, symbol: "trophy", tint: .orange,
                                             value: e.map { Format.duration($0.seconds) } ?? "–",
                                             detail: e.map(pace),
                                             note: e.map { "\($0.name) · \($0.date.formatted(date: .abbreviated, time: .omitted))" }
                                                ?? (finder.finished ? "No run this long yet" : "Still looking…"),
                                             opens: e != nil)
                            }
                            .buttonStyle(.plain)
                            .disabled(e == nil)
                        }
                    }
                }
            }
        }
    }

    // MARK: Race predictions

    private var predictions: some View {
        let predictor = RacePredictor(efforts: efforts.map { ($0.activity, $0.date, $0.label, $0.seconds) })
        return Panel(title: "If you raced today", subtitle: "Predicted from your best efforts of the last \(predictor.months) months") {
            if predictor.predictions.isEmpty {
                Text("Needs a run of 5 km or more in the last year.").foregroundStyle(.secondary)
            } else {
                Grid(alignment: .topLeading, horizontalSpacing: 0) {
                    GridRow {
                        ForEach(Array(predictor.predictions.enumerated()), id: \.element.id) { i, p in
                            HStack(spacing: 0) {
                                if i > 0 { Divider().padding(.horizontal, 8) }
                                NavigationLink(value: p.source.activity) {
                                    RecordColumn(title: p.label, symbol: "flag.checkered", tint: Sport.run.color,
                                                 value: Format.duration(p.seconds),
                                                 detail: format.pace(secondsPerKm: p.seconds / p.metres * 1000),
                                                 note: "From your \(p.source.label) of \(Format.duration(p.source.seconds)), \(p.source.date.formatted(.dateTime.day().month(.abbreviated)))",
                                                 opens: true)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                Text("Riegel's formula on the fastest stretches inside your runs. Training efforts are rarely all-out, so on a rested race day you'll often beat these. The marathon also needs the long runs to back it up.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Progression

    private var progression: some View {
        let list = efforts.filter { $0.label == distance }
        // The record as it stood at each point: a step down every time you beat it.
        var record = Double.infinity
        let steps: [(Date, Double)] = list.compactMap { e in
            guard e.seconds < record else { return nil }
            record = e.seconds
            return (e.date, e.seconds)
        } + (list.isEmpty ? [] : [(Date(), record)])
        let broken = steps.count - 1
        // A few walks with a run in the middle sit far below the rest and squash the chart: the slowest 5% are left off.
        let sorted = list.map(\.seconds).sorted()
        let slowest = sorted.isEmpty ? 1 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        let fastest = sorted.first ?? 0
        let shown = list.filter { $0.seconds <= slowest }

        return Panel(title: "How your record came down",
                     subtitle: list.isEmpty ? "No \(distance) efforts yet" : "\(list.count) runs with a \(distance) in them · record broken \(max(broken - 1, 0)) times") {
            Picker("Distance", selection: $distance) {
                ForEach(Records.distances, id: \.label) { Text($0.label).tag($0.label) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        } content: {
            Chart {
                ForEach(shown) { e in
                    PointMark(x: .value("Date", e.date), y: .value("Time", -e.seconds))
                        .symbolSize(14)
                        .foregroundStyle(Sport.run.color.opacity(0.35))
                }
                ForEach(steps.indices, id: \.self) { i in
                    LineMark(x: .value("Date", steps[i].0), y: .value("Time", -steps[i].1), series: .value("Line", "record"))
                        .interpolationMethod(.stepEnd)
                        .foregroundStyle(.orange)
                        .lineStyle(StrokeStyle(lineWidth: 2.5))
                    if i < steps.count - 1 {
                        PointMark(x: .value("Date", steps[i].0), y: .value("Time", -steps[i].1))
                            .foregroundStyle(.orange)
                            .symbolSize(40)
                    }
                }
            }
            .chartYScale(domain: -(slowest * 1.02)...(-(fastest * 0.98)))
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel { if let v = value.as(Double.self) { Text(Format.duration(-v)) } }
                }
            }
            .frame(height: 240)
            .drawingGroup()
        }
    }

    // MARK: By year

    private var byYear: some View {
        let calendar = Calendar.current
        let years = Set(efforts.map { calendar.component(.year, from: $0.date) }).sorted(by: >)
        let allTime = Dictionary(uniqueKeysWithValues: Records.distances.compactMap { d in best(d.label).map { (d.label, $0.id) } })

        return Panel(title: "Best of each year", subtitle: "The trophy marks the all-time record") {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    Text("")
                    ForEach(Records.distances, id: \.label) { Text($0.label).font(.caption.bold()).foregroundStyle(.secondary) }
                }
                Divider()
                ForEach(years, id: \.self) { year in
                    let inYear = efforts.filter { calendar.component(.year, from: $0.date) == year }
                    GridRow {
                        Text(String(year)).font(.callout.weight(.semibold)).monospacedDigit()
                        ForEach(Records.distances, id: \.label) { d in
                            if let e = best(d.label, in: inYear) {
                                NavigationLink(value: e.activity) {
                                    HStack(spacing: 3) {
                                        Text(Format.duration(e.seconds)).monospacedDigit()
                                        if allTime[d.label] == e.id { Image(systemName: "trophy.fill").foregroundStyle(.orange).font(.caption2) }
                                    }
                                    .fontWeight(allTime[d.label] == e.id ? .bold : .regular)
                                }
                                .buttonStyle(.plain)
                                .help("\(e.name) · \(e.date.formatted(date: .abbreviated, time: .omitted)) · \(pace(e))")
                            } else {
                                Text("–").foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// One number in a row of them: what it is, the number, a detail and where it came from. Hover shows it opens.
struct RecordColumn: View {
    let title: String
    let symbol: String
    let tint: Color
    let value: String
    let detail: String?
    let note: String
    let opens: Bool
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbol).foregroundStyle(tint)
            }
            .font(.subheadline).foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title, design: .rounded).weight(.semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
            if let detail { Text(detail).font(.callout).monospacedDigit().foregroundStyle(.secondary) }
            Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(hovering ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 && opens }
        .accessibilityElement(children: .combine)
    }
}
