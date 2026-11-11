import Foundation

// The numbers behind the Sleep and HRV pages. Pure functions over stored `Day`s and `Activity`s, so they're
// testable and the views only draw. Methods are the ones sports and sleep scientists use, kept simple enough
// to explain on the page.

private func mean(_ xs: [Double]) -> Double? { xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count) }

private func standardDeviation(_ xs: [Double]) -> Double? {
    guard xs.count > 1, let m = mean(xs) else { return nil }
    return (xs.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(xs.count - 1)).squareRoot()
}

private func median(_ xs: [Double]) -> Double? {
    guard !xs.isEmpty else { return nil }
    let s = xs.sorted()
    return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
}

// MARK: HRV

/// HRV read the way it's read in sports science (Plews et al. 2012, 2013; Buchheit 2014):
/// - ln(rMSSD), because HRV is skewed and the log makes a day's change mean the same at 40 ms and at 90 ms.
/// - A 7-day rolling mean, since one morning says little.
/// - A normal range from the 60 days before: their mean ± 0.5 SD (the smallest change worth noticing).
/// - The coefficient of variation over the same 7 days: how much it swings from day to day.
enum HRVAnalysis {
    static let window = 7
    static let baselineDays = 60
    /// Mornings needed in a window before it says anything.
    static let minimumInWindow = 4
    static let minimumInBaseline = 20

    struct Morning: Identifiable {
        let date: Date
        let ms: Double
        var ln: Double { log(ms) }
        var id: Date { date }
    }

    struct Point: Identifiable {
        let date: Date
        /// 7-day mean of ln(rMSSD).
        let mean: Double
        /// Coefficient of variation of ln(rMSSD) over those 7 days, in %.
        let cv: Double
        /// The normal range for the mean, in ln(ms): baseline ± 0.5 SD. Nil until there are 60 days to go on.
        let low: Double?
        let high: Double?
        /// The usual swing: the mean CV of the 60 days before.
        let usualCV: Double?
        var id: Date { date }
        var meanMs: Double { exp(mean) }
        var lowMs: Double? { low.map(exp) }
        var highMs: Double? { high.map(exp) }
    }

    enum Level: String { case below, within, above }

    static func mornings(_ days: [Day]) -> [Morning] {
        var result: [Morning] = []
        for d in days {
            if let value = d.hrvLastNight, value > 0 { result.append(Morning(date: d.day, ms: Double(value))) }
        }
        return result.sorted { $0.date < $1.date }
    }

    /// One point a day from the first full week on.
    static func series(_ mornings: [Morning]) -> [Point] {
        let calendar = Calendar.current
        var points: [Point] = []
        for (i, m) in mornings.enumerated() {
            let weekStart = calendar.date(byAdding: .day, value: -(window - 1), to: m.date)!
            let week = mornings[...i].reversed().prefix { $0.date >= weekStart }.map(\.ln)
            guard week.count >= minimumInWindow, let wMean = mean(week), let wSD = standardDeviation(week) else { continue }
            let baseStart = calendar.date(byAdding: .day, value: -baselineDays, to: m.date)!
            let base = mornings[..<i].filter { $0.date >= baseStart }.map(\.ln)
            var low: Double?, high: Double?
            if base.count >= minimumInBaseline, let bMean = mean(base), let bSD = standardDeviation(base) {
                low = bMean - 0.5 * bSD
                high = bMean + 0.5 * bSD
            }
            let earlierCVs = points.filter { $0.date >= baseStart }.map(\.cv)
            points.append(Point(date: m.date, mean: wMean, cv: wSD / wMean * 100, low: low, high: high,
                                usualCV: earlierCVs.count >= minimumInBaseline / 2 ? mean(earlierCVs) : nil))
        }
        return points
    }

    static func level(_ p: Point) -> Level? {
        guard let low = p.low, let high = p.high else { return nil }
        return p.mean < low ? .below : p.mean > high ? .above : .within
    }

