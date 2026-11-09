import Charts
import MapKit
import SwiftData
import SwiftUI

/// The full activity screen: Garmin's summary and detail, plus route, charts and splits from the activity file.
struct ActivityPage: View {
    let activity: Activity
    @Environment(\.format) private var format
    @State private var analysis: TrackAnalysis?
    @State private var detail: ActivityDetailDTO.Summary?
    @State private var location: String?
    @State private var zoneFloors: [Int] = []
    @State private var loadError: String?
    /// The chart cursor, in the user's distance unit (km or miles).
    @State private var selectedKm: Double?
    @State private var exploringMap = false
    @State private var sharing = false

    private var sport: Sport { activity.sport }
    private var isPaceSport: Bool { [.run, .walk, .hike].contains(sport) }
    private var title: String { activity.name.isEmpty ? Format.title(activity.typeKey) : activity.name }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                StatGroups(activity: activity, detail: detail, isPaceSport: isPaceSport)
                CoachCard(activity: activity, analysis: analysis)

                if let analysis {
                    if !analysis.route.isEmpty && !Sport.isIndoor(activity.typeKey) {
                        // A still picture of the map: a live map in a scrolling page is slow and catches the scroll wheel.
                        RouteSnapshot(analysis: analysis, sport: sport, selectedKm: selectedKm.map { format.imperial ? $0 * 1.609344 : $0 })
                            .frame(height: 380)
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                            .onTapGesture(count: 2) { exploringMap = true }
                            .overlay(alignment: .topTrailing) {
                                Button { exploringMap = true } label: {
                                    Label("Explore map", systemImage: "arrow.up.left.and.arrow.down.right")
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.black.opacity(0.65))
                                .padding(12)
                            }
                            .overlay(alignment: .bottomLeading) { PaceLegend().padding(12) }
                    }
                    TrackCharts(analysis: analysis, activity: activity, zoneFloors: zoneFloors, isPaceSport: isPaceSport,
                                selectedKm: $selectedKm)
                    HStack(alignment: .top, spacing: 18) {
                        if !analysis.splits.isEmpty { SplitsCard(analysis: analysis, sport: sport, isPaceSport: isPaceSport) }
                        VStack(spacing: 18) {
                            VersusUsual(activity: activity)
                            if sport == .run && !analysis.bests.isEmpty { BestsCard(analysis: analysis) }
                            ZonesCard(activity: activity, floors: zoneFloors)
                            EffectCard(activity: activity)
                        }
                        .frame(width: 340)
                    }
                } else if let loadError {
                    Label(loadError, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                    HStack(alignment: .top, spacing: 18) {
                        VersusUsual(activity: activity)
                        ZonesCard(activity: activity, floors: zoneFloors)
                        EffectCard(activity: activity)
                    }
                } else {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Getting the activity file from Garmin…").foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 30)
                }
            }
            .padding(24)
            .frame(maxWidth: 1180)
            // Fill the scroll view and take hits everywhere: on macOS, empty space (padding, gaps, margins)
            // otherwise doesn't receive the scroll wheel.
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .navigationTitle(title)
        .task(id: activity.garminId) { await load() }
        .toolbar {
            ToolbarItem {
                Button { sharing = true } label: { Label("Share", systemImage: "square.and.arrow.up") }
                    .help("Make a picture of this activity to share")
            }
        }
        .sheet(isPresented: $sharing) {
            ShareSheet(activity: activity, route: analysis?.route ?? [])
        }
        .sheet(isPresented: $exploringMap) {
            if let analysis {
                MapExplorer(analysis: analysis, sport: sport, title: title)
            }
        }
    }

    private func load() async {
        analysis = nil
        loadError = nil
        let id = activity.garminId
        let sport = self.sport
        async let detailTask = try? Tracks.shared.detail(for: id)
        async let zonesTask = Tracks.shared.zones(for: sport)
        do {
            let track = try await Tracks.shared.track(for: id)
            let length = format.imperial ? 1609.344 : 1000
            analysis = await Task.detached { TrackAnalysis(track, splitLength: length) }.value
        } catch {
            loadError = "Couldn't load the activity file: \(error.localizedDescription)"
        }
        let fetched = await detailTask
        detail = fetched?.summaryDTO
        location = fetched?.locationName
        zoneFloors = await zonesTask
    }

    // MARK: Header

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [sport.color, sport.color.opacity(0.6), .black.opacity(0.35)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: sport.symbol)
                .font(.system(size: 170, weight: .bold))
                .foregroundStyle(.white.opacity(0.16))
                .rotationEffect(.degrees(-8))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .offset(x: -24, y: 26)
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(Format.title(activity.typeKey).uppercased())
                        .font(.caption.weight(.heavy)).tracking(1.5).opacity(0.85)
                    Text(title).font(.system(size: 32, weight: .heavy, design: .rounded)).lineLimit(2)
                    HStack(spacing: 6) {
                        Text(activity.start, format: .dateTime.weekday(.wide).day().month(.wide).year().hour().minute())
                        if let location { Text("· \(location)") }
                    }
                    .opacity(0.9)
                    HStack(spacing: 8) {
                        if activity.isPR { Badge(text: "Personal record", symbol: "trophy.fill") }
                        if activity.isFavorite { Badge(text: "Favourite", symbol: "heart.fill") }
                        if let feel = detail?.directWorkoutFeel { Badge(text: Self.feel(feel), symbol: "face.smiling") }
                        if let rpe = detail?.directWorkoutRpe { Badge(text: "Effort \(Int(rpe / 10))/10", symbol: "flame.fill") }
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    if activity.distance > 0 {
                        Text(format.distance(activity.distance, decimals: 2))
                            .font(.system(size: 40, weight: .heavy, design: .rounded)).monospacedDigit()
                    }
                    Text(Format.duration(activity.activeSeconds))
                        .font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit().opacity(0.9)
                }
            }
            .foregroundStyle(.white)
            .padding(26)
        }
        .frame(height: 210)
        .clipShape(RoundedRectangle(cornerRadius: 22))
        // No shadow: a big blurred shadow is redrawn on every frame while scrolling.
    }

    /// Garmin's "how did it feel": 0, 25, 50, 75, 100.
    static func feel(_ value: Double) -> String {
        switch value {
        case ..<13: "Felt very weak"
        case ..<38: "Felt weak"
        case ..<63: "Felt normal"
        case ..<88: "Felt strong"
        default: "Felt very strong"
        }
    }
}

