import Charts
import SwiftData
import SwiftUI

struct TrendsView: View {
    enum Range: String, CaseIterable, Identifiable {
        case months3 = "3 months", year = "1 year", all = "All time"
        var id: String { rawValue }
        var days: Int? {
            switch self {
            case .months3: 91
            case .year: 365
            case .all: nil
            }
        }
    }

    @Query(sort: \Day.date) private var allDays: [Day]
    @Query(sort: \Activity.start) private var allActivities: [Activity]
    @Environment(\.format) private var format
    @State private var range: Range = .year

    /// "the last year", "the last 3 months"
    private var period: String { range == .year ? "the last year" : "the last \(range.rawValue)" }

    private var since: Date {
        range.days.map { Calendar.current.date(byAdding: .day, value: -$0, to: Date())! } ?? .distantPast
    }

    var body: some View {
        let since = since
        let days = allDays.filter { $0.day >= since }
        let activities = allActivities.filter { $0.start >= since }

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    highlights(activities, days)
                    ActivityCalendar(activities: allActivities)
                    yearOverYear

                    // Side by side when there's room, stacked when there isn't: the charts' legends don't wrap,
                    // so a fixed pair pushed the page wider than the window.
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 20) {
                            weeklyDistance(activities)
                            sportMix(activities).frame(width: 320)
                        }
                        VStack(alignment: .leading, spacing: 28) {
                            weeklyDistance(activities)
                            sportMix(activities)
                        }
                    }
                    weeklyLoad(activities)
                    aerobicForm(since: since)
                    records(activities)
                }
                .padding(24)
                .frame(maxWidth: 1240)
                // Take hits everywhere, so the scroll wheel works over empty space too.
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .navigationTitle("Trends")
            .toolbar {
                // A segmented control in the toolbar switches what the whole view shows (segmented-controls.md, macOS).
                ToolbarItem(placement: .principal) {
                    Picker("Range", selection: $range) {
                        ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("How far back the summary and charts go")
                }
            }
            .navigationDestination(for: Int64.self) { id in
                if let activity = allActivities.first(where: { $0.garminId == id }) { ActivityPage(activity: activity) }
            }
        }
    }

    // MARK: Highlights

    private func highlights(_ activities: [Activity], _ days: [Day]) -> some View {
        let distance = activities.reduce(0) { $0 + $1.distance }
        let seconds = activities.reduce(0) { $0 + $1.activeSeconds }
        let climb = activities.filter { !Sport.isIndoor($0.typeKey) }.reduce(0) { $0 + $1.elevationGain }
        let sleep = average(days.compactMap(\.sleepSeconds))
        let hrv = average(days.compactMap(\.hrvLastNight))
        var metrics = [
            Metric(label: "Activities", symbol: "figure.mixed.cardio", tint: Sport.run.color, value: activities.count.formatted()),
            Metric(label: "Distance", symbol: "point.topleft.down.to.point.bottomright.curvepath", tint: Sport.ride.color, value: format.distance(distance, decimals: 0)),
            Metric(label: "Time moving", symbol: "stopwatch", tint: Sport.swim.color, value: "\(Int(seconds / 3600)) h"),
            Metric(label: "Climbed", symbol: "mountain.2", tint: Sport.hike.color, value: format.elevation(climb)),
        ]
        if let sleep { metrics.append(Metric(label: "Sleep", symbol: "bed.double", tint: .indigo, value: Format.hoursMinutes(sleep), note: "a night on average")) }
        if let hrv { metrics.append(Metric(label: "HRV", symbol: "waveform.path.ecg", tint: .teal, value: "\(hrv) ms", note: "overnight average")) }
        return Panel(title: "Summary", subtitle: range == .all ? "Everything since your first activity" : period.prefix(1).uppercased() + period.dropFirst()) {
            MetricRow(metrics: metrics)
        }
    }

    // MARK: Year over year

    private var yearOverYear: some View {
        let calendar = Calendar.current
        let thisYear = calendar.component(.year, from: Date())
        let lines = [thisYear - 1, thisYear].map { year -> (Int, [(Int, Double)]) in
            var total = 0.0
            let runs = allActivities.filter { calendar.component(.year, from: $0.start) == year && $0.distance > 0 }
            let points = runs.map { a -> (Int, Double) in
                total += format.distanceValue(a.distance)
                return (calendar.ordinality(of: .day, in: .year, for: a.start) ?? 1, total)
            }
            return (year, [(1, 0)] + points)
        }
        let now = lines.last?.1.last?.1 ?? 0
        let sameDayLastYear = lines.first?.1.last { $0.0 <= (calendar.ordinality(of: .day, in: .year, for: Date()) ?? 1) }?.1 ?? 0
        let delta = sameDayLastYear > 0 ? (now / sameDayLastYear - 1) * 100 : 0

        return ChartCard(title: "\(thisYear) vs \(thisYear - 1)",
                         subtitle: sameDayLastYear > 0 ? "\(delta >= 0 ? "+" : "")\(Int(delta))% on the same day last year" : "") {
            Chart {
                ForEach(lines, id: \.0) { year, points in
                    ForEach(points, id: \.0) { day, total in
                        LineMark(x: .value("Day of year", day), y: .value(format.distanceUnit, total))
                            .foregroundStyle(by: .value("Year", String(year)))
                            .lineStyle(StrokeStyle(lineWidth: year == thisYear ? 3 : 2, dash: year == thisYear ? [] : [5, 4]))
                    }
                }
            }
            .chartForegroundStyleScale([String(thisYear - 1): Color.gray, String(thisYear): Sport.run.color])
            .chartXScale(domain: 1...366)
            .chartXAxis {
                AxisMarks(values: [1, 32, 60, 91, 121, 152, 182, 213, 244, 274, 305, 335]) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let day = value.as(Int.self) {
                            Text(Calendar.current.shortMonthSymbols[[1, 32, 60, 91, 121, 152, 182, 213, 244, 274, 305, 335].firstIndex(of: day) ?? 0])
                        }
                    }
                }
            }
            .chartYAxisLabel(format.distanceUnit)
        }
    }

    // MARK: Weekly

    private struct ZoneWeek: Identifiable { let id: String; let start: Date; let zone: Int; let minutes: Double }

    private struct WeekSport: Identifiable { let id: String; let start: Date; let label: String; let value: Double }

    private func weekly(_ activities: [Activity], value: (Activity) -> Double, group: (Activity) -> String?) -> [WeekSport] {
        let calendar = Calendar.current
        var totals: [String: WeekSport] = [:]
        for a in activities {
            guard let label = group(a) else { continue }
            let start = calendar.dateInterval(of: .weekOfYear, for: a.start)?.start ?? a.start
            let id = "\(start.timeIntervalSince1970)-\(label)"
            totals[id] = WeekSport(id: id, start: start, label: label, value: (totals[id]?.value ?? 0) + value(a))
        }
        return totals.values.sorted { $0.start < $1.start }
    }

    private func weeklyDistance(_ activities: [Activity]) -> some View {
        let main: Set<Sport> = [.run, .ride, .swim, .walk, .hike]
        let weeks = weekly(activities, value: { format.distanceValue($0.distance) },
                           group: { main.contains($0.sport) && $0.distance > 0 ? $0.sport.label : nil })
        return ChartCard(title: "Distance per week", subtitle: format.distanceUnit) {
            Chart(weeks) { week in
                BarMark(x: .value("Week", week.start, unit: .weekOfYear), y: .value(format.distanceUnit, week.value))
                    .foregroundStyle(by: .value("Sport", week.label))
            }
            .chartForegroundStyleScale(domain: main.sorted { $0.rawValue < $1.rawValue }.map(\.label),
                                       range: main.sorted { $0.rawValue < $1.rawValue }.map(\.color))
        }
    }

    private func weeklyLoad(_ activities: [Activity]) -> some View {
        let zoneNames = ["Zone 1", "Zone 2", "Zone 3", "Zone 4", "Zone 5"]
        let zoneColors: [Color] = [.gray, .blue, .green, .orange, .red]
        let calendar = Calendar.current
        var minutes: [String: ZoneWeek] = [:]
        for a in activities where a.hrZones.count == 5 {
            let start = calendar.dateInterval(of: .weekOfYear, for: a.start)?.start ?? a.start
            for (zone, seconds) in a.hrZones.enumerated() {
                let id = "\(start.timeIntervalSince1970)-\(zone)"
                minutes[id] = ZoneWeek(id: id, start: start, zone: zone, minutes: (minutes[id]?.minutes ?? 0) + seconds / 60)
            }
        }
        let rows = minutes.values.sorted { $0.start < $1.start }
        let load = weekly(activities, value: { $0.trainingLoad ?? 0 }, group: { _ in "Load" })
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 20) {
                zoneChart(rows, zoneNames, zoneColors)
                loadChart(load).frame(width: 360)
            }
            VStack(alignment: .leading, spacing: 28) {
                zoneChart(rows, zoneNames, zoneColors)
                loadChart(load)
            }
        }
    }

    private func zoneChart(_ rows: [ZoneWeek], _ zoneNames: [String], _ zoneColors: [Color]) -> some View {
            ChartCard(title: "Time in heart rate zones", subtitle: "minutes per week") {
                Chart(rows) { row in
                    BarMark(x: .value("Week", row.start, unit: .weekOfYear), y: .value("Minutes", row.minutes))
                        .foregroundStyle(by: .value("Zone", zoneNames[row.zone]))
                }
                .chartForegroundStyleScale(domain: zoneNames, range: zoneColors)
            }
    }

    private func loadChart(_ load: [WeekSport]) -> some View {
            ChartCard(title: "Training load", subtitle: "Garmin's load, per week") {
                Chart(load) { week in
                    BarMark(x: .value("Week", week.start, unit: .weekOfYear), y: .value("Load", week.value))
                        .foregroundStyle(.teal.gradient)
                }
            }
    }

    // MARK: Sport mix

    private func sportMix(_ activities: [Activity]) -> some View {
        let byTime = Dictionary(grouping: activities, by: \.sport).mapValues { $0.reduce(0) { $0 + $1.activeSeconds } }
            .sorted { $0.value > $1.value }
        let total = max(byTime.reduce(0) { $0 + $1.value }, 1)
        return ChartCard(title: "Where your time went", subtitle: "\(Int(total / 3600)) h") {
            HStack(spacing: 14) {
                Chart(byTime, id: \.key) { sport, seconds in
                    SectorMark(angle: .value("Time", seconds), innerRadius: .ratio(0.6), angularInset: 1.5)
                        .foregroundStyle(sport.color)
                }
                .frame(width: 130)
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(byTime.prefix(6), id: \.key) { sport, seconds in
                        HStack(spacing: 6) {
                            Circle().fill(sport.color).frame(width: 8, height: 8)
                            Text(sport.label).font(.caption).lineLimit(1)
                            Spacer()
                            Text("\(Int(seconds / total * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: Wellness

    // MARK: Aerobic form

    private func aerobicForm(since: Date) -> some View {
        let resting = allDays.compactMap(\.restingHR).sorted()
        let form = AerobicForm(runs: allActivities, resting: resting.isEmpty ? nil : Double(resting[resting.count / 2]))
        let shown = form.points.filter { $0.date >= since }
        let yearAgo = Calendar.current.date(byAdding: .year, value: -1, to: Date())!
        let compareDate = range == .all ? yearAgo : since
        let change: Double? = form.now.flatMap { now in form.trend(at: compareDate).map { now - $0 } }

        return Panel(title: "Aerobic form", subtitle: "Your running pace at \(form.reference) bpm, from \(form.points.count) outdoor runs") {
            if let now = form.now {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(format.pace(secondsPerKm: now))
                        .font(.system(.largeTitle, design: .rounded).weight(.semibold)).monospacedDigit()
                    Text("at \(form.reference) bpm, last 30 days").foregroundStyle(.secondary)
                    }
                    if let change, abs(change) >= 1 {
                        let faster = change < 0
                        let seconds = Int(abs(format.imperial ? change * 1.609344 : change).rounded())
                        Label("\(seconds) s/\(format.distanceUnit) \(faster ? "faster" : "slower") than \(range == .all || range == .year ? "a year ago" : "\(range.rawValue) ago")",
                              systemImage: faster ? "arrow.down.right" : "arrow.up.right")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(faster ? .green : .orange)
                    }
                }
                Chart {
                    ForEach(shown) { p in
                        PointMark(x: .value("Date", p.date), y: .value("Pace", -p.pace))
                            .symbolSize(12)
                            .foregroundStyle(Sport.run.color.opacity(0.3))
                    }
                    ForEach(shown) { p in
                        LineMark(x: .value("Date", p.date), y: .value("Pace", -p.trend))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(Sport.run.color)
                            .lineStyle(StrokeStyle(lineWidth: 2.5))
                    }
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel { if let v = value.as(Double.self) { Text(format.pace(secondsPerKm: -v)) } }
                    }
                }
                .frame(height: 200)
                .drawingGroup()
                Text("Each run's pace is scaled to \(form.reference) bpm using your resting heart rate (\(Int(form.resting))), with every metre climbed counted as 6 m on the flat. Higher on the chart is faster: you're getting fitter when the line goes up.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Needs outdoor runs of 3 km or more with heart rate.").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Records

    private func records(_ activities: [Activity]) -> some View {
        let runs = activities.filter { $0.sport == .run }
        let rides = activities.filter { $0.sport == .ride && !Sport.isIndoor($0.typeKey) }
        let swims = activities.filter { $0.sport == .swim }
        let fastest = runs.filter { $0.distance >= 5000 && !Sport.isIndoor($0.typeKey) }.min { ($0.paceSecondsPerKm ?? .infinity) < ($1.paceSecondsPerKm ?? .infinity) }
        let items: [(String, String, Activity?)] = [
            ("Longest run", runs.max { $0.distance < $1.distance }.map { format.distance($0.distance) } ?? "–", runs.max { $0.distance < $1.distance }),
            ("Fastest run (5 km+)", fastest?.paceSecondsPerKm.map { format.pace(secondsPerKm: $0) } ?? "–", fastest),
            ("Longest ride", rides.max { $0.distance < $1.distance }.map { format.distance($0.distance) } ?? "–", rides.max { $0.distance < $1.distance }),
            ("Longest swim", swims.max { $0.distance < $1.distance }.map { "\(Int($0.distance)) m" } ?? "–", swims.max { $0.distance < $1.distance }),
            ("Biggest climb", activities.filter { !Sport.isIndoor($0.typeKey) }.max { $0.elevationGain < $1.elevationGain }.map { format.elevation($0.elevationGain) } ?? "–",
             activities.filter { !Sport.isIndoor($0.typeKey) }.max { $0.elevationGain < $1.elevationGain }),
            ("Longest session", activities.max { $0.activeSeconds < $1.activeSeconds }.map { Format.duration($0.activeSeconds) } ?? "–",
             activities.max { $0.activeSeconds < $1.activeSeconds }),
            ("Hardest effort", activities.max { ($0.trainingLoad ?? 0) < ($1.trainingLoad ?? 0) }.flatMap { $0.trainingLoad.map { "Load \(Int($0))" } } ?? "–",
             activities.max { ($0.trainingLoad ?? 0) < ($1.trainingLoad ?? 0) }),
        ]
        return Panel(title: "Records", subtitle: range == .all ? "All time" : "In \(period)") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                ForEach(items, id: \.0) { title, value, activity in
                    NavigationLink(value: activity?.garminId ?? 0) {
                        RecordCell(title: title, value: value, activity: activity)
                    }
                    .buttonStyle(.plain)
                    .disabled(activity == nil)
                }
            }
        }
    }

    private func average(_ values: [Int]) -> Int? {
        values.isEmpty ? nil : values.reduce(0, +) / values.count
    }
}

/// One record: what, the number, and which activity it was. Hovering shows it opens.
struct RecordCell: View {
    let title: String
    let value: String
    let activity: Activity?
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "trophy").foregroundStyle(.orange).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).foregroundStyle(.secondary)
                Text(value).font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
                if let activity {
                    Text("\(activity.name.isEmpty ? Format.title(activity.typeKey) : activity.name) · \(activity.start.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if activity != nil {
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary).opacity(hovering ? 1 : 0)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(hovering ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 && activity != nil }
        .accessibilityElement(children: .combine)
    }
}

/// The last 53 weeks as a grid of days, darker the more you moved, with streaks above it.
struct ActivityCalendar: View {
    let activities: [Activity]
    @AppStorage("calendarRunsOnly") private var runsOnly = true
    @State private var width: CGFloat = 500

    private static let gap: CGFloat = 3
    private static let labelWidth: CGFloat = 30

    var body: some View {
        let calendar = Calendar.current
        let shown = runsOnly ? activities.filter { $0.sport == .run } : activities
        let noun = runsOnly ? "runs" : "activities"
        let today = calendar.startOfDay(for: Date())
        let firstWeek = calendar.dateInterval(of: .weekOfYear, for: calendar.date(byAdding: .weekOfYear, value: -52, to: today)!)!.start
        var minutes: [Date: Double] = [:]
        for a in shown where a.start >= firstWeek {
            minutes[calendar.startOfDay(for: a.start), default: 0] += a.activeSeconds / 60
        }
        let weeks = (0..<53).map { calendar.date(byAdding: .weekOfYear, value: $0, to: firstWeek)! }
        let streaks = Streaks(dates: shown.map(\.start))
        let cell = max(6, min(22, ((width - Self.labelWidth - 52 * Self.gap) / 53).rounded(.down)))

        return Panel(title: "Last 12 months", subtitle: "\(minutes.count) active days") {
            Picker("Show", selection: $runsOnly) {
                Text("Running").tag(true)
                Text("Everything").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .help("Count runs only, or every activity")
        } content: {
            MetricRow(metrics: [
                Metric(label: "Streak", symbol: "flame", tint: .orange,
                       value: "\(streaks.currentDays) \(streaks.currentDays == 1 ? "day" : "days")",
                       note: "Longest \(streaks.longestDays) days" + (streaks.longestDaysEnd.map { ", to \($0.formatted(.dateTime.day().month(.abbreviated).year()))" } ?? "")),
                Metric(label: "Weeks with \(streaks.perWeek)+ \(noun)", symbol: "calendar", tint: .green,
                       value: "\(streaks.currentWeeks) in a row", note: "Longest \(streaks.longestWeeks) weeks"),
                Metric(label: "This week", symbol: "figure.run", tint: Sport.run.color,
                       value: "\(streaks.thisWeek) \(streaks.thisWeek == 1 ? String(noun.dropLast()) : noun)",
                       note: streaks.thisWeek >= streaks.perWeek ? "Streak kept for this week" : "\(streaks.perWeek - streaks.thisWeek) more to keep the streak"),
                Metric(label: "Busiest week", symbol: "star", tint: .yellow, value: "\(streaks.bestWeek) \(noun)"),
            ])
            Divider()
            // Measures the width on offer with a flexible empty view; measuring the grid itself fed back into its
            // own size and grew past the window.
            Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            VStack(alignment: .leading, spacing: 4) {
                // Month names over the week each month starts in.
                ZStack(alignment: .topLeading) {
                    ForEach(weeks.indices, id: \.self) { i in
                        let week = weeks[i]
                        let monthStart = calendar.dateInterval(of: .month, for: calendar.date(byAdding: .day, value: 6, to: week)!)!.start
                        if i == 0 || (monthStart >= week && monthStart <= calendar.date(byAdding: .day, value: 6, to: week)!), i < 51 {
                            Text(monthStart.formatted(.dateTime.month(.abbreviated)))
                                .font(.caption2).foregroundStyle(.secondary)
                                .offset(x: Self.labelWidth + CGFloat(i) * (cell + Self.gap))
                        }
                    }
                }
                .frame(height: 13, alignment: .topLeading)
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: Self.gap) {
                        ForEach(0..<7, id: \.self) { row in
                            Text(row % 2 == 0 ? calendar.shortWeekdaySymbols[(row + calendar.firstWeekday - 1) % 7] : "")
                                .font(.caption2).foregroundStyle(.secondary)
                                .frame(height: cell)
                        }
                    }
                    .frame(width: Self.labelWidth, alignment: .leading)
                    HStack(alignment: .top, spacing: Self.gap) {
                        ForEach(weeks, id: \.self) { week in
                            VStack(spacing: Self.gap) {
                                ForEach(0..<7, id: \.self) { offset in
                                    let day = calendar.date(byAdding: .day, value: offset, to: week)!
                                    let value = minutes[day] ?? 0
                                    RoundedRectangle(cornerRadius: cell / 4, style: .continuous)
                                        .fill(day > today ? Color.clear : Self.color(for: value))
                                        .frame(width: cell, height: cell)
                                        .help(day > today ? "" : "\(day.formatted(date: .abbreviated, time: .omitted)): \(Int(value)) min")
                                }
                            }
                        }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(minutes.count) active days in the last 12 months")
                HStack(spacing: 4) {
                    Spacer()
                    Text("Less").font(.caption2).foregroundStyle(.secondary)
                    ForEach([0.0, 20, 45, 75, 120], id: \.self) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Self.color(for: $0)).frame(width: 10, height: 10)
                    }
                    Text("More").font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
            // The grid mustn't hold the box open: it sizes itself from the width measured above, and if it also
            // set that width the two would never shrink (the page ran wider than the window).
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The system green in four steps, so it follows light and dark appearance and increased contrast.
    private static func color(for minutes: Double) -> Color {
        switch minutes {
        case 0: Color.primary.opacity(0.07)
        case ..<30: Color.green.opacity(0.3)
        case ..<60: Color.green.opacity(0.55)
        case ..<100: Color.green.opacity(0.8)
        default: Color.green
        }
    }
}

