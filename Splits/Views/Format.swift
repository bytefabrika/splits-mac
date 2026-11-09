import Foundation

/// Numbers the way the user's Garmin profile shows them: kilometres or miles.
struct Format {
    let imperial: Bool

    init(units: String) { imperial = units == "statute_us" }

    func distance(_ metres: Double, decimals: Int = 2) -> String {
        let value = imperial ? metres / 1609.344 : metres / 1000
        return "\(value.formatted(.number.precision(.fractionLength(decimals)))) \(imperial ? "mi" : "km")"
    }

    func distanceValue(_ metres: Double) -> Double { imperial ? metres / 1609.344 : metres / 1000 }
    var distanceUnit: String { imperial ? "mi" : "km" }

    func elevation(_ metres: Double) -> String {
        imperial ? "\(Int((metres / 0.3048).rounded())) ft" : "\(Int(metres.rounded())) m"
    }

    /// Pace per km or mile: "5:12 /km".
    func pace(secondsPerKm: Double) -> String {
        let seconds = Int((imperial ? secondsPerKm * 1.609344 : secondsPerKm).rounded())
        return String(format: "%d:%02d /%@", seconds / 60, seconds % 60, imperial ? "mi" : "km")
    }

    func speed(metresPerSecond: Double) -> String {
        let value = imperial ? metresPerSecond * 2.236936 : metresPerSecond * 3.6
        return "\(value.formatted(.number.precision(.fractionLength(1)))) \(imperial ? "mph" : "km/h")"
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "7 h 12 min".
    static func hoursMinutes(_ seconds: Int) -> String {
        let minutes = (seconds + 30) / 60
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }

    static func title(_ key: String?) -> String {
        guard let key else { return "–" }
        return key.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
