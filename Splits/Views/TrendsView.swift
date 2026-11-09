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
        let seconds = activities.reduce(0) { $0 + $1.movingDuration }
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
        let byTime = Dictionary(grouping: activities, by: \.sport).mapValues { $0.reduce(0) { $0 + $1.movingDuration } }
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
            ("Longest session", activities.max { $0.movingDuration < $1.movingDuration }.map { Format.duration($0.movingDuration) } ?? "–",
             activities.max { $0.movingDuration < $1.movingDuration }),
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

/// The last 53 weeks as a grid of days, darker the more you moved. Like a GitHub contribution graph.
struct ActivityCalendar: View {
    let activities: [Activity]

    var body: some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let firstWeek = calendar.dateInterval(of: .weekOfYear, for: calendar.date(byAdding: .weekOfYear, value: -52, to: today)!)!.start
        var minutes: [Date: Double] = [:]
        for a in activities where a.start >= firstWeek {
            minutes[calendar.startOfDay(for: a.start), default: 0] += a.movingDuration / 60
        }
        let activeDays = minutes.count
        let weeks = (0..<53).map { calendar.date(byAdding: .weekOfYear, value: $0, to: firstWeek)! }

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your last 12 months").font(.headline)
                Spacer()
                Text("\(activeDays) active days").font(.caption).foregroundStyle(.secondary)
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