// MARK: - Stats

/// The numbers, grouped: overview, effort, body, running dynamics, power.
struct StatGroups: View {
    let activity: Activity
    let detail: ActivityDetailDTO.Summary?
    let isPaceSport: Bool
    @Environment(\.format) private var format

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 14)], alignment: .leading, spacing: 14) {
            ForEach(groups, id: \.title) { group in
                VStack(alignment: .leading, spacing: 12) {
                    Label(group.title, systemImage: group.symbol).font(.subheadline.weight(.semibold)).foregroundStyle(group.tint)
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                        ForEach(Array(stride(from: 0, to: group.items.count, by: 2)), id: \.self) { i in
                            GridRow {
                                cell(group.items[i])
                                if i + 1 < group.items.count { cell(group.items[i + 1]) } else { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]) }
                            }
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
                .background(group.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    private func cell(_ item: (String, String)) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.0.uppercased()).font(.caption2.weight(.bold)).tracking(0.6).foregroundStyle(.secondary)
            Text(item.1).font(.system(size: 19, weight: .bold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private struct StatGroup { let title: String; let symbol: String; let tint: Color; let items: [(String, String)] }

    private var groups: [StatGroup] {
        let a = activity, d = detail
        var overview: [(String, String)] = []
        if a.distance > 0 { overview.append(("Distance", format.distance(a.distance))) }
        overview.append(a.sport.isDistanceSport ? ("Moving time", Format.duration(a.movingDuration)) : ("Time", Format.duration(a.duration)))
        if isPaceSport, let pace = a.paceSecondsPerKm {
            overview.append(("Avg pace", format.pace(secondsPerKm: pace)))
            if let gap = d?.avgGradeAdjustedSpeed, gap > 0 { overview.append(("Grade-adjusted", format.pace(secondsPerKm: 1000 / gap))) }
        } else if let speed = a.averageSpeed, speed > 0 {
            overview.append(("Avg speed", format.speed(metresPerSecond: speed)))
        }
        if a.elevationGain > 0 && !Sport.isIndoor(a.typeKey) { overview.append(("Climb", format.elevation(a.elevationGain))) }
        if a.sport.isDistanceSport, a.duration - a.movingDuration > 60 { overview.append(("Stopped", Format.duration(a.duration - a.movingDuration))) }
        if let c = a.calories { overview.append(("Calories", "\(Int(c)) kcal")) }

        var effort: [(String, String)] = []
        if let hr = a.averageHR { effort.append(("Avg heart rate", "\(Int(hr)) bpm")) }
        if let max = a.maxHR { effort.append(("Max heart rate", "\(Int(max)) bpm")) }
        if let load = a.trainingLoad { effort.append(("Training load", "\(Int(load))")) }
        if let te = a.aerobicEffect { effort.append(("Aerobic effect", String(format: "%.1f", te))) }
        if let rec = d?.recoveryHeartRate, rec > 0 { effort.append(("Recovery HR", "−\(Int(rec)) bpm")) }
        if let vig = d?.vigorousIntensityMinutes {
            effort.append(("Intensity min", "\(Int(vig * 2 + (d?.moderateIntensityMinutes ?? 0)))"))
        }

        var body: [(String, String)] = []
        if let bb = d?.differenceBodyBattery { body.append(("Body Battery", bb > 0 ? "+\(Int(bb))" : "\(Int(bb))")) }
        if let water = d?.waterEstimated, water > 0 { body.append(("Sweat loss", String(format: "%.1f L", water / 1000))) }
        if let start = d?.beginPotentialStamina, let end = d?.endPotentialStamina {
            body.append(("Stamina", "\(Int(start))% → \(Int(end))%"))
        }
        if let t = d?.averageTemperature { body.append(("Temperature", "\(Int(t.rounded())) °C")) }
        if let steps = a.steps, steps > 0 { body.append(("Steps", steps.formatted())) }

        var dynamics: [(String, String)] = []
        if let cadence = a.cadence { dynamics.append(("Cadence", "\(Int(cadence)) spm")) }
        if let stride = d?.strideLength, stride > 0 { dynamics.append(("Stride", String(format: "%.2f m", stride / 100))) }
        if let gct = d?.groundContactTime, gct > 0 { dynamics.append(("Ground contact", "\(Int(gct)) ms")) }
        if let vo = d?.verticalOscillation, vo > 0 { dynamics.append(("Vertical osc.", String(format: "%.1f cm", vo))) }
        if let vr = d?.verticalRatio, vr > 0 { dynamics.append(("Vertical ratio", String(format: "%.1f%%", vr))) }

        var power: [(String, String)] = []
        if let p = a.averagePower { power.append(("Avg power", "\(Int(p)) W")) }
        if let np = d?.normalizedPower { power.append(("Normalized", "\(Int(np)) W")) }
        if let max = d?.maxPower { power.append(("Max power", "\(Int(max)) W")) }
        if let work = d?.totalWork, work > 0 { power.append(("Work", "\(Int(work)) kJ")) }

        return [
            StatGroup(title: "Overview", symbol: "chart.bar.fill", tint: activity.sport.color, items: overview),
            StatGroup(title: "Effort", symbol: "heart.fill", tint: .red, items: effort),
            StatGroup(title: "Body", symbol: "bolt.heart.fill", tint: .blue, items: body),
            StatGroup(title: "Running dynamics", symbol: "figure.run", tint: .orange, items: dynamics),
            StatGroup(title: "Power", symbol: "bolt.fill", tint: .purple, items: power),
        ].filter { !$0.items.isEmpty }
    }
}

// MARK: - Map

/// The route, coloured by pace: blue where it was slow, through to orange-red where it was fast.
struct RouteMap: View {
    let analysis: TrackAnalysis
    let sport: Sport
    var selectedKm: Double?
    let interactive: Bool

    struct Segment: Identifiable { let id: Int; let coordinates: [CLLocationCoordinate2D]; let color: Color }

    static func segments(_ analysis: TrackAnalysis) -> [Segment] {
        let located = analysis.samples.filter { $0.coordinate != nil }
        guard located.count > 2 else { return [] }
        let speeds = located.compactMap(\.speed).filter { $0 > 0.3 }.sorted()
        guard !speeds.isEmpty else {
            return [Segment(id: 0, coordinates: located.compactMap(\.coordinate), color: .orange)]
        }
        let low = speeds[speeds.count / 10], high = speeds[speeds.count * 9 / 10]
        let chunk = max(located.count / 160, 1)
        var segments: [Segment] = []
        var i = 0
        while i < located.count - 1 {
            let slice = located[i...min(i + chunk, located.count - 1)]
            let speed = slice.compactMap(\.speed).reduce(0, +) / Double(max(slice.count, 1))
            let t = high > low ? min(max((speed - low) / (high - low), 0), 1) : 0.5
            segments.append(Segment(id: i, coordinates: slice.compactMap(\.coordinate), color: paceColor(t)))
            i += chunk
        }
        return segments
    }

    /// 0 = slow (blue) … 1 = fast (red).
    static func paceColor(_ t: Double) -> Color {
        let stops: [(Double, Double, Double)] = [(0.25, 0.55, 1.0), (0.2, 0.85, 0.6), (1.0, 0.8, 0.2), (1.0, 0.35, 0.25)]
        let x = t * Double(stops.count - 1)
        let i = min(Int(x), stops.count - 2), f = x - Double(i)
        let a = stops[i], b = stops[i + 1]
        return Color(red: a.0 + (b.0 - a.0) * f, green: a.1 + (b.1 - a.1) * f, blue: a.2 + (b.2 - a.2) * f)
    }

    var body: some View {
        let segments = Self.segments(analysis)
        let selected = selectedKm.flatMap { km in analysis.samples.min { abs($0.km - km) < abs($1.km - km) } }
        Map(initialPosition: .automatic, interactionModes: interactive ? .all : []) {
            ForEach(segments) { segment in
                MapPolyline(coordinates: segment.coordinates)
                    .stroke(segment.color, style: StrokeStyle(lineWidth: interactive ? 6 : 5, lineCap: .round, lineJoin: .round))
            }
            if let first = analysis.route.first {
                Annotation("Start", coordinate: first) {
                    Circle().fill(.green).frame(width: 16, height: 16).overlay(Circle().stroke(.white, lineWidth: 3)).shadow(radius: 2)
                }
            }
            if let last = analysis.route.last {
                Annotation("Finish", coordinate: last) {
                    Image(systemName: "flag.checkered.circle.fill").font(.title).foregroundStyle(.white, .black).shadow(radius: 2)
                }
            }
            if let coordinate = selected?.coordinate {
                Annotation("", coordinate: coordinate) {
                    ZStack {
                        Circle().fill(sport.color.opacity(0.3)).frame(width: 34, height: 34)
                        Circle().fill(sport.color).frame(width: 16, height: 16).overlay(Circle().stroke(.white, lineWidth: 3))
                    }
                    .shadow(radius: 4)
                }
            }
        }
        .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .excludingAll))
    }
}

struct PaceLegend: View {
    var body: some View {
        HStack(spacing: 6) {
            Text("Slower").font(.caption2.weight(.semibold))
            LinearGradient(colors: (0...4).map { RouteMap.paceColor(Double($0) / 4) }, startPoint: .leading, endPoint: .trailing)
                .frame(width: 90, height: 6).clipShape(Capsule())
            Text("Faster").font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .foregroundStyle(.white)
        .background(Color.black.opacity(0.55), in: Capsule())  // solid, not a blur: cheaper to scroll
    }
}

/// The big, explorable map, in a sheet.
struct MapExplorer: View {
    let analysis: TrackAnalysis
    let sport: Sport
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        RouteMap(analysis: analysis, sport: sport, interactive: true)
            .overlay(alignment: .top) {
                HStack {
                    Label(title, systemImage: sport.symbol).font(.headline)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).controlSize(.large)
                }
                .padding(14)
            }
            .overlay(alignment: .bottomLeading) { PaceLegend().padding(14) }
            .frame(minWidth: 900, idealWidth: 1100, minHeight: 640, idealHeight: 760)
    }
}

