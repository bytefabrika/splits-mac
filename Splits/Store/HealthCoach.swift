import Foundation

// What the coach says on the Sleep and HRV pages. As with the daily briefing, the verdict, the observations
// and the advice are decided here; the on-device model only puts them into words.

extension Coach {
    static let healthInstructions = """
    You are a friendly, sharp coach explaining someone's Garmin data to them like a smart friend would.
    Format: one short, playful headline line (under 8 words, one emoji) that puts the verdict in your own words and \
    never sounds the opposite of it, then 3 short \
    paragraphs of 1–2 sentences each, under 100 words in total. No lists.
    1. Where things stand, following the verdict and its reasons.
    2. The pattern behind it, using only the observations given.
    3. The advice, exactly as given.
    Say each fact once. Use at most four numbers, copied exactly from the facts. Never make up causes, events or \
    numbers, and don't add numbers that aren't in the facts. \
    No medical advice, no diagnoses.
    Never use em dashes (—), quotes or markdown.
    """

    private static func percent(_ x: Double) -> String { "\(Int(abs(x).rounded()))%" }

    // MARK: HRV

    struct HRVAssessment {
        let verdict: String
        let reasons: [String]
        let observations: [String]
        let advice: String
    }

    static func hrvAssessment(days: [Day], activities: [Activity], now: Date = Date()) -> HRVAssessment? {
        let mornings = HRVAnalysis.mornings(days)
        let series = HRVAnalysis.series(mornings)
        guard let last = mornings.last, let latest = series.last else { return nil }
        var reasons: [String] = [], observations: [String] = []

        reasons.append("Last night's HRV was \(Int(last.ms)) ms.")
        let level = HRVAnalysis.level(latest)
        // Few numbers on purpose: the model copies every number it's given, and the charts show the rest.
        switch level {
        case .below: reasons.append("The 7-day average is below their normal range.")
        case .above: reasons.append("The 7-day average is above their normal range.")
        case .within: reasons.append("The 7-day average is inside their normal range.")
        case nil: break
        }
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: latest.date)!
        if let earlier = series.last(where: { $0.date <= weekAgo }) {
            let change = (exp(latest.mean - earlier.mean) - 1) * 100
            reasons.append(abs(change) < 3 ? "It's been steady over the past week." : "It has \(change > 0 ? "risen" : "fallen") \(percent(change)) over the past week.")
        }
        let jumpy = latest.usualCV.map { latest.cv > $0 * 1.5 } ?? false
        if jumpy { reasons.append("It's swinging more than usual from one morning to the next.") }

        let restingNow = days.suffix(7).compactMap(\.restingHR)
        let restingBefore = days.dropLast(7).suffix(60).compactMap(\.restingHR)
        var restingUp = false
        if restingNow.count >= 4, restingBefore.count >= 20 {
            let diff = Double(restingNow.reduce(0, +)) / Double(restingNow.count) - Double(restingBefore.reduce(0, +)) / Double(restingBefore.count)
            if abs(diff) >= 2 {
                reasons.append("Resting heart rate is \(Int(abs(diff).rounded())) bpm \(diff > 0 ? "above" : "below") usual.")
                restingUp = diff > 0
            }
        }
        if let ratio = HRVAnalysis.loadRatio(activities, now: now) {
            if ratio > 1.3 {
                observations.append("This week's training load is \(String(format: "%.1f", ratio)) times the usual week, a big step up.")
            } else if ratio < 0.7 {
                observations.append("This week's training has been lighter than usual.")
            }
        }
        let drivers = HRVAnalysis.drivers(days: days, activities: activities)
            .filter { abs($0.percent) >= 4 }
            .sorted { abs($0.percent) > abs($1.percent) }
        let when: [String: String] = [
            "Rest day": "after rest days", "Easier day": "after easier training days", "Hard day": "after hard training days",
            "Asleep before 23:00": "when they fall asleep before 23:00", "23:00 to midnight": "when they fall asleep before midnight",
            "After midnight": "when they fall asleep after midnight",
            "Under 6½ h": "after nights under 6½ hours", "6½ to 7½ h": "after 6½ to 7½ hours of sleep",
            "7½ h or more": "after nights of 7½ hours or more",
            "Weeknights": "after weeknights", "Weekend nights": "after weekend nights",
        ]
        for d in drivers.prefix(2) {
            guard let phrase = when[d.label] else { continue }
            observations.append("Their HRV is usually \(d.percent < 0 ? "lower" : "higher") \(phrase).")
        }

