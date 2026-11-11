import SwiftUI

/// The coach's read on a page (Sleep, HRV): written by Apple's on-device model once for each new night,
/// kept until the next one. The facts, verdict and advice come from code; the model words them.
struct InsightCard: View {
    let title: String
    let symbol: String
    let colors: [Color]
    /// The newest night the facts cover: a new one writes a new take.
    let night: String
    let facts: () -> String
    @AppStorage private var savedFor: String
    @AppStorage private var savedText: String
    @State private var text = ""
    @State private var writing = false
    @State private var failure: String?
    @State private var status: Coach.Status

    init(key: String, title: String, symbol: String, colors: [Color], night: String, facts: @escaping () -> String) {
        self.title = title
        self.symbol = symbol
        self.colors = colors
        self.night = night
        self.facts = facts
        // Checked here, not in onAppear: an empty card never appears, so it would never find out.
        _status = State(initialValue: Coach.status)
        _savedFor = AppStorage(wrappedValue: "", "\(key)For")
        _savedText = AppStorage(wrappedValue: "", "\(key)Text")
    }

    var body: some View {
        VStack { content }
            .task(id: "\(status == .ready)-\(night)") {
                if status == .ready, !night.isEmpty, savedFor != night, !writing { await write() }
            }
    }

    @ViewBuilder private var content: some View {
        if status == .ready || !savedText.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(title, systemImage: symbol)
                        .font(.headline)
                        .foregroundStyle(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                    Spacer()
                    Text("Written by on-device AI, can be wrong").font(.caption2).foregroundStyle(.secondary)
                    if !writing && status == .ready && !savedText.isEmpty {
                        Button { Task { await write() } } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless)
                            .help("Write it again")
                    }
                }
                let shown = Coach.withoutDashes(writing ? text : savedText)
                if !shown.isEmpty {
                    let lines = shown.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
                    VStack(alignment: .leading, spacing: 8) {
                        if lines.count == 2 {
                            Text(DailyBriefing.headline(String(lines[0]))).font(.title3.weight(.semibold))
                            Text(lines[1].trimmingCharacters(in: .whitespacesAndNewlines))
                        } else {
                            Text(shown)
                        }
                    }
                    .textSelection(.enabled)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                } else if !writing {
                    Button { Task { await write() } } label: { Label("Explain it", systemImage: "wand.and.stars") }
                        .buttonStyle(.borderedProminent)
                        .tint(colors[0])
                }
                if writing && text.isEmpty {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading the numbers…").foregroundStyle(.secondary) }
                }
                if let failure { Text(failure).font(.caption).foregroundStyle(.orange) }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(colors: colors.map { $0.opacity(0.1) }, startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 14)
            )
        }
    }

    private func write() async {
        let facts = facts()
        guard !facts.isEmpty else { return }
        writing = true
        failure = nil
        text = ""
        defer { writing = false }
        do {
            try await Coach.write(facts: facts, instructions: Coach.healthInstructions, temperature: 0.4) { text = $0 }
            savedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            savedFor = night
        } catch {
            failure = "Couldn't write it: \(error.localizedDescription)"
        }
    }
}

/// Last night's detail that isn't stored: fetched when a night is shown, kept for the session.
@MainActor
enum NightCache {
    private static var hrv: [String: [(Date, Double)]] = [:]
    private static var heartRate: [String: [(Date, Double)]] = [:]
    private static var live: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil }

    /// HRV every 5 minutes through the night that ended on `date`.
    static func hrv(_ date: String) async -> [(Date, Double)] {
        if let cached = hrv[date] { return cached }
        guard live, let night: HRVNightDTO = try? await GarminClient.shared.get(Endpoint.hrvNight(date)) else { return [] }
        hrv[date] = night.readings
        return night.readings
    }

    /// Heart rate every 2 minutes between falling asleep and waking. The night spans two calendar days.
    static func heartRate(_ date: String, from start: Date, to end: Date) async -> [(Date, Double)] {
        if let cached = heartRate[date] { return cached }
        guard live, let day = GarminDate.day(date) else { return [] }
        let before = GarminDate.string(Calendar.current.date(byAdding: .day, value: -1, to: day)!)
        var values: [(Date, Double)] = []
        for d in Calendar.current.isDate(start, inSameDayAs: day) ? [date] : [before, date] {
            let (path, query) = Endpoint.dailyHeartRate(d)
            guard let dto: DailyHeartRateDTO = try? await GarminClient.shared.get(path, query: query) else { return [] }
            values += dto.values.filter { $0.0 >= start && $0.0 <= end }
        }
        heartRate[date] = values
        return values
    }
}

enum DebugFlags {
    /// `-scrollBottom YES` (Debug): long pages open scrolled to the end, for screenshots.
    static var scrollBottom: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "scrollBottom")
        #else
        false
        #endif
    }
}
