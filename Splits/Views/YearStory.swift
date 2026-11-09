import Charts
import CoreLocation
import SwiftUI

/// A year, worked out from the local store, for the story.
struct YearStats {
    let year: Int
    let activities: [Activity]
    let days: [Day]

    init(year: Int, activities: [Activity], days: [Day]) {
        let calendar = Calendar.current
        self.year = year
        self.activities = activities.filter { calendar.component(.year, from: $0.start) == year }.sorted { $0.start < $1.start }
        self.days = days.filter { calendar.component(.year, from: $0.day) == year }
    }

    var count: Int { activities.count }
    var activeDays: Int { Set(activities.map { Calendar.current.startOfDay(for: $0.start) }).count }
    var distance: Double { activities.reduce(0) { $0 + $1.distance } }
    var seconds: Double { activities.reduce(0) { $0 + $1.activeSeconds } }
    var climb: Double { activities.filter { !Sport.isIndoor($0.typeKey) }.reduce(0) { $0 + $1.elevationGain } }
    var calories: Double { activities.compactMap(\.calories).reduce(0, +) }

    var sports: [(Sport, Double, Int)] {
        Dictionary(grouping: activities, by: \.sport)
            .map { ($0.key, $0.value.reduce(0) { $0 + $1.activeSeconds }, $0.value.count) }
            .sorted { $0.1 > $1.1 }
    }

    var months: [Double] {
        var hours = Array(repeating: 0.0, count: 12)
        for a in activities { hours[Calendar.current.component(.month, from: a.start) - 1] += a.activeSeconds / 3600 }
        return hours
    }

    var longestStreak: Int {
        let days = Set(activities.map { Calendar.current.startOfDay(for: $0.start) }).sorted()
        var best = 0, run = 0
        var previous: Date?
        for day in days {
            run = previous.map { Calendar.current.date(byAdding: .day, value: 1, to: $0) == day } == true ? run + 1 : 1
            best = max(best, run)
            previous = day
        }
        return best
    }

    var favouriteWeekday: Int? {
        Dictionary(grouping: activities) { Calendar.current.component(.weekday, from: $0.start) }
            .max { $0.value.count < $1.value.count }?.key
    }

    /// 0 morning, 1 afternoon, 2 evening, 3 night.
    var timeOfDay: Int {
        var counts = [0, 0, 0, 0]
        for a in activities {
            let h = Calendar.current.component(.hour, from: a.start)
            counts[h >= 5 && h < 12 ? 0 : h >= 12 && h < 17 ? 1 : h >= 17 && h < 22 ? 2 : 3] += 1
        }
        return counts.firstIndex(of: counts.max() ?? 0) ?? 0
    }

    var runs: [Activity] { activities.filter { $0.sport == .run } }
    var fastestRun: Activity? {
        runs.filter { $0.distance >= 5000 && !Sport.isIndoor($0.typeKey) }
            .min { ($0.paceSecondsPerKm ?? .infinity) < ($1.paceSecondsPerKm ?? .infinity) }
    }
    var longest: Activity? { activities.max { $0.distance < $1.distance } }

    // Wellness
    func average(_ values: [Int]) -> Int? { values.isEmpty ? nil : values.reduce(0, +) / values.count }
    var averageSleep: Int? { average(days.compactMap(\.sleepSeconds)) }
    var averageSleepScore: Int? { average(days.compactMap(\.sleepScore)) }
    var bestNight: Day? { days.filter { $0.sleepScore != nil }.max { ($0.sleepScore ?? 0) < ($1.sleepScore ?? 0) } }
    var steps: Int { days.compactMap(\.steps).reduce(0, +) }
    /// First and last month's average, to show the year's direction.
    func trend(_ value: KeyPath<Day, Int?>) -> (Int, Int)? {
        let sorted = days.sorted { $0.date < $1.date }.filter { $0[keyPath: value] != nil }
        guard sorted.count >= 40 else { return nil }
        let first = sorted.prefix(30).compactMap { $0[keyPath: value] }, last = sorted.suffix(30).compactMap { $0[keyPath: value] }
        return (first.reduce(0, +) / first.count, last.reduce(0, +) / last.count)
    }
}