    /// The mean of the 60 days before a date, as (mean ln, SD ln).
    static func baseline(_ mornings: [Morning], before date: Date) -> (mean: Double, sd: Double)? {
        let start = Calendar.current.date(byAdding: .day, value: -baselineDays, to: date)!
        let base = mornings.filter { $0.date >= start && $0.date < date }.map(\.ln)
        guard base.count >= minimumInBaseline, let m = mean(base), let sd = standardDeviation(base) else { return nil }
        return (m, sd)
    }

    // MARK: HRV and resting heart rate together

    /// Buchheit (2014): HRV and resting heart rate moving in opposite directions say more than either alone.
    /// Each morning as z-scores against its own 60 days before: x is resting heart rate, y is HRV.
    struct Pair: Identifiable {
        let date: Date
        let hrv: Double
        let restingHR: Double
        var id: Date { date }
    }

    static func pairs(_ days: [Day]) -> [Pair] {
        let sorted = days.sorted { $0.date < $1.date }
        let calendar = Calendar.current
        var result: [Pair] = []
        for (i, d) in sorted.enumerated() {
            guard let hrv = d.hrvLastNight, hrv > 0, let rhr = d.restingHR else { continue }
            let start = calendar.date(byAdding: .day, value: -baselineDays, to: d.day)!
            let base = sorted[..<i].filter { $0.day >= start }
            let lns = base.compactMap { $0.hrvLastNight.flatMap { $0 > 0 ? log(Double($0)) : nil } }
            let rhrs = base.compactMap { $0.restingHR.map(Double.init) }
            guard lns.count >= minimumInBaseline, rhrs.count >= minimumInBaseline,
                  let lm = mean(lns), let ls = standardDeviation(lns), ls > 0,
                  let rm = mean(rhrs), let rs = standardDeviation(rhrs), rs > 0 else { continue }
            result.append(Pair(date: d.day, hrv: (log(Double(hrv)) - lm) / ls, restingHR: (Double(rhr) - rm) / rs))
        }
        return result
    }

    // MARK: What moves it

    /// The mornings after a kind of day, as the average difference from normal in %.
    struct Driver: Identifiable {
        let group: String
        let label: String
        let percent: Double
        let count: Int
        var id: String { group + label }
    }

    /// Next-morning HRV against its 60-day normal, grouped by the day and night before it. Descriptive, not
    /// causal: it shows what tends to come with a lower or higher morning.
    static func drivers(days: [Day], activities: [Activity]) -> [Driver] {
        let calendar = Calendar.current
        let ms = mornings(days)
        var loadByDay: [Date: Double] = [:]
        for a in activities { loadByDay[calendar.startOfDay(for: a.start), default: 0] += a.trainingLoad ?? 0 }
        let trainingLoads = loadByDay.values.filter { $0 > 0 }.sorted()
        let hard = trainingLoads.isEmpty ? .infinity : trainingLoads[trainingLoads.count * 2 / 3]
        let byDate = Dictionary(days.map { ($0.date, $0) }, uniquingKeysWith: { a, _ in a })

        var groups: [String: [String: [Double]]] = [:]
        for m in ms {
            guard let base = baseline(ms, before: m.date) else { continue }
            let percent = (exp(m.ln - base.mean) - 1) * 100
            let dayBefore = calendar.date(byAdding: .day, value: -1, to: m.date)!
            let load = loadByDay[dayBefore] ?? 0
            let training = load == 0 ? "Rest day" : load >= hard ? "Hard day" : "Easier day"
            groups["Training the day before", default: [:]][training, default: []].append(percent)

            let night = byDate[GarminDate.string(m.date)]
            if let start = night?.sleepStart {
                let hour = SleepAnalysis.clockHours(start, wakeDay: m.date)
                let bedtime = hour < 23 ? "Asleep before 23:00" : hour < 24 ? "23:00 to midnight" : "After midnight"
                groups["Bedtime", default: [:]][bedtime, default: []].append(percent)
            }
            if let seconds = night?.sleepSeconds {
                let hours = Double(seconds) / 3600
                let length = hours < 6.5 ? "Under 6½ h" : hours < 7.5 ? "6½ to 7½ h" : "7½ h or more"
                groups["Sleep", default: [:]][length, default: []].append(percent)
            }
            let weekday = calendar.component(.weekday, from: m.date)
            groups["Night", default: [:]][weekday == 1 || weekday == 7 ? "Weekend nights" : "Weeknights", default: []].append(percent)
        }
        let order: [String: [String]] = [
            "Training the day before": ["Rest day", "Easier day", "Hard day"],
            "Bedtime": ["Asleep before 23:00", "23:00 to midnight", "After midnight"],
            "Sleep": ["Under 6½ h", "6½ to 7½ h", "7½ h or more"],
            "Night": ["Weeknights", "Weekend nights"],
        ]
        return ["Training the day before", "Bedtime", "Sleep", "Night"].flatMap { group in
            (order[group] ?? []).compactMap { label in
                guard let values = groups[group]?[label], values.count >= 5, let m = mean(values) else { return nil }
                return Driver(group: group, label: label, percent: m, count: values.count)
            }
        }
    }

