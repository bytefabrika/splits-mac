import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Writes a short take on an activity with Apple's on-device language model. Only the on-device model is
/// used (never Private Cloud Compute): the data stays on this Mac, like everything else in Splits.
enum Coach {
    enum Status: Equatable {
        case ready
        case unavailable(String)
    }

    static var status: Status {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return .ready
            case .unavailable(.deviceNotEligible): return .unavailable("This Mac doesn't support Apple Intelligence.")
            case .unavailable(.appleIntelligenceNotEnabled): return .unavailable("Turn on Apple Intelligence in System Settings to get a take on your activities.")
            case .unavailable(.modelNotReady): return .unavailable("Apple Intelligence is still getting ready. Try again in a little while.")
            case .unavailable: return .unavailable("Apple Intelligence isn't available right now.")
            }
        }
        #endif
        return .unavailable("Needs macOS 26 or later with Apple Intelligence.")
    }

    static let instructions = """
    You are a friendly, knowledgeable endurance coach looking at one of the user's workouts from their Garmin watch.
    Write a short take in plain English: 3 short paragraphs, no headings, no lists, under 150 words in total.
    1. What kind of session this was and how it went, using the numbers given.
    2. Pacing and effort: were the splits even, did they speed up or fade, what heart rate and zones say. Compare with \
    their recent sessions of the same sport when that's given.
    3. One practical suggestion for recovery or the next session, taking last night's sleep, HRV and Body Battery \
    into account when given.
    Only use the facts provided; never invent numbers. Be encouraging but honest. No medical advice.
    Never use em dashes (—); use commas or full stops instead.
    """

    /// Streams the take. `onText` gets the text so far, on the main actor.
    @MainActor
    static func write(facts: String, instructions: String = Coach.instructions, temperature: Double = 0.6,
                      onText: @escaping (String) -> Void) async throws {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            let session = LanguageModelSession(model: .default, instructions: instructions)
            let stream = session.streamResponse(to: facts, options: GenerationOptions(temperature: temperature))
            for try await snapshot in stream {
                onText(withoutDashes(snapshot.content))
            }
            return
        }
        #endif
        throw CocoaError(.featureUnsupported)
    }

    /// The model still writes the odd em dash despite being asked not to: "a — b" and "a—b" become "a, b".
    static func withoutDashes(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s*—\s*"#, with: ", ", options: .regularExpression)
    }

    /// The workout as compact facts for the model. Units follow the user's settings.
    static func facts(activity: Activity, analysis: TrackAnalysis?, recent: [Activity], morning: Day?, format: Format) -> String {
        var lines: [String] = []
        let sport = activity.sport
        let paceLike = [.run, .walk, .hike].contains(sport)
        func paceOrSpeed(_ a: Activity) -> String? {
            if paceLike { return a.paceSecondsPerKm.map { format.pace(secondsPerKm: $0) } }
            return a.averageSpeed.map { format.speed(metresPerSecond: $0) }
        }

        lines.append("Workout: \(Format.title(activity.typeKey)) on \(activity.start.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute()))"
                     + (activity.name.isEmpty ? "" : ", named \"\(activity.name)\""))
        if activity.distance > 0 { lines.append("Distance: \(format.distance(activity.distance))") }
        lines.append(activity.sport.isDistanceSport
                     ? "Moving time: \(Format.duration(activity.movingDuration)) (elapsed \(Format.duration(activity.duration)))"
                     : "Duration: \(Format.duration(activity.duration))")
        if let p = paceOrSpeed(activity) { lines.append((paceLike ? "Average pace: " : "Average speed: ") + p) }
        if activity.elevationGain > 0 && !Sport.isIndoor(activity.typeKey) { lines.append("Climb: \(format.elevation(activity.elevationGain))") }
        if Sport.isIndoor(activity.typeKey) { lines.append("Indoors (treadmill, trainer or similar).") }
        if let hr = activity.averageHR { lines.append("Heart rate: average \(Int(hr)), max \(Int(activity.maxHR ?? hr)) bpm") }
        if activity.hrZones.count == 5 {
            let total = max(activity.hrZones.reduce(0, +), 1)
            lines.append("Time in heart rate zones 1–5: " + activity.hrZones.map { "\(Int($0 / total * 100))%" }.joined(separator: ", "))
        }
        if let power = activity.averagePower { lines.append("Average power: \(Int(power)) W") }
        if let cadence = activity.cadence { lines.append("Cadence: \(Int(cadence)) spm") }
        if let te = activity.aerobicEffect {
            lines.append(String(format: "Garmin training effect: aerobic %.1f, anaerobic %.1f (out of 5)", te, activity.anaerobicEffect ?? 0))
        }
        if let load = activity.trainingLoad { lines.append("Training load: \(Int(load))") }
        if let t = activity.minTemperature { lines.append("Temperature: \(Int(t))–\(Int(activity.maxTemperature ?? t)) °C") }

        if let analysis, !analysis.splits.isEmpty {
            let unit = format.imperial ? "mile" : "km"
            let splits = analysis.splits.prefix(45).map { s -> String in
                let perMetre = s.seconds / s.length
                return paceLike ? format.pace(secondsPerKm: perMetre * 1000) : format.speed(metresPerSecond: 1 / perMetre)
            }
            lines.append("Splits per \(unit), in order: " + splits.joined(separator: ", "))
            if !analysis.bests.isEmpty, sport == .run {
                lines.append("Fastest stretches: " + analysis.bests.map { "\($0.id) in \(Format.duration($0.seconds))" }.joined(separator: ", "))
            }
        }

        let same = recent.filter { $0.sport == sport && $0.garminId != activity.garminId && $0.start < activity.start }.prefix(10)
        if same.count >= 3 {
            let avgDistance = same.reduce(0) { $0 + $1.distance } / Double(same.count)
            let avgHR = same.compactMap(\.averageHR)
            var line = "Their previous \(same.count) \(sport.label.lowercased()) sessions averaged \(format.distance(avgDistance))"
            if paceLike {
                let paces = same.compactMap(\.paceSecondsPerKm)
                if !paces.isEmpty { line += " at \(format.pace(secondsPerKm: paces.reduce(0, +) / Double(paces.count)))" }
            }
            if !avgHR.isEmpty { line += ", average heart rate \(Int(avgHR.reduce(0, +) / Double(avgHR.count))) bpm" }
            lines.append(line + ".")
        }

        if let morning {
            var parts: [String] = []
            if let s = morning.sleepSeconds { parts.append("slept \(Format.hoursMinutes(s))" + (morning.sleepScore.map { " (sleep score \($0))" } ?? "")) }
            if let hrv = morning.hrvLastNight { parts.append("overnight HRV \(hrv) ms" + (morning.hrvStatus.map { ", status \(Format.title($0).lowercased())" } ?? "")) }
            if let bb = morning.bodyBatteryHigh { parts.append("Body Battery peaked at \(bb)") }
            if let rhr = morning.restingHR { parts.append("resting heart rate \(rhr)") }
            if !parts.isEmpty { lines.append("That day: " + parts.joined(separator: "; ") + ".") }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Daily briefing

    /// The verdict worked out in `dailyFacts`, and the plan in the user's own words (the facts speak about them
    /// in the third person, for the model), for the notification and the widget.
    static func dailyAssessment(_ facts: String) -> (verdict: String, plan: String)? {
        guard let line = facts.split(separator: "\n").first(where: { $0.hasPrefix("Recovery verdict: ") }) else { return nil }
        let verdict = line.dropFirst("Recovery verdict: ".count).prefix { $0 != "." }
        switch verdict {
        case "well recovered": return ("Well recovered", "Room for a harder session today.")
        case "partly recovered": return ("Partly recovered", "Keep it easy today: an easy run, or rest if you feel flat.")
        case let v where v.hasPrefix("unknown"): return ("Waiting for last night", "Your briefing comes once your watch has synced last night.")
        default: return ("Not well recovered", "Rest day today, or something very light like a walk.")
        }
    }

    static let dailyInstructions = """
    You are a witty, upbeat running buddy writing someone's morning briefing from their Garmin data. Funny like a \
    friend, accurate like a coach.
    Format: one short headline line (under 10 words, one emoji) that matches the recovery verdict, then 3 short \
    paragraphs of 1–2 sentences each, under 90 words in total. No lists.
    1. Recovery, following the verdict and its reasons, with one playful comparison.
    2. Recent training exactly as described (if yesterday had no training, say so), with a light joke.
    3. Today's recommendation exactly as given, plus the run streak if it's given.
    Use at most four numbers, copied exactly from the facts. Never make up events, causes or comparisons. \
    Teasing is fine, guilt-tripping isn't. No medical advice.
    Never use em dashes (—); use commas or full stops instead.
    """

    /// This morning's numbers against the two weeks before, plus recent training, as compact facts for the model.
    static func dailyFacts(activities: [Activity], days: [Day], format: Format, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let twoWeeksAgo = calendar.date(byAdding: .day, value: -14, to: today)!
        let todayDay = days.first { calendar.isDate($0.day, inSameDayAs: today) }
        let before = days.filter { $0.day >= twoWeeksAgo && $0.day < today }
        func avg(_ values: [Int]) -> Int? { values.isEmpty ? nil : values.reduce(0, +) / values.count }
        var lines = ["Today is \(now.formatted(.dateTime.weekday(.wide).day().month(.wide)))."]
        // Signals that say "not fully recovered", and ones that say "fresh". The verdict comes from these, here,
        // not from the model: the small on-device model is good at words, not at weighing numbers.
        var tired: [String] = [], fresh: [String] = []

        if let d = todayDay {
            if let sleep = d.sleepSeconds {
                var line = "Last night: slept \(Format.hoursMinutes(sleep))"
                if let score = d.sleepScore { line += ", sleep score \(score) out of 100" }
                if let usual = avg(before.compactMap(\.sleepSeconds)) {
                    let diff = (sleep - usual) / 60
                    line += diff >= 30 ? ", \(diff) min more than usual" : diff <= -30 ? ", \(-diff) min less than usual" : ", about their usual"
                    if diff <= -45 { tired.append("short sleep") } else if diff >= 30 { fresh.append("a long night's sleep") }
                }
                if let score = d.sleepScore {
                    if score < 60 { tired.append("poor sleep score") } else if score >= 80 { fresh.append("good sleep score") }
                }
                lines.append(line + ".")
            } else {
                lines.append("Last night's sleep hasn't synced yet.")
            }
            if let hrv = d.hrvLastNight {
                var line = "Overnight HRV \(hrv) ms"
                if let low = d.hrvBalancedLow, let high = d.hrvBalancedHigh {
                    line += hrv < low ? ", below their normal range of \(low)–\(high)" : hrv > high ? ", above their normal range of \(low)–\(high)" : ", inside their normal range of \(low)–\(high)"
                    if hrv < low { tired.append("HRV below normal") } else { fresh.append("HRV in its normal range") }
                }
                if let status = d.hrvStatus?.lowercased(), status.contains("low") || status.contains("unbalanced") {
                    line += "; the 7-day HRV status is \(Format.title(status).lowercased())"
                    if !tired.contains("HRV below normal") { tired.append("HRV status \(Format.title(status).lowercased())") }
                }
                lines.append(line + ".")
            }
            if let rhr = d.restingHR, let usual = avg(before.compactMap(\.restingHR)) {
                let diff = rhr - usual
                lines.append("Resting heart rate \(rhr) bpm, " + (diff >= 3 ? "\(diff) above their usual \(usual)" : diff <= -2 ? "\(-diff) below their usual \(usual)" : "about their usual \(usual)") + ".")
                if diff >= 3 { tired.append("resting heart rate up") } else if diff <= 0 { fresh.append("resting heart rate normal") }
            }
            if let high = d.bodyBatteryHigh {
                let usual = avg(before.compactMap(\.bodyBatteryHigh))
                var line = "Body Battery charged to \(high) overnight"
                if let usual { line += high >= usual + 8 ? ", higher than usual (\(usual))" : high <= usual - 8 ? ", lower than usual (\(usual))" : ", about usual" }
                lines.append(line + ".")
                if let usual, high <= usual - 10 || high < 40 { tired.append("low Body Battery") } else if high >= 75 { fresh.append("Body Battery well charged") }
            }
        }

        func describe(_ a: Activity) -> String {
            var text = Format.title(a.typeKey)
            if a.distance > 0 { text += " of \(format.distance(a.distance))" }
            text += " (\(Format.duration(a.activeSeconds)))"
            return text
        }
        let todays = activities.filter { $0.start >= today }
        let yesterdays = activities.filter { $0.start >= yesterday && $0.start < today }
        lines.append(yesterdays.isEmpty ? "Yesterday: no training." : "Yesterday: " + yesterdays.map(describe).joined(separator: ", ") + ".")
        if !todays.isEmpty { lines.append("Already done today: " + todays.map(describe).joined(separator: ", ") + ".") }

        let weekStart = calendar.date(byAdding: .day, value: -7, to: today)!
        let base = activities.filter { $0.start >= calendar.date(byAdding: .day, value: -35, to: today)! && $0.start < weekStart }
        let week = activities.filter { $0.start >= weekStart && $0.start < today }
        let load = week.compactMap(\.trainingLoad).reduce(0, +), usualLoad = base.compactMap(\.trainingLoad).reduce(0, +) / 4
        if usualLoad > 0 {
            let ratio = load / usualLoad
            let pct = Int((abs(ratio - 1) * 100).rounded())
            lines.append("Training over the last 7 days: " + (ratio >= 1.15 ? "\(pct)% more than a usual week (a big week)" : ratio <= 0.85 ? "\(pct)% less than a usual week (a light week)" : "about a usual week") + ".")
            if ratio >= 1.3 { tired.append("a much bigger week than usual") } else if ratio <= 0.85 { fresh.append("a light week") }
        }
        let trainingDays = Set(activities.filter { $0.start < today }.map { calendar.startOfDay(for: $0.start) })
        var day = yesterday, inRow = 0
        while trainingDays.contains(day) && inRow < 60 { inRow += 1; day = calendar.date(byAdding: .day, value: -1, to: day)! }
        if inRow >= 3 { lines.append("They've trained \(inRow) days in a row."); if inRow >= 6 { tired.append("\(inRow) days without a rest day") } }
        if inRow == 0, let last = activities.first(where: { $0.start < today }) {
            let gap = calendar.dateComponents([.day], from: calendar.startOfDay(for: last.start), to: today).day ?? 0
            if gap >= 2 { lines.append("Their last activity was \(gap) days ago."); fresh.append("\(gap) days of rest") }
        }

        let verdict: String, plan: String
        let lastNightIn = todayDay?.sleepSeconds != nil || todayDay?.hrvLastNight != nil
        switch tired.count {
        case _ where !lastNightIn:
            verdict = "unknown, last night's data hasn't synced from their watch yet"
            plan = "No call on recovery yet; go by feel until the watch syncs."
        case 0:
            verdict = "well recovered"
            plan = "There's room for a harder session today (intervals, tempo or a long run) if they want one."
        case 1...2:
            verdict = "partly recovered"
            plan = "Keep it easy today: an easy run, or a rest day if they feel flat."
        default:
            verdict = "not well recovered"
            plan = "Take a rest day today, or something very light like a walk."
        }
        lines.append("Recovery verdict: \(verdict)." + (tired.isEmpty ? "" : " Against: \(tired.joined(separator: ", ")).")
                     + (fresh.isEmpty ? "" : " For: \(fresh.joined(separator: ", ")).") )
        lines.append("Recommendation: \(plan)")

        let runs = activities.filter { $0.sport == .run }.map(\.start)
        let streak = Streaks(dates: runs, today: now, calendar: calendar)
        if streak.currentWeeks >= 2 {
            let left = max(0, 3 - streak.thisWeek)
            lines.append("Run streak: \(streak.currentWeeks) weeks in a row with 3 or more runs. This week: \(streak.thisWeek) so far"
                         + (left > 0 ? ", \(left) more needed by Sunday." : ", this week's 3 are done."))
        }
        return lines.joined(separator: "\n")
    }
}
