import Charts
import SwiftData
import SwiftUI

struct ActivitiesView: View {
    @Query(sort: \Activity.start, order: .reverse) private var activities: [Activity]
    @Environment(\.format) private var format
    @State private var search = ""
    @State private var sport: Sport?
    @State private var selection: Activity.ID?
    @State private var path: [Int64] = []
    @State private var sortOrder = [KeyPathComparator(\Activity.start, order: .reverse)]

    private var shown: [Activity] {
        activities
            .filter { sport == nil || $0.sport == sport }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.typeKey.contains(search.lowercased()) }
            .sorted(using: sortOrder)
    }

    var body: some View {
        NavigationStack(path: $path) {
            table
                .navigationDestination(for: Int64.self) { id in
                    if let activity = activities.first(where: { $0.garminId == id }) { ActivityPage(activity: activity) }
                }
        }
    }

    private var table: some View {
        let shown = shown
        return Table(shown, selection: $selection, sortOrder: $sortOrder) {
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
        // Double-click or Return opens the activity.
        .contextMenu(forSelectionType: Activity.ID.self) { _ in } primaryAction: { ids in
            if let id = ids.first, let activity = shown.first(where: { $0.id == id }) { path.append(activity.garminId) }
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