    // MARK: Training load

    /// Acute to chronic: the last 7 days' training load against the weekly average of the last 28.
    static func loadRatio(_ activities: [Activity], now: Date = Date()) -> Double? {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let week = calendar.date(byAdding: .day, value: -6, to: today)!
        let month = calendar.date(byAdding: .day, value: -27, to: today)!
        let acute = activities.filter { $0.start >= week }.compactMap(\.trainingLoad).reduce(0, +)
        let chronic = activities.filter { $0.start >= month }.compactMap(\.trainingLoad).reduce(0, +) / 4
        return chronic > 0 ? acute / chronic : nil
    }
}

// MARK: Sleep

/// Sleep timing and amount, beyond Garmin's score:
/// - Regularity: how much bedtime and wake time move from night to night (SD, in minutes).
/// - Social jetlag (Wittmann et al. 2006): midsleep on free days minus midsleep on workdays.
/// - Chronotype (Roenneberg's MSFsc, 2004): midsleep on free days, corrected for catching up on sleep.
/// - Sleep debt: what you slept against Garmin's sleep need, over the last 14 nights (Van Dongen et al. 2003
///   showed two weeks of 6 h nights add up to the effect of a night without sleep).
enum SleepAnalysis {
    /// Garmin's optimal shares of the night for adults, as its API returns them with every night.
    static let optimal: [(stage: String, low: Double, high: Double)] = [("Deep", 16, 33), ("Light", 30, 64), ("REM", 21, 31)]

    struct Night: Identifiable {
        let date: Date  // the morning it ended
        let start: Date
        let end: Date
        let asleep: Double  // seconds
        let need: Double?  // seconds
        let deep: Double, light: Double, rem: Double, awake: Double
        let score: Int?
        var id: Date { date }
        var inBed: Double { end.timeIntervalSince(start) }
        var midsleep: Date { start.addingTimeInterval(inBed / 2) }
        /// Bedtime and wake time as hours after the midnight before the morning: 23:30 is -0.5, 07:15 is 7.25.
        var bedtime: Double { SleepAnalysis.clockHours(start, wakeDay: date) - 24 }
        var wake: Double { SleepAnalysis.clockHours(end, wakeDay: date) - 24 }
        var midsleepHours: Double { SleepAnalysis.clockHours(midsleep, wakeDay: date) - 24 }
        var isFreeDay: Bool {
            let weekday = Calendar.current.component(.weekday, from: date)
            return weekday == 1 || weekday == 7
        }
        var efficiency: Double? { inBed > 0 ? min(asleep / inBed, 1) * 100 : nil }
        func share(_ seconds: Double) -> Double { asleep > 0 ? seconds / asleep * 100 : 0 }
    }

