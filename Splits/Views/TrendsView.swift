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
        let activities = allActivities.filter { $0.start >= since && $0.distance > 0 }
        let weeks = weekly(activities)

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Picker("Range", selection: $range) {
                    ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)

                ChartCard(title: "Distance per week", subtitle: "\(format.distance(activities.reduce(0) { $0 + $1.distance }, decimals: 0)) in this period") {
                    Chart(weeks, id: \.id) { week in
                        BarMark(x: .value("Week", week.start, unit: .weekOfYear),
                                y: .value(format.distanceUnit, format.distanceValue(week.metres)))
                            .foregroundStyle(by: .value("Sport", week.sport.label))
                    }
                    .chartYAxisLabel(format.distanceUnit)
                }

                ChartCard(title: "Overnight HRV", subtitle: "Shaded: your balanced range") {
                    Chart {
                        ForEach(days.filter { $0.hrvBalancedLow != nil && $0.hrvBalancedHigh != nil }, id: \.date) { d in
                            AreaMark(x: .value("Day", d.day), yStart: .value("Low", d.hrvBalancedLow!), yEnd: .value("High", d.hrvBalancedHigh!))
                                .foregroundStyle(.teal.opacity(0.15))
                        }
                        ForEach(days.filter { $0.hrvLastNight != nil }, id: \.date) { d in
                            LineMark(x: .value("Day", d.day), y: .value("HRV", d.hrvLastNight!))
                                .foregroundStyle(.teal)
                        }
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .chartYAxisLabel("ms")
                }

                ChartCard(title: "Sleep", subtitle: average(days.compactMap { $0.sleepSeconds }).map { "Average \(Format.hoursMinutes($0))" } ?? "") {
                    Chart(days.filter { $0.sleepSeconds != nil }, id: \.date) { d in
                        BarMark(x: .value("Day", d.day, unit: .day), y: .value("Hours", Double(d.sleepSeconds!) / 3600))
                            .foregroundStyle(.indigo.gradient)
                    }
                    .chartYAxisLabel("hours")
                }

                ChartCard(title: "Resting heart rate", subtitle: average(days.compactMap { $0.restingHR }).map { "Average \($0) bpm" } ?? "") {
                    Chart(days.filter { $0.restingHR != nil }, id: \.date) { d in
                        LineMark(x: .value("Day", d.day), y: .value("bpm", d.restingHR!))
                            .foregroundStyle(.red)
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .chartYAxisLabel("bpm")
                }

                if range == .all || allDays.first.map({ $0.day > since }) == true {
                    Text("Sleep, HRV and heart rate go back a year, from the first sync.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
        .navigationTitle("Trends")
    }

    private struct Week { let id: String; let start: Date; let sport: Sport; let metres: Double }

    /// Distance per week and sport. Only the main sports, so the chart stays readable.
    private func weekly(_ activities: [Activity]) -> [Week] {
        let calendar = Calendar.current
        let main: Set<Sport> = [.run, .ride, .swim, .walk, .hike]
        var totals: [String: Week] = [:]
        for a in activities where main.contains(a.sport) {
            let start = calendar.dateInterval(of: .weekOfYear, for: a.start)?.start ?? a.start
            let id = "\(start.timeIntervalSince1970)-\(a.sport.rawValue)"
            totals[id] = Week(id: id, start: start, sport: a.sport, metres: (totals[id]?.metres ?? 0) + a.distance)
        }
        return totals.values.sorted { $0.start < $1.start }
    }

    private func average(_ values: [Int]) -> Int? {
        values.isEmpty ? nil : values.reduce(0, +) / values.count
    }
}

struct ChartCard<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            content.frame(height: 200)
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
    }
}