private struct StorySlide: Identifiable {
    let id: String
    let background: Color
    let dark: Bool  // dark text on a bright background
    let emoji: String
    let sticker: String?
    let content: AnyView
}

/// The year as a story: one big number per slide, moving on by itself. ← → or clicks to move, Esc to close.
struct YearStory: View {
    let stats: YearStats
    let format: Format
    @Environment(\.dismiss) private var dismiss
    @State private var index: Int
    @State private var startedAt = Date()
    @State private var paused = false
    private let slideSeconds = 6.0

    init(stats: YearStats, format: Format, startAt: Int = 0) {
        self.stats = stats
        self.format = format
        _index = State(initialValue: startAt)
    }

    /// How many slides this year has (some only appear with enough data).
    var slideCount: Int { buildSlides().count }

    var body: some View {
        let slides = buildSlides()
        let slide = slides[min(index, slides.count - 1)]
        ZStack {
            slide.background.ignoresSafeArea()
            Circle().fill(.white.opacity(slide.dark ? 0.18 : 0.06)).frame(width: 520).offset(x: 280, y: -260)
            Circle().stroke(.white.opacity(slide.dark ? 0.2 : 0.08), lineWidth: 40).frame(width: 300).offset(x: -320, y: 260)

            VStack(alignment: .leading, spacing: 0) {
                progress(count: slides.count)
                HStack {
                    if let sticker = slide.sticker {
                        Text(sticker)
                            .font(.system(size: 18, weight: .heavy, design: .rounded))
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .background(slide.dark ? Color.black : Color.white, in: RoundedRectangle(cornerRadius: 10))
                            .foregroundStyle(slide.dark ? slide.background : .black)
                            .rotationEffect(.degrees(-5))
                    }
                    Spacer()
                    Text(slide.emoji).font(.system(size: 64))
                }
                .padding(.top, 30)
                Spacer()
                slide.content
                    .foregroundStyle(slide.dark ? Color.black.opacity(0.88) : .white)
                    .id(slide.id)
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                Spacer()
            }
            .padding(44)
            .frame(maxWidth: 760)

            HStack(spacing: 0) {
                Color.clear.contentShape(Rectangle()).onTapGesture { go(-1) }.frame(maxWidth: 200)
                Color.clear.contentShape(Rectangle()).onTapGesture { go(1) }
            }
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 760, idealHeight: 860)
        .animation(.spring(duration: 0.45), value: index)
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.title) }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.8))
                .padding(16)
                .keyboardShortcut(.cancelAction)
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.rightArrow) { go(1); return .handled }
        .onKeyPress(.leftArrow) { go(-1); return .handled }
        .onKeyPress(.space) { paused.toggle(); startedAt = Date(); return .handled }
        .task(id: index) {
            startedAt = Date()
            guard index < slides.count - 1 else { return }
            try? await Task.sleep(for: .seconds(slideSeconds))
            if !Task.isCancelled && !paused { go(1) }
        }
    }

    private func go(_ step: Int) {
        let count = buildSlides().count
        index = min(max(index + step, 0), count - 1)
    }

    private func progress(count: Int) -> some View {
        HStack(spacing: 5) {
            ForEach(0..<count, id: \.self) { i in
                Capsule().fill(.white.opacity(i <= index ? 0.95 : 0.3)).frame(height: 4)
            }
        }
    }

    // MARK: Slides

    private func big(_ value: String, unit: String = "") -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(value).font(.system(size: 120, weight: .black, design: .rounded)).minimumScaleFactor(0.4).lineLimit(1)
            if !unit.isEmpty { Text(unit).font(.system(size: 34, weight: .heavy, design: .rounded)) }
        }
    }

    private func kicker(_ text: String) -> some View {
        Text(text).font(.system(size: 26, weight: .bold, design: .rounded)).opacity(0.75)
    }

    private func lead(_ text: String) -> some View {
        Text(text).font(.system(size: 24, weight: .medium)).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
    }

    private func buildSlides() -> [StorySlide] {
        let s = stats
        var slides: [StorySlide] = []
        func add(_ id: String, _ bg: Color, dark: Bool = true, _ emoji: String, sticker: String? = nil, @ViewBuilder _ content: () -> some View) {
            slides.append(StorySlide(id: id, background: bg, dark: dark, emoji: emoji, sticker: sticker, content: AnyView(content())))
        }

        add("intro", Sport.walk.color, "🏁") {
            VStack(alignment: .leading, spacing: 0) {
                kicker("Your year in sport")
                Text(String(s.year)).font(.system(size: 190, weight: .black, design: .rounded)).minimumScaleFactor(0.5)
                lead("Your watch saw everything. Let's talk about it.")
            }
        }
        add("count", Sport.swim.color, "⌚", sticker: s.activeDays >= 200 ? "Unstoppable" : s.activeDays >= 120 ? "Habit unlocked" : "Solid") {
            VStack(alignment: .leading, spacing: 0) {
                kicker("You pressed start")
                big(s.count.formatted(), unit: "times")
                lead("On \(s.activeDays) different days.\(s.activeDays >= 183 ? " More days moving than not." : "")")
            }
        }
        if s.distance > 0 {
            let marathons = s.distance / 42_195, earth = s.distance / 40_075_000 * 100
            add("distance", Sport.ride.color, "🌍", sticker: s.distance > 2_000_000 ? "Long hauler" : "Going places") {
                VStack(alignment: .leading, spacing: 0) {
                    kicker("You covered")
                    big(String(format.distance(s.distance, decimals: 0).split(separator: " ").first ?? ""), unit: format.distanceUnit)
                    lead("That's \(marathons.formatted(.number.precision(.fractionLength(1)))) marathons, or \(earth.formatted(.number.precision(.fractionLength(1))))% of the way around the planet.")
                }
            }
        }
        add("time", Sport.mindful.color, "⏱️") {
            VStack(alignment: .leading, spacing: 0) {
                kicker("Time in motion")
                big(Int(s.seconds / 3600).formatted(), unit: "hours")
                lead("That's \(Int(s.seconds / 2700)) TV episodes you didn't watch.")
            }
        }
        if let top = s.sports.first {
            let maxTime = s.sports.first?.1 ?? 1
            add("sports", Color(red: 0.07, green: 0.08, blue: 0.11), dark: false, top.0 == .run ? "🏃" : top.0 == .ride ? "🚴" : "⭐",
                sticker: s.sports.count >= 5 ? "All-rounder" : "Main character") {
                VStack(alignment: .leading, spacing: 14) {
                    kicker("Your number one")
                    Text(top.0.label).font(.system(size: 80, weight: .black, design: .rounded)).foregroundStyle(top.0.color)
                    ForEach(Array(s.sports.prefix(5)), id: \.0) { sport, seconds, count in
                        HStack {
                            Text(sport.label).font(.title3.bold()).frame(width: 170, alignment: .leading)
                            Capsule().fill(sport.color).frame(width: max(360 * seconds / maxTime, 8), height: 16)
                            Spacer()
                            Text("\(Int(seconds / 3600)) h · \(count)×").font(.title3.monospacedDigit()).opacity(0.7)
                        }
                    }
                }
            }
        }
        if s.runs.count >= 5, let runPace = Optional(s.runs.reduce(0) { $0 + $1.activeSeconds } / max(s.runs.reduce(0) { $0 + $1.distance } / 1000, 0.001)) {
            add("running", Sport.run.color, "👟", sticker: "Runner") {
                VStack(alignment: .leading, spacing: 0) {
                    kicker("You ran \(s.runs.count) times")
                    big(String(format.distance(s.runs.reduce(0) { $0 + $1.distance }, decimals: 0).split(separator: " ").first ?? ""), unit: format.distanceUnit)
                    lead("At an average of \(format.pace(secondsPerKm: runPace)).")
                    if let fast = s.fastestRun, let pace = fast.paceSecondsPerKm {
                        lead("Fastest run (5 km or more): \(format.pace(secondsPerKm: pace)) over \(format.distance(fast.distance)) on \(fast.start.formatted(.dateTime.day().month(.wide))).")
                    }
                }
            }
        }
        let months = s.months
        if let busiest = months.indices.max(by: { months[$0] < months[$1] }), months[busiest] > 0 {
            add("months", Sport.strength.color, "🔥") {
                VStack(alignment: .leading, spacing: 12) {
                    kicker("You were on fire in")
                    Text(Calendar.current.monthSymbols[busiest]).font(.system(size: 80, weight: .black, design: .rounded))
                    Chart(Array(months.enumerated()), id: \.offset) { i, hours in
                        BarMark(x: .value("Month", Calendar.current.veryShortMonthSymbols[i] + String(repeating: " ", count: i)), y: .value("Hours", hours))
                            .foregroundStyle(i == busiest ? Color.black : Color.black.opacity(0.25))
                            .cornerRadius(6)
                    }
                    .chartYAxis(.hidden)
                    .frame(height: 180)
                    lead("\(Int(months[busiest])) hours that month.")
                }
            }
        }
        let personas = [("Early bird", "🌅", "Most sessions started before noon."), ("Lunch break hero", "🥪", "Afternoons were your thing."),
                        ("After-work warrior", "🌆", "Laptop shut, shoes on. Evenings were yours."), ("Night owl", "🦉", "You trained while others slept.")]
        let persona = personas[s.timeOfDay]
        add("habits", Color(red: 1.0, green: 0.42, blue: 0.29), persona.1, sticker: "Your type") {
            VStack(alignment: .leading, spacing: 0) {
                kicker("You are an")
                Text(persona.0).font(.system(size: 80, weight: .black, design: .rounded)).minimumScaleFactor(0.5)
                lead(persona.2)
                HStack(spacing: 16) {
                    if let day = s.favouriteWeekday {
                        fact(Calendar.current.weekdaySymbols[day - 1] + "s", "your favourite day")
                    }
                    fact("\(s.longestStreak) days", "longest streak")
                }
                .padding(.top, 24)
            }
        }
        if s.climb >= 200 {
            add("climb", Color(red: 0.83, green: 0.95, blue: 0.24), "⛰️", sticker: s.climb >= 8849 ? "Summit club" : "Uphill fan") {
                VStack(alignment: .leading, spacing: 0) {
                    kicker("You climbed")
                    big(format.elevation(s.climb).split(separator: " ").first.map(String.init) ?? "", unit: format.imperial ? "ft" : "m")
                    lead(s.climb >= 8849 ? "That's Mount Everest \((s.climb / 8849).formatted(.number.precision(.fractionLength(1)))) times." : "That's the Eiffel Tower \(Int(s.climb / 330)) times.")
                }
            }
        }
        if let sleep = s.averageSleep {
            add("sleep", Color(red: 0.36, green: 0.3, blue: 0.85), dark: false, "😴", sticker: sleep >= 7 * 3600 ? "Well rested" : "Night shift") {
                VStack(alignment: .leading, spacing: 0) {
                    kicker("A typical night")
                    big(Format.hoursMinutes(sleep).replacingOccurrences(of: " min", with: "m").replacingOccurrences(of: " h ", with: "h "))
                    if let score = s.averageSleepScore { lead("Average sleep score \(score).") }
                    if let best = s.bestNight, let score = best.sleepScore {
                        lead("Best night: \(best.day.formatted(.dateTime.day().month(.wide))), score \(score).")
                    }
                }
            }
        }
        if let hrv = s.trend(\.hrvLastNight) {
            let rhr = s.trend(\.restingHR)
            add("heart", Color(red: 0.91, green: 0.09, blue: 0.29), dark: false, "❤️", sticker: hrv.1 >= hrv.0 ? "Heart of gold" : "Busy year") {
                VStack(alignment: .leading, spacing: 0) {
                    kicker("Your heart over the year")
                    big("\(hrv.0) → \(hrv.1)", unit: "ms")
                    lead("Overnight HRV, first month to last.\(hrv.1 > hrv.0 ? " Up is good." : "")")
                    if let rhr { lead("Resting heart rate went from \(rhr.0) to \(rhr.1) bpm.") }
                }
            }
        }
        if s.steps > 10_000 {
            add("steps", Color(red: 1.0, green: 0.84, blue: 0.65), "🦶", sticker: "Step machine") {
                VStack(alignment: .leading, spacing: 0) {
                    kicker("All day long, you took")
                    big(s.steps >= 1_000_000 ? (Double(s.steps) / 1_000_000).formatted(.number.precision(.fractionLength(1))) : s.steps.formatted(),
                        unit: s.steps >= 1_000_000 ? "million steps" : "steps")
                    lead("That's the Eiffel Tower's 1,665 stairs \((s.steps / 1665).formatted()) times.")
                }
            }
        }
        if let longest = s.longest, longest.distance > 0 {
            add("longest", Color(red: 0.07, green: 0.08, blue: 0.11), dark: false, "🏆", sticker: "Big day") {
                VStack(alignment: .leading, spacing: 0) {
                    kicker("Remember \(longest.start.formatted(.dateTime.day().month(.wide)))?")
                    big(String(format.distance(longest.distance).split(separator: " ").first ?? ""), unit: format.distanceUnit)
                        .foregroundStyle(longest.sport.color)
                    lead("Your longest \(longest.sport.label.lowercased()) of the year, in \(Format.duration(longest.activeSeconds)).")
                }
            }
        }
        add("summary", Color(red: 0.07, green: 0.08, blue: 0.11), dark: false, "🎉", sticker: "That's a wrap") {
            YearSummaryCard(stats: s, format: format)
        }
        return slides
    }

    private func fact(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 30, weight: .heavy, design: .rounded))
            Text(label).font(.callout).opacity(0.75)
        }
        .padding(16)
        .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 16))
        .foregroundStyle(.white)
    }
}

