import Charts
import SwiftData
import SwiftUI

/// One table row: plain values worked out once, so scrolling and selecting don't touch SwiftData objects.
struct ActivityTableRow: Identifiable {
    let id: Int64
    let start: Date
    let date: String
    let time: String
    let name: String
    let symbol: String
    let sport: Sport
    let typeKey: String
    let distance: Double
    let distanceText: String
    let seconds: Double
    let timeText: String
    let pace: String
    let elevation: Double
    let elevationText: String
    let heartRate: Double
    let heartRateText: String

    init(_ a: Activity, format: Format) {
        id = a.garminId
        start = a.start
        date = a.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year())
        time = a.start.formatted(date: .omitted, time: .shortened)
        name = a.name.isEmpty ? Format.title(a.typeKey) : a.name
        sport = a.sport
        symbol = a.sport.symbol
        typeKey = a.typeKey
        distance = a.hasDistance ? a.distance : 0
        // Padel or the gym record a few hundred metres of arm movement: not a distance worth showing.
        distanceText = a.hasDistance ? format.distance(a.distance) : "–"
        seconds = a.activeSeconds
        timeText = Format.duration(a.activeSeconds)
        switch a.sport {
        case .run, .walk, .hike:
            pace = a.paceSecondsPerKm.map { format.pace(secondsPerKm: $0) } ?? "–"
        case .swim where a.distance > 0:
            let per100 = Int(a.movingDuration / (a.distance / 100))
            pace = String(format: "%d:%02d /100m", per100 / 60, per100 % 60)
        default:
            pace = a.hasDistance ? a.averageSpeed.map { $0 > 0 ? format.speed(metresPerSecond: $0) : "–" } ?? "–" : "–"
        }
        let outdoorClimb = a.elevationGain > 0 && !Sport.isIndoor(a.typeKey)
        elevation = outdoorClimb ? a.elevationGain : 0
        elevationText = outdoorClimb ? format.elevation(a.elevationGain) : "–"
        heartRate = a.averageHR ?? 0
        heartRateText = a.averageHR.map { "\(Int($0))" } ?? "–"
    }
}

struct ActivitiesView: View {
    @Query(sort: \Activity.start, order: .reverse) private var activities: [Activity]
    @Environment(\.format) private var format
    @State private var search = ""
    @State private var sport: Sport?
    @State private var selection: ActivityTableRow.ID?
    @State private var path: [Int64] = []
    @State private var sortOrder = [KeyPathComparator(\ActivityTableRow.start, order: .reverse)]
    /// Every activity as a row, rebuilt only when the activities change.
    @State private var allRows: [ActivityTableRow] = []
    /// The rows on screen: filtered and sorted only when the search, sport or sort order changes.
    @State private var rows: [ActivityTableRow] = []
    @State private var summary = ""

    var body: some View {
        NavigationStack(path: $path) {
            table
                .navigationDestination(for: Int64.self) { id in
                    if let activity = activities.first(where: { $0.garminId == id }) { ActivityPage(activity: activity) }
                }
        }
        .task(id: "\(activities.count)-\(activities.first?.garminId ?? 0)-\(format.imperial)") {
            allRows = activities.map { ActivityTableRow($0, format: format) }
            refilter()
        }
        .onChange(of: search) { refilter() }
        #if DEBUG
        // `-openNewest YES`: opens the newest activity, for screenshots.
        .onAppear {
            if UserDefaults.standard.bool(forKey: "openNewest"), let first = activities.first { path = [first.garminId] }
            // `-openActivity 1234567`: that activity, for screenshots.
            if let id = Int64(UserDefaults.standard.string(forKey: "openActivity") ?? "") { path = [id] }
        }
        #endif
        .onChange(of: sport) { refilter() }
        .onChange(of: sortOrder) { refilter() }
    }

    private func refilter() {
        let needle = search.lowercased()
        rows = allRows
            .filter { sport == nil || $0.sport == sport }
            .filter { needle.isEmpty || $0.name.lowercased().contains(needle) || $0.typeKey.contains(needle) }
            .sorted(using: sortOrder)
        let distance = rows.reduce(0) { $0 + $1.distance }
        let time = rows.reduce(0) { $0 + $1.seconds }
        summary = "\(rows.count) activities · \(format.distance(distance, decimals: 0)) · \(Int(time / 3600)) h"
    }

    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Date", value: \.start) { r in
                HStack(spacing: 6) {
                    Text(r.date)
                    Text(r.time).foregroundStyle(.secondary)
                }
                .monospacedDigit()
            }
            .width(min: 150, ideal: 190)
            TableColumn("Activity", value: \.name) { r in Label(r.name, systemImage: r.symbol) }
                .width(min: 180, ideal: 260)
            TableColumn("Distance", value: \.distance) { r in Text(r.distanceText).monospacedDigit() }
                .width(80)
            TableColumn("Time", value: \.seconds) { r in Text(r.timeText).monospacedDigit() }
                .width(70)
            TableColumn("Pace") { r in Text(r.pace).monospacedDigit() }
                .width(85)
            TableColumn("Elevation", value: \.elevation) { r in Text(r.elevationText).monospacedDigit() }
                .width(70)
            TableColumn("Avg HR", value: \.heartRate) { r in Text(r.heartRateText).monospacedDigit() }
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
        .contextMenu(forSelectionType: ActivityTableRow.ID.self) { _ in } primaryAction: { ids in
            if let id = ids.first { path.append(id) }
        }
        .navigationTitle("Activities")
        .navigationSubtitle(summary)
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
            Text(Format.duration(activity.activeSeconds)).monospacedDigit().foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
        }
        .padding(.vertical, 8)
    }
}
