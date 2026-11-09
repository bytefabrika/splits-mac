import Charts
import SwiftData
import SwiftUI

struct ActivitiesView: View {
    @Query(sort: \Activity.start, order: .reverse) private var activities: [Activity]
    @Environment(\.format) private var format
    @State private var search = ""
    @State private var sport: Sport?
    @State private var selection: Activity.ID?
    @State private var sortOrder = [KeyPathComparator(\Activity.start, order: .reverse)]

    private var shown: [Activity] {
        activities
            .filter { sport == nil || $0.sport == sport }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.typeKey.contains(search.lowercased()) }
            .sorted(using: sortOrder)
    }

    var body: some View {
        let shown = shown
        Table(shown, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Date", value: \.start) { a in
                Text(a.start, format: .dateTime.year().month(.abbreviated).day().hour().minute())
            }
            .width(min: 130, ideal: 150)
            TableColumn("Activity", value: \.name) { a in
                Label(a.name.isEmpty ? Format.title(a.typeKey) : a.name, systemImage: a.sport.symbol)
            }
            .width(min: 180, ideal: 260)
            TableColumn("Distance", value: \.distance) { a in
                Text(a.distance > 0 ? format.distance(a.distance) : "–").monospacedDigit()
            }
            .width(80)
            TableColumn("Time", value: \.movingDuration) { a in Text(Format.duration(a.movingDuration)).monospacedDigit() }
                .width(70)
            TableColumn("Pace") { a in Text(paceOrSpeed(a)).monospacedDigit() }
                .width(85)
            TableColumn("Elevation", value: \.elevationGain) { a in
                Text(a.elevationGain > 0 && !Sport.isIndoor(a.typeKey) ? format.elevation(a.elevationGain) : "–").monospacedDigit()
            }
            .width(70)
            TableColumn("Avg HR") { a in Text(a.averageHR.map { "\(Int($0))" } ?? "–").monospacedDigit() }
                .width(55)
        }
        .searchable(text: $search, prompt: "Search activities")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Sport", selection: $sport) {
                    Text("All sports").tag(Sport?.none)
                    ForEach(Sport.allCases) { s in Label(s.label, systemImage: s.symbol).tag(Sport?.some(s)) }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
        }
        .inspector(isPresented: .constant(selection != nil)) {
            if let selected = shown.first(where: { $0.id == selection }) ?? activities.first(where: { $0.id == selection }) {
                ActivityDetail(activity: selected)
                    .inspectorColumnWidth(min: 280, ideal: 320)
            }
        }
        .navigationTitle("Activities")
        .navigationSubtitle(summary(shown))
    }

    private func paceOrSpeed(_ a: Activity) -> String {
        switch a.sport {
        case .run, .walk, .hike:
            return a.paceSecondsPerKm.map { format.pace(secondsPerKm: $0) } ?? "–"
        case .swim:
            guard a.distance > 0 else { return "–" }
            return String(format: "%d:%02d /100m", Int(a.movingDuration / (a.distance / 100)) / 60,
                          Int(a.movingDuration / (a.distance / 100)) % 60)
        default:
            return a.averageSpeed.map { $0 > 0 ? format.speed(metresPerSecond: $0) : "–" } ?? "–"
        }
    }

    private func summary(_ list: [Activity]) -> String {
        let distance = list.reduce(0) { $0 + $1.distance }
        let time = list.reduce(0) { $0 + $1.movingDuration }
        return "\(list.count) activities · \(format.distance(distance, decimals: 0)) · \(Int(time / 3600)) h"
    }
}

struct ActivityRow: View {
    let activity: Activity
    @Environment(\.format) private var format

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: activity.sport.symbol).frame(width: 24).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(activity.name.isEmpty ? Format.title(activity.typeKey) : activity.name).lineLimit(1)
                Text(activity.start, format: .dateTime.weekday(.abbreviated).day().month().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if activity.distance > 0 { Text(format.distance(activity.distance)).monospacedDigit() }
            Text(Format.duration(activity.movingDuration)).monospacedDigit().foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
        }
        .padding(.vertical, 8)
    }
}

struct ActivityDetail: View {
    let activity: Activity
    @Environment(\.format) private var format

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label(activity.name.isEmpty ? Format.title(activity.typeKey) : activity.name, systemImage: activity.sport.symbol)
                    .font(.title3.bold())
                Text(activity.start, format: .dateTime.weekday(.wide).day().month(.wide).year().hour().minute())
                    .foregroundStyle(.secondary)

                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                    row("Distance", activity.distance > 0 ? format.distance(activity.distance) : nil)
                    row("Moving time", Format.duration(activity.movingDuration))
                    row("Elapsed", Format.duration(activity.duration))
                    row("Pace", activity.sport == .run || activity.sport == .walk
                        ? activity.paceSecondsPerKm.map { format.pace(secondsPerKm: $0) } : nil)
                    row("Avg speed", activity.averageSpeed.map { format.speed(metresPerSecond: $0) })
                    row("Elevation gain", activity.elevationGain > 0 ? format.elevation(activity.elevationGain) : nil)
                    row("Avg / max HR", activity.averageHR.map { "\(Int($0)) / \(Int(activity.maxHR ?? 0)) bpm" })
                    row("Avg power", activity.averagePower.map { "\(Int($0)) W" })
                    row("Cadence", activity.cadence.map { "\(Int($0)) spm" })
                    row("Calories", activity.calories.map { "\(Int($0)) kcal" })
                    row("Training effect", activity.aerobicEffect.map {
                        String(format: "%.1f aerobic · %.1f anaerobic", $0, activity.anaerobicEffect ?? 0)
                    })
                    row("Training load", activity.trainingLoad.map { "\(Int($0))" })
                    row("Steps", activity.steps.map { $0.formatted() })
                    row("Laps", activity.laps.map { "\($0)" })
                    row("Temperature", activity.minTemperature.map { "\(Int($0))–\(Int(activity.maxTemperature ?? $0)) °C" })
                }

                if activity.hrZones.count == 5, activity.hrZones.contains(where: { $0 > 0 }) {
                    Text("Time in heart rate zones").font(.headline)
                    Chart(Array(activity.hrZones.enumerated()), id: \.offset) { zone, seconds in
                        BarMark(x: .value("Minutes", seconds / 60), y: .value("Zone", "Zone \(zone + 1)"))
                            .foregroundStyle([Color.gray, .blue, .green, .orange, .red][zone])
                            .annotation(position: .trailing) {
                                Text(Format.duration(seconds)).font(.caption2).foregroundStyle(.secondary)
                            }
                    }
                    .chartXAxis(.hidden)
                    .frame(height: 140)
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        if let value {
            GridRow {
                Text(label).foregroundStyle(.secondary)
                Text(value).monospacedDigit()
            }
        }
    }
}