/// The last slide: the year on one card, with Share.
struct YearSummaryCard: View {
    let stats: YearStats
    let format: Format
    @State private var file: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            card.clipShape(RoundedRectangle(cornerRadius: 24))
            if let file {
                ShareLink(item: file) { Label("Share", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(.black)
            }
        }
        .onAppear { makeFile() }
    }

    var card: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("My year in sport").font(.system(size: 20, weight: .heavy, design: .rounded))
                Spacer()
                Text(String(stats.year)).font(.system(size: 64, weight: .black, design: .rounded))
            }
            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 12) {
                GridRow { cell("Activities", stats.count.formatted()); cell("Active days", "\(stats.activeDays)") }
                GridRow { cell("Distance", format.distance(stats.distance, decimals: 0)); cell("Hours", "\(Int(stats.seconds / 3600))") }
                GridRow { cell("Climbed", format.elevation(stats.climb)); cell("Best streak", "\(stats.longestStreak) days") }
            }
            if !stats.sports.isEmpty {
                GeometryReader { geo in
                    let total = max(stats.sports.reduce(0) { $0 + $1.1 }, 1)
                    HStack(spacing: 2) {
                        ForEach(stats.sports, id: \.0) { sport, seconds, _ in
                            Rectangle().fill(sport.color).frame(width: geo.size.width * seconds / total)
                        }
                    }
                }
                .frame(height: 12)
                .clipShape(Capsule())
                Text("Mostly \(stats.sports[0].0.label.lowercased())").font(.system(size: 18, weight: .heavy, design: .rounded))
            }
        }
        .padding(28)
        .frame(width: 520)
        .foregroundStyle(.black)
        .background(LinearGradient(colors: [Sport.walk.color, Sport.swim.color, Sport.strength.color], startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    private func cell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.system(size: 13, weight: .bold)).opacity(0.65)
            Text(value).font(.system(size: 28, weight: .heavy, design: .rounded)).monospacedDigit()
        }
    }

    private func makeFile() {
        let renderer = ImageRenderer(content: card)
        renderer.scale = 2
        guard let tiff = renderer.nsImage?.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("My \(stats.year) in sport.png")
        try? png.write(to: url)
        file = url
    }
}
