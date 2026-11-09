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
    """

    /// Streams the take. `onText` gets the text so far, on the main actor.
    @MainActor
    static func write(facts: String, onText: @escaping (String) -> Void) async throws {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            let session = LanguageModelSession(model: .default, instructions: instructions)
            let stream = session.streamResponse(to: facts, options: GenerationOptions(temperature: 0.6))
            for try await snapshot in stream {
                onText(snapshot.content)
            }
            return
        }
        #endif
        throw CocoaError(.featureUnsupported)
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
        lines.append("Moving time: \(Format.duration(activity.movingDuration)) (elapsed \(Format.duration(activity.duration)))")
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
}