// MARK: - Charts

/// Heart rate, pace, elevation, cadence and power along the activity, sharing one cursor.
struct TrackCharts: View {
    let analysis: TrackAnalysis
    let activity: Activity
    let zoneFloors: [Int]
    let isPaceSport: Bool
    @Binding var selectedKm: Double?
    @Environment(\.format) private var format

    private var toUnit: Double { format.imperial ? 1 / 1.609344 : 1 }
    private var maxX: Double { max((analysis.samples.last?.km ?? 1) * toUnit, 0.01) }

    var body: some View {
        let samples = analysis.samples
        let selected = selectedKm.flatMap { x in samples.min { abs($0.km * toUnit - x) < abs($1.km * toUnit - x) } }
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Along the way").font(.title3.bold())
                Spacer()
                readout(selected)
            }
            if samples.contains(where: { $0.heartRate != nil }) { heartRate(samples, selected) }
            if samples.contains(where: { ($0.speed ?? 0) > 0.3 }) { pace(samples, selected) }
            if samples.contains(where: { $0.altitude != nil }) && !Sport.isIndoor(activity.typeKey) { elevation(samples, selected) }
            if samples.filter({ ($0.cadence ?? 0) > 0 }).count > samples.count / 2 { cadence(samples, selected) }
            if samples.filter({ ($0.power ?? 0) > 0 }).count > samples.count / 2 { power(samples, selected) }
        }
        .padding(18)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder
    private func readout(_ s: TrackAnalysis.Sample?) -> some View {
        if let s {
            HStack(spacing: 14) {
                Text(format.distance(s.km * 1000)).fontWeight(.semibold)
                Text(Format.duration(s.time)).foregroundStyle(.secondary)
                if let hr = s.heartRate { Label("\(Int(hr))", systemImage: "heart.fill").foregroundStyle(.red) }
                if let v = s.speed, v > 0.3 {
                    Label(isPaceSport ? format.pace(secondsPerKm: 1000 / v) : format.speed(metresPerSecond: v), systemImage: "speedometer")
                        .foregroundStyle(activity.sport.color)
                }
                if let a = s.altitude { Label(format.elevation(a), systemImage: "mountain.2.fill").foregroundStyle(.green) }
            }
            .font(.callout.monospacedDigit())
        } else {
            Text("Hover over a chart to follow the route").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func frame<C: View>(_ title: String, _ symbol: String, _ tint: Color, height: CGFloat = 130,
                                @ViewBuilder _ chart: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol).font(.caption.weight(.semibold)).foregroundStyle(tint)
            chart()
                .chartXScale(domain: 0...maxX)
                .chartXSelection(value: $selectedKm)
                .chartXAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let v = value.as(Double.self) { Text("\(v.formatted(.number.precision(.fractionLength(0...1)))) \(format.distanceUnit)") }
                        }
                    }
                }
                .frame(height: height)
                // One flattened layer per chart instead of hundreds of marks to composite while scrolling.
                .drawingGroup()
        }
    }

    @ChartContentBuilder
    private func cursor(_ s: TrackAnalysis.Sample?) -> some ChartContent {
        if let s {
            RuleMark(x: .value("At", s.km * toUnit))
                .foregroundStyle(.primary.opacity(0.35))
                .lineStyle(StrokeStyle(lineWidth: 1))
        }
    }

    private func range(_ values: [Double], pad: Double) -> ClosedRange<Double> {
        guard let low = values.min(), let high = values.max(), high > low else { return 0...1 }
        return (low - pad)...(high + pad)
    }

    private func heartRate(_ samples: [TrackAnalysis.Sample], _ selected: TrackAnalysis.Sample?) -> some View {
        let values = samples.compactMap(\.heartRate)
        let domain = range(values, pad: 6)
        // Colour the area by the user's own zones: each band takes its zone's colour.
        let colors: [Color] = [.gray, .blue, .green, .orange, .red]
        let style: AnyShapeStyle
        if zoneFloors.count == 5 {
            var stops: [Gradient.Stop] = []
            let span = domain.upperBound - domain.lowerBound
            var current = Color.gray.opacity(0.35)
            stops.append(.init(color: current, location: 0))
            for (i, floor) in zoneFloors.enumerated() {
                let location = (Double(floor) - domain.lowerBound) / span
                guard location > 0 && location < 1 else {
                    if location <= 0 { current = colors[i].opacity(0.5); stops[0] = .init(color: current, location: 0) }
                    continue
                }
                stops.append(.init(color: current, location: location))
                current = colors[i].opacity(0.5)
                stops.append(.init(color: current, location: location))
            }
            stops.append(.init(color: current, location: 1))
            style = AnyShapeStyle(LinearGradient(stops: stops, startPoint: .bottom, endPoint: .top))
        } else {
            style = AnyShapeStyle(LinearGradient(colors: [.red.opacity(0.4), .red.opacity(0.05)], startPoint: .top, endPoint: .bottom))
        }
        return frame("Heart rate", "heart.fill", .red, height: 150) {
            Chart {
                ForEach(samples.filter { $0.heartRate != nil }) { s in
                    AreaMark(x: .value("Distance", s.km * toUnit), yStart: .value("Base", domain.lowerBound), yEnd: .value("bpm", s.heartRate!))
                        .foregroundStyle(style)
                    LineMark(x: .value("Distance", s.km * toUnit), y: .value("bpm", s.heartRate!))
                        .foregroundStyle(.red)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
                cursor(selected)
            }
            .chartYScale(domain: domain)
        }
    }

    private func pace(_ samples: [TrackAnalysis.Sample], _ selected: TrackAnalysis.Sample?) -> some View {
        let unitMetres = format.imperial ? 1609.344 : 1000
        let minSpeed = isPaceSport ? 1.0 : 0.3
        let paceSport = isPaceSport, imperial = format.imperial
        func value(_ speed: Double) -> Double { paceSport ? unitMetres / speed : (imperial ? speed * 2.236936 : speed * 3.6) }
        // Faster pace is a smaller number but belongs at the top, so pace is drawn negated and labelled without
        // the sign. (A reversed ClosedRange would trap.)
        let sign = paceSport ? -1.0 : 1.0
        let moving = samples.filter { ($0.speed ?? 0) > minSpeed }
        // Keep the axis on the bulk of the activity: a stop or a GPS glitch shouldn't stretch it.
        let sorted = moving.map { value($0.speed!) }.sorted()
        let low = sorted.isEmpty ? 0 : sorted[sorted.count / 50]
        let high = sorted.isEmpty ? 1 : sorted[min(sorted.count * 49 / 50, sorted.count - 1)]
        let pad = max((high - low) * 0.15, isPaceSport ? 10 : 1)
        let domain = paceSport ? (-(high + pad))...(-(low - pad)) : (low - pad)...(high + pad)
        let average = isPaceSport ? activity.paceSecondsPerKm.map { $0 * unitMetres / 1000 } : activity.averageSpeed.map(value)
        return frame(isPaceSport ? "Pace" : "Speed", "speedometer", activity.sport.color) {
            Chart {
                ForEach(moving) { s in
                    LineMark(x: .value("Distance", s.km * toUnit),
                             y: .value("Pace", min(max(sign * value(s.speed!), domain.lowerBound), domain.upperBound)))
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(activity.sport.color)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                }
                if let average {
                    RuleMark(y: .value("Average", sign * average))
                        .foregroundStyle(activity.sport.color.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .annotation(position: .top, alignment: .leading) {
                            Text("average").font(.caption2).foregroundStyle(.secondary)
                        }
                }
                cursor(selected)
            }
            .chartYScale(domain: domain)
            .chartYAxis {
                AxisMarks { v in
                    AxisGridLine()
                    AxisValueLabel {
                        if let x = v.as(Double.self) {
                            Text(paceSport ? String(format: "%d:%02d", Int(abs(x)) / 60, Int(abs(x)) % 60) : "\(Int(x))")
                        }
                    }
                }
            }
        }
    }

    private func elevation(_ samples: [TrackAnalysis.Sample], _ selected: TrackAnalysis.Sample?) -> some View {
        let values = samples.compactMap(\.altitude)
        let span = (values.max() ?? 0) - (values.min() ?? 0)
        let domain = range(values, pad: max(span * 0.15, 3))
        return frame("Elevation", "mountain.2.fill", .green, height: 110) {
            Chart {
                ForEach(samples.filter { $0.altitude != nil }) { s in
                    AreaMark(x: .value("Distance", s.km * toUnit), yStart: .value("Base", domain.lowerBound), yEnd: .value("m", s.altitude!))
                        .foregroundStyle(LinearGradient(colors: [.green.opacity(0.55), .green.opacity(0.08)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Distance", s.km * toUnit), y: .value("m", s.altitude!))
                        .foregroundStyle(.green)
                        .lineStyle(StrokeStyle(lineWidth: 1.2))
                }
                cursor(selected)
            }
            .chartYScale(domain: domain)
        }
    }

    private func cadence(_ samples: [TrackAnalysis.Sample], _ selected: TrackAnalysis.Sample?) -> some View {
        // FIT stores running cadence per foot; steps per minute is twice that.
        let factor = isPaceSport ? 2.0 : 1.0
        let points = samples.filter { ($0.cadence ?? 0) > 0 }
        let sorted = points.map { $0.cadence! * factor }.sorted()
        let low = sorted.isEmpty ? 0 : sorted[sorted.count / 50], high = sorted.isEmpty ? 1 : sorted[min(sorted.count * 49 / 50, sorted.count - 1)]
        let domain = (low - 8)...(high + 8)
        return frame(isPaceSport ? "Cadence (spm)" : "Cadence (rpm)", "metronome.fill", .orange, height: 90) {
            Chart {
                ForEach(points) { s in
                    PointMark(x: .value("Distance", s.km * toUnit), y: .value("Cadence", min(max(s.cadence! * factor, domain.lowerBound), domain.upperBound)))
                        .symbolSize(6)
                        .foregroundStyle(.orange.opacity(0.7))
                }
                cursor(selected)
            }
            .chartYScale(domain: domain)
        }
    }

    private func power(_ samples: [TrackAnalysis.Sample], _ selected: TrackAnalysis.Sample?) -> some View {
        let points = samples.filter { ($0.power ?? 0) > 0 }
        let sorted = points.map { $0.power! }.sorted()
        let top = sorted.isEmpty ? 100 : sorted[min(sorted.count * 98 / 100, sorted.count - 1)] * 1.15
        return frame("Power (W)", "bolt.fill", .purple, height: 90) {
            Chart {
                ForEach(points) { s in
                    LineMark(x: .value("Distance", s.km * toUnit), y: .value("W", min(s.power!, top)))
                        .foregroundStyle(.purple)
                        .lineStyle(StrokeStyle(lineWidth: 1.2))
                }
                cursor(selected)
            }
            .chartYScale(domain: 0...top)
        }
    }
}

// MARK: - Cards

struct SplitsCard: View {
    let analysis: TrackAnalysis
    let sport: Sport
    let isPaceSport: Bool
    @Environment(\.format) private var format

    var body: some View {
        let full = analysis.splits.filter { $0.length > 0.9 * (format.imperial ? 1609.344 : 1000) }
        let rates = full.map { $0.seconds / $0.length }
        let fastest = rates.min() ?? 0, slowest = rates.max() ?? 1
        let average = rates.isEmpty ? 0 : rates.reduce(0, +) / Double(rates.count)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Splits").font(.title3.bold())
                Spacer()
                if rates.count >= 4 {
                    let half = rates.count / 2
                    let firstHalf = rates.prefix(half).reduce(0, +) / Double(half)
                    let secondHalf = rates.suffix(half).reduce(0, +) / Double(half)
                    let negative = secondHalf < firstHalf
                    Label(negative ? "Negative split" : "Positive split", systemImage: negative ? "arrow.down.right" : "arrow.up.right")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background((negative ? Color.green : Color.orange).opacity(0.18), in: Capsule())
                        .help("The second half was \(negative ? "faster" : "slower") than the first")
                }
            }
            HStack(spacing: 10) {
                Text(format.distanceUnit).frame(width: 24, alignment: .trailing)
                Spacer()
                Text(isPaceSport ? "Pace" : "Speed").frame(width: 92, alignment: .trailing)
                Text("HR").frame(width: 46, alignment: .trailing)
                Text("Climb").frame(width: 50, alignment: .trailing)
                Color.clear.frame(width: 14)
            }
            .font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            ForEach(analysis.splits) { split in
                let rate = split.seconds / split.length
                let isFastest = abs(rate - fastest) < 1e-9
                HStack(spacing: 10) {
                    Text("\(split.id)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 24, alignment: .trailing)
                    let share = slowest > fastest ? 0.25 + 0.75 * (slowest - rate) / (slowest - fastest) : 1
                    Capsule().fill(.quaternary.opacity(0.5))
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(isFastest ? sport.color : (rate <= average ? sport.color : sport.color.opacity(0.45)).opacity(0.75))
                                .scaleEffect(x: min(max(share, 0.06), 1), anchor: .leading)
                        }
                        .frame(height: 14)
                    Text(isPaceSport ? format.pace(secondsPerKm: rate * 1000) : format.speed(metresPerSecond: 1 / rate))
                        .font(.callout.monospacedDigit().weight(isFastest ? .bold : .regular))
                        .frame(width: 92, alignment: .trailing)
                    Text(split.averageHR.map { "\(Int($0))" } ?? "–")
                        .font(.caption.monospacedDigit()).foregroundStyle(.red.opacity(0.8)).frame(width: 46, alignment: .trailing)
                    Text(split.climb >= 1 ? "+\(Int(split.climb))" : "–")
                        .font(.caption.monospacedDigit()).foregroundStyle(.green).frame(width: 50, alignment: .trailing)
                    if isFastest { Image(systemName: "bolt.fill").foregroundStyle(sport.color).frame(width: 14) } else { Color.clear.frame(width: 14) }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18))
    }
}

/// This activity next to the average of the last ten of the same sport.
struct VersusUsual: View {
    let activity: Activity
    @Environment(\.modelContext) private var context
    @Environment(\.format) private var format
    /// Fetched once when the page opens, not on every redraw.
    @State private var previous: [Activity] = []

    var body: some View {
        Group {
            if previous.count >= 3 {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Versus your usual", systemImage: "arrow.left.arrow.right").font(.headline)
                    Text("Compared with your last \(previous.count) \(activity.sport.label.lowercased()) sessions")
                        .font(.caption).foregroundStyle(.secondary)
                    if activity.distance > 0 {
                        let avg = previous.reduce(0) { $0 + $1.distance } / Double(previous.count)
                        if avg > 0 { row("Distance", format.distance(activity.distance), change: activity.distance / avg - 1, higherIsBetter: true) }
                    }
                    let paces = previous.compactMap(\.paceSecondsPerKm)
                    if [.run, .walk, .hike].contains(activity.sport), let pace = activity.paceSecondsPerKm, !paces.isEmpty {
                        let avg = paces.reduce(0, +) / Double(paces.count)
                        row("Pace", format.pace(secondsPerKm: pace), change: avg / pace - 1, higherIsBetter: true)
                    }
                    let hrs = previous.compactMap(\.averageHR)
                    if let hr = activity.averageHR, !hrs.isEmpty {
                        let avg = hrs.reduce(0, +) / Double(hrs.count)
                        row("Avg heart rate", "\(Int(hr)) bpm", change: hr / avg - 1, higherIsBetter: nil)
                    }
                    let loads = previous.compactMap(\.trainingLoad).filter { $0 > 0 }
                    if let load = activity.trainingLoad, !loads.isEmpty {
                        let avg = loads.reduce(0, +) / Double(loads.count)
                        row("Training load", "\(Int(load))", change: load / avg - 1, higherIsBetter: nil)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .task(id: activity.garminId) {
            let before = activity.start
            var query = FetchDescriptor<Activity>(predicate: #Predicate { $0.start < before },
                                                  sortBy: [SortDescriptor(\.start, order: .reverse)])
            query.fetchLimit = 80
            previous = Array(((try? context.fetch(query)) ?? []).filter { $0.sport == activity.sport }.prefix(10))
        }
    }

    /// `higherIsBetter`: nil when it's neither good nor bad (heart rate, load).
    private func row(_ label: String, _ value: String, change: Double, higherIsBetter: Bool?) -> some View {
        let percent = Int((change * 100).rounded())
        let tint: Color = higherIsBetter == nil || percent == 0 ? .secondary : ((change > 0) == higherIsBetter! ? .green : .orange)
        return HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit().fontWeight(.semibold)
            Label("\(percent > 0 ? "+" : "")\(percent)%", systemImage: percent > 0 ? "arrow.up" : percent < 0 ? "arrow.down" : "equal")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 66, alignment: .trailing)
        }
    }
}

struct BestsCard: View {
    let analysis: TrackAnalysis
    @Environment(\.format) private var format

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Fastest stretches", systemImage: "stopwatch").font(.headline)
            ForEach(analysis.bests) { best in
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct ZonesCard: View {
    let activity: Activity
    let floors: [Int]

    var body: some View {
        if activity.hrZones.count == 5, activity.hrZones.contains(where: { $0 > 0 }) {
            let colors: [Color] = [.gray, .blue, .green, .orange, .red]
            let names = ["Warm up", "Easy", "Aerobic", "Threshold", "Maximum"]
            let total = max(activity.hrZones.reduce(0, +), 1)
            VStack(alignment: .leading, spacing: 10) {
                Text("Heart rate zones").font(.headline)
                HStack(spacing: 16) {
                    Chart(Array(activity.hrZones.enumerated()), id: \.offset) { zone, seconds in
                        SectorMark(angle: .value("Time", seconds), innerRadius: .ratio(0.62), angularInset: 1.5)
                            .foregroundStyle(colors[zone])
                    }
                    .frame(width: 104, height: 104)
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(activity.hrZones.enumerated()).reversed(), id: \.offset) { zone, seconds in
                            HStack(spacing: 6) {
                                Circle().fill(colors[zone]).frame(width: 8, height: 8)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text("\(zone + 1) · \(names[zone])").font(.caption)
                                    if floors.count == 5 {
                                        Text(zone < 4 ? "\(floors[zone])–\(floors[zone + 1] - 1) bpm" : "\(floors[zone])+ bpm")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Text("\(Int(seconds / total * 100))%").font(.caption.monospacedDigit().weight(.semibold))
                            }
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

struct EffectCard: View {
    let activity: Activity
    var body: some View {
        if let aerobic = activity.aerobicEffect {
            VStack(alignment: .leading, spacing: 10) {
                Text("Training effect").font(.headline)
                HStack(spacing: 20) {
                    EffectGauge(label: "Aerobic", value: aerobic, tint: .teal)
                    EffectGauge(label: "Anaerobic", value: activity.anaerobicEffect ?? 0, tint: .purple)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Self.describe(aerobic)).font(.callout.weight(.semibold))
                        Text("Garmin's 0–5 scale for how much this session moved your fitness.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    static func describe(_ value: Double) -> String {
        switch value {
        case ..<1: "No benefit"
        case ..<2: "Minor benefit"
        case ..<3: "Maintaining"
        case ..<4: "Improving"
        case ..<5: "Highly improving"
        default: "Overreaching"
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
    /// Checked once when the card appears: asking the system on every redraw is wasted work.
    @State private var status: Coach.Status = .unavailable("")

    var body: some View {
        content.onAppear { status = Coach.status }
    }

    @ViewBuilder private var content: some View {
        if case .unavailable(let reason) = status, activity.coachNote == nil {
            if #available(macOS 26, *), !reason.isEmpty {
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
                    Text(Coach.withoutDashes(shown))
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
                    .disabled(analysis == nil)
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
                in: RoundedRectangle(cornerRadius: 16)
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