    /// Hours after the midnight that started the day before `wakeDay`: 23:00 the night before is 23, 07:00 is 31.
    static func clockHours(_ date: Date, wakeDay: Date) -> Double {
        let calendar = Calendar.current
        let previousMidnight = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: wakeDay))!
        return date.timeIntervalSince(previousMidnight) / 3600
    }

    static func nights(_ days: [Day]) -> [Night] {
        days.compactMap { d in
            guard let asleep = d.sleepSeconds, asleep > 0, let start = d.sleepStart, let end = d.sleepEnd, end > start else { return nil }
            let need = (d.sleepNeedMinutes ?? d.sleepNeedBaseline).map { Double($0 * 60) }
            return Night(date: d.day, start: start, end: end, asleep: Double(asleep), need: need,
                         deep: Double(d.deepSeconds ?? 0), light: Double(d.lightSeconds ?? 0), rem: Double(d.remSeconds ?? 0),
                         awake: Double(d.awakeSeconds ?? 0), score: d.sleepScore)
        }
        .sorted { $0.date < $1.date }
    }

    struct Regularity {
        /// Typical bedtime and wake time (median, in hours after midnight) and how much they move (SD, minutes).
        let bedtime: Double, wake: Double
        let bedtimeSpread: Double, wakeSpread: Double
    }

    static func regularity(_ nights: [Night]) -> Regularity? {
        guard nights.count >= 7, let bed = median(nights.map(\.bedtime)), let wake = median(nights.map(\.wake)),
              let bedSD = standardDeviation(nights.map(\.bedtime)), let wakeSD = standardDeviation(nights.map(\.wake)) else { return nil }
        return Regularity(bedtime: bed, wake: wake, bedtimeSpread: bedSD * 60, wakeSpread: wakeSD * 60)
    }

    struct BodyClock {
        /// Midsleep, in hours after midnight.
        let workdays: Double, freeDays: Double
        /// Free-day midsleep corrected for sleeping longer on free days (MSFsc).
        let chronotype: Double
        let workdaySleep: Double, freeDaySleep: Double  // hours in bed
        var socialJetlag: Double { freeDays - workdays }
        var label: String { chronotype < 3.5 ? "Early bird" : chronotype < 5 ? "In between" : "Night owl" }
    }

    static func bodyClock(_ nights: [Night]) -> BodyClock? {
        let free = nights.filter(\.isFreeDay), work = nights.filter { !$0.isFreeDay }
        guard free.count >= 3, work.count >= 5,
              let msf = mean(free.map(\.midsleepHours)), let msw = mean(work.map(\.midsleepHours)),
              let sdf = mean(free.map { $0.inBed / 3600 }), let sdw = mean(work.map { $0.inBed / 3600 }) else { return nil }
        let week = (5 * sdw + 2 * sdf) / 7
        let corrected = sdf > sdw ? msf - (sdf - week) / 2 : msf
        return BodyClock(workdays: msw, freeDays: msf, chronotype: corrected, workdaySleep: sdw, freeDaySleep: sdf)
    }

    /// Each night's sleep minus its need, in seconds (negative is short). Nights without a need are left out.
    static func balance(_ nights: [Night]) -> [(date: Date, seconds: Double)] {
        nights.compactMap { n in n.need.map { (n.date, n.asleep - $0) } }
    }

    /// The last 14 nights' shortfall, in seconds: positive means owed. A long night pays back, but not past zero.
    static func debt(_ nights: [Night], now: Date = Date()) -> Double? {
        let start = Calendar.current.date(byAdding: .day, value: -14, to: Calendar.current.startOfDay(for: now))!
        let recent = balance(nights.filter { $0.date > start })
        guard recent.count >= 5 else { return nil }
        return max(0, -recent.map(\.seconds).reduce(0, +))
    }

    /// Average share of the night in each stage, in %.
    static func stageShares(_ nights: [Night]) -> [String: Double] {
        let withStages = nights.filter { $0.deep + $0.light + $0.rem > 0 }
        guard !withStages.isEmpty else { return [:] }
        return [
            "Deep": mean(withStages.map { $0.share($0.deep) }) ?? 0,
            "Light": mean(withStages.map { $0.share($0.light) }) ?? 0,
            "REM": mean(withStages.map { $0.share($0.rem) }) ?? 0,
        ]
    }

    /// "23:40" from hours after midnight (-0.33).
    static func clock(_ hours: Double) -> String {
        var minutes = Int((hours * 60).rounded()) % (24 * 60)
        if minutes < 0 { minutes += 24 * 60 }
        return String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}
