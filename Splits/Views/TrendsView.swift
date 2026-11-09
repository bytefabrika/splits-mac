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

    private var since: Date {
        range.days.map { Calendar.current.date(byAdding: .day, value: -$0, to: Date())! } ?? .distantPast
    }

    var body: some View {
        let since = since
        let days = allDays.filter { $0.day >= since }
        let activities = allActivities.filter { $0.start >= since }

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Picker("Range", selection: $range) {
                        ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 360)

                    highlights(activities, days)
                    ActivityCalendar(activities: allActivities)
                    yearOverYear

                    HStack(alignment: .top, spacing: 18) {
                        weeklyDistance(activities)
                        sportMix(activities).frame(width: 320)
                    }
                    weeklyLoad(activities)
                    aerobicForm(since: since)
                    sleepStages(days)
                    HStack(alignment: .top, spacing: 18) {
                        hrv(days)
                        restingHR(days)
                    }
                    records(activities)

                    if allDays.first.map({ $0.day > since }) == true {
                        Text("Sleep, HRV and heart rate go back a year from the first sync.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(24)
                // Take hits everywhere, so the scroll wheel works over empty space too.
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .navigationTitle("Trends")
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
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            BigStat(label: "Activities", value: activities.count.formatted(), tint: Sport.run.color)
            BigStat(label: "Distance", value: format.distance(distance, decimals: 0), tint: Sport.ride.color)
            BigStat(label: "Time moving", value: "\(Int(seconds / 3600)) h", tint: Sport.swim.color)
            BigStat(label: "Climbed", value: format.elevation(climb), tint: Sport.hike.color)
            if let sleep { BigStat(label: "Avg sleep", value: Format.hoursMinutes(sleep), tint: .indigo) }
            if let hrv { BigStat(label: "Avg HRV", value: "\(hrv) ms", tint: .teal) }
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
        return HStack(alignment: .top, spacing: 18) {
            ChartCard(title: "Time in heart rate zones", subtitle: "minutes per week") {
                Chart(rows) { row in
                    BarMark(x: .value("Week", row.start, unit: .weekOfYear), y: .value("Minutes", row.minutes))
                        .foregroundStyle(by: .value("Zone", zoneNames[row.zone]))
                }
                .chartForegroundStyleScale(domain: zoneNames, range: zoneColors)
            }
            ChartCard(title: "Training load", subtitle: "Garmin's load, per week") {
                Chart(load) { week in
                    BarMark(x: .value("Week", week.start, unit: .weekOfYear), y: .value("Load", week.value))
                        .foregroundStyle(.teal.gradient)
                }
            }
            .frame(width: 360)
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

    private func sleepStages(_ days: [Day]) -> some View {
        let nights = days.filter { $0.sleepSeconds != nil }
        let stages: [(String, Color, KeyPath<Day, Int?>)] = [
            ("Deep", .indigo, \.deepSeconds), ("Light", .blue, \.lightSeconds), ("REM", .purple, \.remSeconds), ("Awake", .pink, \.awakeSeconds),
        ]
        return ChartCard(title: "Sleep stages", subtitle: average(nights.compactMap(\.sleepSeconds)).map { "Average \(Format.hoursMinutes($0)) a night" } ?? "") {
            Chart {
                ForEach(nights, id: \.date) { night in
                    ForEach(stages, id: \.0) { name, _, path in
                        BarMark(x: .value("Night", night.day, unit: .day), y: .value("Hours", Double(night[keyPath: path] ?? 0) / 3600))
                            .foregroundStyle(by: .value("Stage", name))
                    }
                }
                if let avg = average(nights.compactMap(\.sleepSeconds)) {
                    RuleMark(y: .value("Average", Double(avg) / 3600))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(.secondary)
                }
            }
            .chartForegroundStyleScale(domain: stages.map(\.0), range: stages.map(\.1))
            .chartYAxisLabel("hours")
        }
    }

    private func hrv(_ days: [Day]) -> some View {
        ChartCard(title: "Overnight HRV", subtitle: "Shaded: your balanced range") {
            Chart {
                ForEach(days.filter { $0.hrvBalancedLow != nil && $0.hrvBalancedHigh != nil }, id: \.date) { d in
                    AreaMark(x: .value("Day", d.day), yStart: .value("Low", d.hrvBalancedLow!), yEnd: .value("High", d.hrvBalancedHigh!))
                        .foregroundStyle(.teal.opacity(0.15))
                }
                ForEach(days.filter { $0.hrvLastNight != nil }, id: \.date) { d in
                    LineMark(x: .value("Day", d.day), y: .value("HRV", d.hrvLastNight!), series: .value("s", "night"))
                        .foregroundStyle(.teal.opacity(0.45))
                }
                ForEach(days.filter { $0.hrvWeekly != nil }, id: \.date) { d in
                    LineMark(x: .value("Day", d.day), y: .value("HRV", d.hrvWeekly!), series: .value("s", "week"))
                        .foregroundStyle(.teal)
                        .lineStyle(StrokeStyle(lineWidth: 2.5))
                }
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartYAxisLabel("ms")
        }
    }

    private func restingHR(_ days: [Day]) -> some View {
        ChartCard(title: "Resting heart rate", subtitle: average(days.compactMap(\.restingHR)).map { "Average \($0) bpm" } ?? "") {
            Chart(days.filter { $0.restingHR != nil }, id: \.date) { d in
                LineMark(x: .value("Day", d.day), y: .value("bpm", d.restingHR!))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(.red)
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartYAxisLabel("bpm")
        }
    }

    // MARK: Aerobic form

    private func aerobicForm(since: Date) -> some View {
        let resting = allDays.compactMap(\.restingHR).sorted()
        let form = AerobicForm(runs: allActivities, resting: resting.isEmpty ? nil : Double(resting[resting.count / 2]))
        let shown = form.points.filter { $0.date >= since }
        let yearAgo = Calendar.current.date(byAdding: .year, value: -1, to: Date())!
        let compareDate = range == .all ? yearAgo : since
        let change: Double? = form.now.flatMap { now in form.trend(at: compareDate).map { now - $0 } }

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label("Aerobic form", systemImage: "heart.circle.fill").font(.headline).foregroundStyle(Sport.run.color)
                Spacer()
                Text("Your pace at \(form.reference) bpm, from \(form.points.count) outdoor runs")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let now = form.now {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(format.pace(secondsPerKm: now))
                        .font(.system(size: 34, weight: .heavy, design: .rounded)).monospacedDigit()
                    Text("at \(form.reference) bpm, last 30 days").foregroundStyle(.secondary)
                    if let change, abs(change) >= 1 {
                        let faster = change < 0
                        let seconds = Int(abs(format.imperial ? change * 1.609344 : change).rounded())
                        Label("\(seconds) s/\(format.distanceUnit) \(faster ? "faster" : "slower") than \(range == .all ? "a year ago" : "\(range.rawValue) ago")",
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
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
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
        return VStack(alignment: .leading, spacing: 10) {
            Label("Records in this period", systemImage: "trophy.fill").font(.headline).foregroundStyle(.orange)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], spacing: 12) {
                ForEach(items, id: \.0) { title, value, activity in
                    NavigationLink(value: activity?.garminId ?? 0) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(title.uppercased()).font(.caption2.weight(.bold)).tracking(0.8).foregroundStyle(.secondary)
                            Text(value).font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
                            if let activity {
                                Text("\(activity.name.isEmpty ? Format.title(activity.typeKey) : activity.name) · \(activity.start.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        .contentShape(Rectangle())
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

struct StreakStat: View {
    let symbol: String
    let tint: Color
    let value: String
    let label: String
    let note: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.title2).foregroundStyle(tint).frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(value).font(.system(size: 26, weight: .heavy, design: .rounded)).monospacedDigit()
                    Text(label).font(.callout.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                }
                Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// The last 53 weeks as a grid of days, darker the more you moved. Like a GitHub contribution graph.
struct ActivityCalendar: View {
    let activities: [Activity]
    @AppStorage("calendarRunsOnly") private var runsOnly = true

    var body: some View {
        let activities = runsOnly ? activities.filter { $0.sport == .run } : activities
        let noun = runsOnly ? "runs" : "activities"
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let firstWeek = calendar.dateInterval(of: .weekOfYear, for: calendar.date(byAdding: .weekOfYear, value: -52, to: today)!)!.start
        var minutes: [Date: Double] = [:]
        for a in activities where a.start >= firstWeek {
            minutes[calendar.startOfDay(for: a.start), default: 0] += a.activeSeconds / 60
        }
        let activeDays = minutes.count
        let weeks = (0..<53).map { calendar.date(byAdding: .weekOfYear, value: $0, to: firstWeek)! }
        let streaks = Streaks(dates: activities.map(\.start))

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your last 12 months").font(.headline)
                Picker("Show", selection: $runsOnly) {
                    Text("Running").tag(true)
                    Text("Everything").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(.leading, 8)
                Spacer()
                Text("\(activeDays) active days").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                StreakStat(symbol: "flame.fill", tint: .orange, value: "\(streaks.currentDays)",
                           label: streaks.currentDays == 1 ? "day in a row" : "days in a row",
                           note: "Longest \(streaks.longestDays)" + (streaks.longestDaysEnd.map { ", ended \($0.formatted(.dateTime.day().month(.abbreviated).year()))" } ?? ""))
                StreakStat(symbol: "calendar.badge.checkmark", tint: .green, value: "\(streaks.currentWeeks)",
                           label: streaks.currentWeeks == 1 ? "week with \(streaks.perWeek)+ \(noun)" : "weeks in a row with \(streaks.perWeek)+ \(noun)",
                           note: "Longest \(streaks.longestWeeks) weeks")
                StreakStat(symbol: "figure.run", tint: Sport.run.color, value: "\(streaks.thisWeek)",
                           label: "\(noun) this week",
                           note: streaks.thisWeek >= streaks.perWeek ? "Week done ✓" : "\(streaks.perWeek - streaks.thisWeek) more to keep the streak")
                StreakStat(symbol: "star.fill", tint: .yellow, value: "\(streaks.bestWeek)", label: "in your busiest week", note: "\(noun.capitalized) in one week")
            }
            GeometryReader { geo in
                let cell = min((geo.size.width - 52 * 3) / 53, 16)
                HStack(alignment: .top, spacing: 3) {
                    ForEach(weeks, id: \.self) { week in
                        VStack(spacing: 3) {
                            ForEach(0..<7, id: \.self) { offset in
                                let day = calendar.date(byAdding: .day, value: offset, to: week)!
                                let value = minutes[day] ?? 0
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(day > today ? Color.clear : color(for: value))
                                    .frame(width: cell, height: cell)
                                    .help(day > today ? "" : "\(day.formatted(date: .abbreviated, time: .omitted)): \(Int(value)) min")
                            }
                        }
                    }
                }
            }
            .frame(height: 7 * 16 + 6 * 3)
            HStack(spacing: 4) {
                Text("Less").font(.caption2).foregroundStyle(.secondary)
                ForEach([0.0, 20, 45, 75, 120], id: \.self) { RoundedRectangle(cornerRadius: 2).fill(color(for: $0)).frame(width: 10, height: 10) }
                Text("More").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
    }

    private func color(for minutes: Double) -> Color {
        switch minutes {
        case 0: Color.secondary.opacity(0.12)
        case ..<30: Sport.walk.color.opacity(0.35)
        case ..<60: Sport.walk.color.opacity(0.6)
        case ..<100: Sport.walk.color.opacity(0.85)
        default: Color(red: 0.12, green: 0.6, blue: 0.3)
        }
    }
}
