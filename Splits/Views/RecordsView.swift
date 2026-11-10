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
                VStack(alignment: .leading, spacing: 20) {
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
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Cards

    private func best(_ label: String, in list: [Effort]? = nil) -> Effort? {
        (list ?? efforts).filter { $0.label == label }.min { $0.seconds < $1.seconds }
    }

    private func pace(_ e: Effort) -> String {
        let metres = Records.distances.first { $0.label == e.label }?.metres ?? 1000
        return format.pace(secondsPerKm: e.seconds / metres * 1000)
    }

    private var cards: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
            ForEach(Records.distances, id: \.label) { d in
                let e = best(d.label)
                NavigationLink(value: e?.activity ?? 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(d.label.uppercased(), systemImage: "trophy.fill")
                            .font(.caption.weight(.heavy)).tracking(0.8).foregroundStyle(.orange)
                        Text(e.map { Format.duration($0.seconds) } ?? "–")
                            .font(.system(size: 30, weight: .heavy, design: .rounded)).monospacedDigit()
                        if let e {
                            Text(pace(e)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            Text("\(e.name) · \(e.date.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        } else {
                            Text(finder.finished ? "No run this long yet" : "Still looking…")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(e == nil)
            }
        }
    }

    // MARK: Race predictions

    private var predictions: some View {
        let predictor = RacePredictor(efforts: efforts.map { ($0.activity, $0.date, $0.label, $0.seconds) })
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label("If you raced today", systemImage: "flag.checkered").font(.headline).foregroundStyle(Sport.run.color)
                Spacer()
                Text("From your best efforts of the last \(predictor.months) months").font(.caption).foregroundStyle(.secondary)
            }
            if predictor.predictions.isEmpty {
                Text("Needs a run of 5 km or more in the last year.").foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                    ForEach(predictor.predictions) { p in
                        NavigationLink(value: p.source.activity) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(p.label.uppercased()).font(.caption.weight(.heavy)).tracking(0.8).foregroundStyle(.secondary)
                                Text(Format.duration(p.seconds))
                                    .font(.system(size: 28, weight: .heavy, design: .rounded)).monospacedDigit()
                                Text(format.pace(secondsPerKm: p.seconds / p.metres * 1000)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                                Text("From your \(p.source.label) of \(Format.duration(p.source.seconds)), \(p.source.date.formatted(.dateTime.day().month(.abbreviated)))")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Sport.run.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text("Riegel's formula on the fastest stretches inside your runs. Training efforts are rarely all-out, so on a rested race day you'll often beat these. The marathon also needs the long runs to back it up.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
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

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("How your record came down").font(.headline)
                Spacer()
                Picker("Distance", selection: $distance) {
                    ForEach(Records.distances, id: \.label) { Text($0.label).tag($0.label) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Text(list.isEmpty ? "No \(distance) efforts yet." : "\(list.count) runs with a \(distance) in them · record broken \(max(broken - 1, 0)) times")
                .font(.caption).foregroundStyle(.secondary)
            Chart {
                ForEach(list) { e in
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
            .chartYScale(domain: .automatic(includesZero: false))
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel { if let v = value.as(Double.self) { Text(Format.duration(-v)) } }
                }
            }
            .frame(height: 240)
            .drawingGroup()
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: By year

    private var byYear: some View {
        let calendar = Calendar.current
        let years = Set(efforts.map { calendar.component(.year, from: $0.date) }).sorted(by: >)
        let allTime = Dictionary(uniqueKeysWithValues: Records.distances.compactMap { d in best(d.label).map { (d.label, $0.id) } })

        return VStack(alignment: .leading, spacing: 10) {
            Text("Best of each year").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    Text("")
                    ForEach(Records.distances, id: \.label) { Text($0.label).font(.caption.bold()).foregroundStyle(.secondary) }
                }
                Divider()
                ForEach(years, id: \.self) { year in
                    let inYear = efforts.filter { calendar.component(.year, from: $0.date) == year }
                    GridRow {
                        Text(String(year)).font(.callout.weight(.heavy)).monospacedDigit()
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
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
    }
}
