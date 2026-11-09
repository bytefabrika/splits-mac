import Charts
import MapKit
import SwiftData
import SwiftUI

/// The full activity screen: route, charts and splits from the activity file, plus Garmin's summary.
struct ActivityPage: View {
    let activity: Activity
    @Environment(\.format) private var format
    @State private var analysis: TrackAnalysis?
    @State private var loadError: String?
    @State private var selectedKm: Double?

    private var sport: Sport { activity.sport }
    private var isPaceSport: Bool { [.run, .walk, .hike].contains(sport) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                stats
                if let analysis {
                    CoachCard(activity: activity, analysis: analysis)
                    if !analysis.route.isEmpty && !Sport.isIndoor(activity.typeKey) { map(analysis) }
                    charts(analysis)
                    HStack(alignment: .top, spacing: 18) {
                        if !analysis.splits.isEmpty { splits(analysis) }
                        VStack(spacing: 18) {
                            if sport == .run && !analysis.bests.isEmpty { bests(analysis) }
                            zones
                            effect
                        }
                        .frame(maxWidth: 340)
                    }
                } else if let loadError {
                    Label(loadError, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                    CoachCard(activity: activity, analysis: nil)
                    HStack(alignment: .top, spacing: 18) { zones; effect }
                } else {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Getting the activity file from Garmin…").foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 30)
                }
            }
            .padding(24)
            .frame(maxWidth: 1100)
        }
        .navigationTitle(title)
        .task(id: activity.garminId) { await load() }
    }

    private var title: String { activity.name.isEmpty ? Format.title(activity.typeKey) : activity.name }

    private func load() async {
        analysis = nil
        loadError = nil
        do {
            let track = try await Tracks.shared.track(for: activity.garminId)
            let length = format.imperial ? 1609.344 : 1000
            analysis = await Task.detached { TrackAnalysis(track, splitLength: length) }.value
        } catch {
            loadError = "Couldn't load the activity file: \(error.localizedDescription)"
        }
    }

    // MARK: Header and stats

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [sport.color, sport.color.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: sport.symbol)
                .font(.system(size: 150, weight: .bold))
                .foregroundStyle(.white.opacity(0.18))
                .rotationEffect(.degrees(-8))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .offset(x: -20, y: 20)
            VStack(alignment: .leading, spacing: 6) {
                Text(Format.title(activity.typeKey).uppercased())
                    .font(.caption.weight(.heavy)).tracking(1.5).opacity(0.85)
                Text(title).font(.system(size: 30, weight: .heavy, design: .rounded)).lineLimit(2)
                Text(activity.start, format: .dateTime.weekday(.wide).day().month(.wide).year().hour().minute())
                    .opacity(0.85)
                HStack(spacing: 8) {
                    if activity.isPR { Badge(text: "Personal record", symbol: "trophy.fill") }
                    if activity.isFavorite { Badge(text: "Favourite", symbol: "heart.fill") }
                }
            }
            .foregroundStyle(.white)
            .padding(24)
        }
        .frame(height: 190)
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private var stats: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
            if activity.distance > 0 { BigStat(label: "Distance", value: format.distance(activity.distance), tint: sport.color) }
            BigStat(label: "Moving time", value: Format.duration(activity.movingDuration), tint: sport.color)
            if isPaceSport, let pace = activity.paceSecondsPerKm {
                BigStat(label: "Avg pace", value: format.pace(secondsPerKm: pace), tint: sport.color)
            } else if let speed = activity.averageSpeed, speed > 0 {
                BigStat(label: "Avg speed", value: format.speed(metresPerSecond: speed), tint: sport.color)
            }
            if activity.elevationGain > 0 && !Sport.isIndoor(activity.typeKey) {
                BigStat(label: "Climb", value: format.elevation(activity.elevationGain), tint: sport.color)
            }
            if let hr = activity.averageHR { BigStat(label: "Avg heart rate", value: "\(Int(hr)) bpm", tint: .red) }
            if let power = activity.averagePower { BigStat(label: "Avg power", value: "\(Int(power)) W", tint: .purple) }
            if let calories = activity.calories { BigStat(label: "Calories", value: "\(Int(calories))", tint: .orange) }
            if let load = activity.trainingLoad { BigStat(label: "Training load", value: "\(Int(load))", tint: .teal) }
        }
    }

    // MARK: Map

    private func map(_ a: TrackAnalysis) -> some View {
        let selected = selectedKm.flatMap { km in a.samples.min { abs($0.km - km) < abs($1.km - km) } }
        return Map(initialPosition: .automatic, interactionModes: [.zoom, .pan]) {
            MapPolyline(coordinates: a.route)
                .stroke(LinearGradient(colors: [sport.color, sport.color.opacity(0.6), .pink], startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            if let first = a.route.first {
                Annotation("Start", coordinate: first) {
                    Circle().fill(.green).frame(width: 14, height: 14).overlay(Circle().stroke(.white, lineWidth: 3))
                }
            }
            if let last = a.route.last {
                Annotation("Finish", coordinate: last) {
                    Image(systemName: "flag.checkered.circle.fill").font(.title2).foregroundStyle(.white, .black)
                }
            }
            if let coordinate = selected?.coordinate {
                Annotation("", coordinate: coordinate) {
                    Circle().fill(sport.color).frame(width: 16, height: 16)
                        .overlay(Circle().stroke(.white, lineWidth: 3))
                        .shadow(radius: 4)
                }
            }
        }
        .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .excludingAll))
        .frame(height: 360)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: Charts

    private func charts(_ a: TrackAnalysis) -> some View {
        let unit = format.distanceUnit
        let toUnit = format.imperial ? 1 / 1.609344 : 1.0
        let selected = selectedKm.flatMap { km in a.samples.min { abs($0.km - km) < abs($1.km - km) } }
        return VStack(spacing: 14) {
            if a.samples.contains(where: { $0.heartRate != nil }) {
                ChartCard(title: "Heart rate", subtitle: selected?.heartRate.map { "\(Int($0)) bpm" } ?? hrRange(a)) {
                    Chart {
                        ForEach(a.samples.filter { $0.heartRate != nil }) { s in
                            AreaMark(x: .value(unit, s.km * toUnit), y: .value("bpm", s.heartRate!))
                                .foregroundStyle(LinearGradient(colors: [.red.opacity(0.35), .red.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                            LineMark(x: .value(unit, s.km * toUnit), y: .value("bpm", s.heartRate!))
                                .foregroundStyle(.red)
                        }
                        selectionRule(selected, toUnit: toUnit)
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .chartXSelection(value: $selectedKm)
                }
            }
            if a.samples.contains(where: { ($0.speed ?? 0) > 0.3 }) {
                let paceTitle = isPaceSport ? "Pace" : "Speed"
                ChartCard(title: paceTitle, subtitle: selected.flatMap { paceText($0.speed) } ?? "") {
                    Chart {
                        ForEach(a.samples.filter { ($0.speed ?? 0) > (isPaceSport ? 1.0 : 0.3) }) { s in
                            LineMark(x: .value(unit, s.km * toUnit), y: .value(paceTitle, paceValue(s.speed!)))
                                .interpolationMethod(.catmullRom)
                                .foregroundStyle(sport.color)
                        }
                        selectionRule(selected, toUnit: toUnit)
                    }
                    .chartYScale(domain: .automatic(includesZero: false, reversed: isPaceSport))
                    .chartYAxis {
                        AxisMarks { value in
                            AxisGridLine()
                            AxisValueLabel { if let v = value.as(Double.self) { Text(isPaceSport ? minutes(v) : "\(Int(v))") } }
                        }
                    }
                    .chartXSelection(value: $selectedKm)
                }
            }
            if a.samples.contains(where: { $0.altitude != nil }) && !Sport.isIndoor(activity.typeKey) {
                ChartCard(title: "Elevation", subtitle: selected?.altitude.map { format.elevation($0) } ?? format.elevation(activity.elevationGain) + " climbed") {
                    Chart {
                        ForEach(a.samples.filter { $0.altitude != nil }) { s in
                            AreaMark(x: .value(unit, s.km * toUnit), y: .value("m", s.altitude!))
                                .foregroundStyle(LinearGradient(colors: [.green.opacity(0.5), .green.opacity(0.05)], startPoint: .top, endPoint: .bottom))
                        }
                        selectionRule(selected, toUnit: toUnit)
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .chartXSelection(value: $selectedKm)
                }
            }
        }
    }

    @ChartContentBuilder
    private func selectionRule(_ s: TrackAnalysis.Sample?, toUnit: Double) -> some ChartContent {
        if let s {
            RuleMark(x: .value("At", s.km * toUnit))
                .foregroundStyle(.secondary.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
    }

    private func hrRange(_ a: TrackAnalysis) -> String {
        let values = a.samples.compactMap(\.heartRate)
        guard let low = values.min(), let high = values.max() else { return "" }
        return "\(Int(low))–\(Int(high)) bpm"
    }

    /// Pace in seconds per km/mile for running-like sports, speed in km/h or mph otherwise.
    private func paceValue(_ speed: Double) -> Double {
        if isPaceSport { return min((format.imperial ? 1609.344 : 1000) / speed, 20 * 60) }
        return format.imperial ? speed * 2.236936 : speed * 3.6
    }

    private func paceText(_ speed: Double?) -> String? {
        guard let speed, speed > 0 else { return nil }
        return isPaceSport ? format.pace(secondsPerKm: 1000 / speed) : format.speed(metresPerSecond: speed)
    }

    private func minutes(_ seconds: Double) -> String { String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60) }

    // MARK: Splits, bests, zones, effect

    private func splits(_ a: TrackAnalysis) -> some View {
        let fastest = a.splits.filter { $0.length > 0.9 * (format.imperial ? 1609.344 : 1000) }.map { $0.seconds / $0.length }.min() ?? 0
        let slowest = a.splits.map { $0.seconds / $0.length }.max() ?? 1
        return VStack(alignment: .leading, spacing: 8) {
            Text("Splits").font(.headline)
            ForEach(a.splits) { split in
                let perMetre = split.seconds / split.length
                let isFastest = abs(perMetre - fastest) < 1e-9
                HStack(spacing: 10) {
                    Text("\(split.id)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 24, alignment: .trailing)
                    GeometryReader { geo in
                        let share = slowest > 0 ? (1.15 - perMetre / slowest) / (1.15 - fastest / slowest) : 1
                        Capsule()
                            .fill(isFastest ? AnyShapeStyle(sport.color.gradient) : AnyShapeStyle(sport.color.opacity(0.35)))
                            .frame(width: max(geo.size.width * min(max(share, 0.08), 1), 6))
                    }
                    .frame(height: 12)
                    Text(isPaceSport ? format.pace(secondsPerKm: perMetre * 1000) : format.speed(metresPerSecond: 1 / perMetre))
                        .font(.callout.monospacedDigit().weight(isFastest ? .bold : .regular))
                        .frame(width: 92, alignment: .trailing)
                    Text(split.averageHR.map { "\(Int($0)) bpm" } ?? "")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
                    if isFastest { Image(systemName: "bolt.fill").foregroundStyle(sport.color) } else { Color.clear.frame(width: 14) }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
    }

    private func bests(_ a: TrackAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Fastest stretches", systemImage: "stopwatch").font(.headline)
            ForEach(a.bests) { best in
                HStack {
                    Text(best.id).fontWeight(.semibold)
                    Spacer()
                    Text(Format.duration(best.seconds)).monospacedDigit()
                    Text(format.pace(secondsPerKm: best.seconds / best.distance * 1000))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder private var zones: some View {
        if activity.hrZones.count == 5, activity.hrZones.contains(where: { $0 > 0 }) {
            let colors: [Color] = [.gray, .blue, .green, .orange, .red]
            VStack(alignment: .leading, spacing: 10) {
                Text("Heart rate zones").font(.headline)
                HStack(spacing: 16) {
                    Chart(Array(activity.hrZones.enumerated()), id: \.offset) { zone, seconds in
                        SectorMark(angle: .value("Time", seconds), innerRadius: .ratio(0.62), angularInset: 1.5)
                            .foregroundStyle(colors[zone])
                    }
                    .frame(width: 110, height: 110)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(activity.hrZones.enumerated()).reversed(), id: \.offset) { zone, seconds in
                            HStack(spacing: 6) {
                                Circle().fill(colors[zone]).frame(width: 8, height: 8)
                                Text("Zone \(zone + 1)").font(.caption)
                                Spacer()
                                Text(Format.duration(seconds)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(16)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    @ViewBuilder private var effect: some View {
        if let aerobic = activity.aerobicEffect {
            VStack(alignment: .leading, spacing: 10) {
                Text("Training effect").font(.headline)
                HStack(spacing: 24) {
                    EffectGauge(label: "Aerobic", value: aerobic, tint: .teal)
                    EffectGauge(label: "Anaerobic", value: activity.anaerobicEffect ?? 0, tint: .purple)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

struct BigStat: View {
    let label: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased()).font(.caption2.weight(.bold)).tracking(0.8).foregroundStyle(.secondary)
            Text(value).font(.system(size: 24, weight: .bold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct Badge: View {
    let text: String
    let symbol: String
    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(.white.opacity(0.25), in: Capsule())
    }
}

struct EffectGauge: View {
    let label: String
    let value: Double
    let tint: Color
    var body: some View {
        VStack(spacing: 6) {
            Gauge(value: value, in: 0...5) {
                EmptyView()
            } currentValueLabel: {
                Text(value, format: .number.precision(.fractionLength(1))).font(.title3.bold())
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(tint)
            .scaleEffect(1.3)
            .frame(width: 70, height: 70)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// "Coach's take": a few paragraphs from Apple's on-device model, written on request and kept with the activity.
struct CoachCard: View {
    let activity: Activity
    let analysis: TrackAnalysis?
    @Environment(\.modelContext) private var context
    @Environment(\.format) private var format
    @State private var text = ""
    @State private var writing = false
    @State private var failure: String?

    var body: some View {
        let status = Coach.status
        if case .unavailable(let reason) = status, activity.coachNote == nil {
            if #available(macOS 26, *) {
                Label(reason, systemImage: "sparkles").font(.caption).foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Coach's take", systemImage: "sparkles")
                        .font(.headline)
                        .foregroundStyle(LinearGradient(colors: [.purple, .pink, .orange], startPoint: .leading, endPoint: .trailing))
                    Spacer()
                    Text("Written on your Mac by Apple Intelligence").font(.caption2).foregroundStyle(.secondary)
                    if activity.coachNote != nil && !writing && status == .ready {
                        Button { Task { await write() } } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless)
                            .help("Write it again")
                    }
                }
                let shown = writing ? text : (activity.coachNote ?? "")
                if !shown.isEmpty {
                    Text(shown)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .animation(.default, value: shown)
                } else if !writing {
                    Button {
                        Task { await write() }
                    } label: {
                        Label("What does the coach think?", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                }
                if writing && text.isEmpty {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Thinking…").foregroundStyle(.secondary) }
                }
                if let failure { Text(failure).font(.caption).foregroundStyle(.orange) }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(colors: [.purple.opacity(0.12), .pink.opacity(0.08), .orange.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 14)
            )
        }
    }

    private func write() async {
        writing = true
        failure = nil
        text = ""
        defer { writing = false }
        let before = activity.start
        var recentQuery = FetchDescriptor<Activity>(predicate: #Predicate { $0.start < before },
                                                    sortBy: [SortDescriptor(\.start, order: .reverse)])
        recentQuery.fetchLimit = 60
        let recent = (try? context.fetch(recentQuery)) ?? []
        let date = GarminDate.string(activity.start)
        let morning = (try? context.fetch(FetchDescriptor<Day>(predicate: #Predicate { $0.date == date })))?.first
        let facts = Coach.facts(activity: activity, analysis: analysis, recent: recent, morning: morning, format: format)
        do {
            try await Coach.write(facts: facts) { text = $0 }
            activity.coachNote = text.trimmingCharacters(in: .whitespacesAndNewlines)
            try? context.save()
        } catch {
            failure = "Couldn't write a take: \(error.localizedDescription)"
        }
    }
}