        let verdict: String, advice: String
        switch level {
        case .below where jumpy || restingUp:
            verdict = "Under strain"
            advice = "Keep the next two or three days easy and give sleep priority, until the average is back in range."
        case .below:
            verdict = "A little low"
            advice = "Go easy today and see where it is tomorrow; one hard session can wait."
        case .within where jumpy:
            verdict = "In range, but jumpy"
            advice = "Train as planned but keep the easy days easy, and watch how it settles."
        case .within:
            verdict = "In balance"
            advice = "The body is handling the training well, so carry on as planned."
        case .above:
            verdict = "Above normal"
            advice = "A good window for a hard session, if the legs agree."
        case nil:
            verdict = "Still learning your normal"
            advice = "Keep wearing the watch at night; after about 60 days there's a normal range to compare with."
        }
        return HRVAssessment(verdict: verdict, reasons: reasons, observations: observations, advice: advice)
    }

    static func hrvFacts(days: [Day], activities: [Activity]) -> String {
        guard let a = hrvAssessment(days: days, activities: activities) else { return "" }
        var lines = ["Topic: heart rate variability (HRV), measured overnight by the watch. Higher than your normal usually means well recovered."]
        lines.append("Verdict: \(a.verdict).")
        lines += a.reasons
        if !a.observations.isEmpty { lines.append("Observations:"); lines += a.observations }
        lines.append("Advice: \(a.advice)")
        return lines.joined(separator: "\n")
    }

    // MARK: Sleep

    struct SleepAssessment {
        let verdict: String
        let reasons: [String]
        let observations: [String]
        let advice: String
    }

    static func sleepAssessment(days: [Day], now: Date = Date()) -> SleepAssessment? {
        let nights = SleepAnalysis.nights(days)
        guard let last = nights.last else { return nil }
        var reasons: [String] = [], observations: [String] = []
        let hm = { (s: Double) in Format.hoursMinutes(Int(s)) }

        if let need = last.need {
            let diff = last.asleep - need
            reasons.append("Last night they slept \(hm(last.asleep)), \(abs(diff) < 15 * 60 ? "about what" : diff < 0 ? "\(hm(-diff)) less than" : "\(hm(diff)) more than") Garmin says they needed.")
        } else {
            reasons.append("Last night they slept \(hm(last.asleep)).")
        }
        let debt = SleepAnalysis.debt(nights, now: now)
        if let debt {
            reasons.append(debt < 30 * 60 ? "Over the last 14 nights there's no sleep debt to speak of." : "Over the last 14 nights they're \(hm(debt)) short in total.")
        }

        // The same 30 days the page shows.
        let monthAgo = Calendar.current.date(byAdding: .day, value: -30, to: Calendar.current.startOfDay(for: now))!
        let recent = nights.filter { $0.date > monthAgo }
        let regularity = SleepAnalysis.regularity(recent)
        if let r = regularity {
            let spread = Int(r.bedtimeSpread.rounded())
            let judgement = spread < 30 ? "very regular" : spread < 60 ? "fairly regular" : "irregular"
            observations.append("Their bedtime is usually around \(SleepAnalysis.clock(r.bedtime)) and is \(judgement) from night to night.")
        }
        let clock = SleepAnalysis.bodyClock(Array(nights.suffix(60)))
        if let c = clock, abs(c.socialJetlag) >= 0.75 {
            observations.append("On weekends they sleep \(hm(abs(c.socialJetlag) * 3600)) \(c.socialJetlag > 0 ? "later" : "earlier") than on weekdays (social jetlag).")
        }
        let shares = SleepAnalysis.stageShares(recent)
        let low = SleepAnalysis.optimal.filter { o in shares[o.stage].map { $0 < o.low } ?? false }.map(\.stage).filter { $0 != "Light" }
        if !low.isEmpty {
            observations.append("\(low.map { $0 == "REM" ? "REM" : $0.lowercased() }.joined(separator: " and ").capitalizedFirst) sleep \(low.count > 1 ? "are" : "is") below the share of the night Garmin calls optimal.")
        }
        let lowStage = low.contains("REM") ? "REM" : low.first

        let verdict: String
        switch debt ?? 0 {
        case ..<(60 * 60): verdict = last.need.map { last.asleep >= $0 - 30 * 60 } ?? true ? "Well rested" : "Short night, solid fortnight"
        case ..<(3 * 3600): verdict = "Running a little short"
        default: verdict = "Short on sleep"
        }
        let advice: String
        if let debt, debt >= 2 * 3600 {
            advice = "Pay some of it back: go to bed 30 to 45 minutes earlier for the next few nights."
        } else if let r = regularity, r.bedtimeSpread >= 60 {
            advice = "Try to fall asleep within half an hour of \(SleepAnalysis.clock(r.bedtime)) every night, weekends too."
        } else if let c = clock, c.socialJetlag >= 1 {
            advice = "On weekends, get up within an hour of the weekday time so Monday feels easier."
        } else if lowStage == "REM" {
            advice = "Most REM sleep comes in the last hours of the night, so protect the end of the night: a steady wake time and enough time in bed."
        } else if lowStage == "Deep" {
            advice = "Deep sleep comes early in the night; a calm last hour before bed and a regular bedtime help it most."
        } else {
            advice = "Keep doing what you're doing."
        }
        return SleepAssessment(verdict: verdict, reasons: reasons, observations: observations, advice: advice)
    }

    static func sleepFacts(days: [Day]) -> String {
        guard let a = sleepAssessment(days: days) else { return "" }
        var lines = ["Topic: their sleep, measured by the watch."]
        lines.append("Verdict: \(a.verdict).")
        lines += a.reasons
        if !a.observations.isEmpty { lines.append("Observations:"); lines += a.observations }
        lines.append("Advice: \(a.advice)")
        return lines.joined(separator: "\n")
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
