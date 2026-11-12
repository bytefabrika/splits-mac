import CoreLocation
import Foundation

/// The file behind an activity, whatever its format. Garmin's download is the original upload: a FIT file for
/// anything a watch recorded, but a TCX or GPX file for an activity uploaded from another app or site, and
/// nothing at all for one entered by hand.
enum ActivityFile {
    enum Failure: LocalizedError {
        case noFile
        case unknownFormat

        var errorDescription: String? {
            switch self {
            case .noFile: "There's no recorded file for this activity, so no route or laps. Activities entered by hand don't have one."
            case .unknownFormat: "The file for this activity isn't in a format Splits can read (FIT, TCX or GPX)."
            }
        }
    }

    enum Format { case fit, tcx, gpx }

    /// The file to keep from a download: the FIT, TCX or GPX inside Garmin's ZIP (in that order of preference),
    /// or the download itself when it isn't a ZIP.
    static func unpack(_ download: Data) throws -> Data {
        // "PK" then 3 4 for a ZIP with files, 5 6 for an empty one.
        guard download.prefix(2) == Data([0x50, 0x4B]) else {
            guard !download.isEmpty else { throw Failure.noFile }
            return download
        }
        let entries = try Zip.entries(download)
        for suffix in [".fit", ".tcx", ".gpx"] {
            if let entry = entries.first(where: { $0.name.lowercased().hasSuffix(suffix) }), !entry.data.isEmpty {
                return entry.data
            }
        }
        throw Failure.noFile
    }

    static func format(of data: Data) -> Format? {
        let b = [UInt8](data.prefix(12))
        if b.count == 12, b[8] == 0x2E, b[9] == 0x46, b[10] == 0x49, b[11] == 0x54 { return .fit }
        let head = String(decoding: data.prefix(4096), as: UTF8.self)
        if head.contains("<TrainingCenterDatabase") { return .tcx }
        if head.contains("<gpx") { return .gpx }
        return nil
    }

    static func decode(_ data: Data) throws -> Track {
        switch format(of: data) {
        case .fit: return try FIT.decode(data)
        case .tcx, .gpx: return try XMLTrack.decode(data)
        case nil: throw data.isEmpty ? Failure.noFile : Failure.unknownFormat
        }
    }
}

/// TCX (Garmin's Training Center format: laps and track points) and GPX (track points, with heart rate, cadence,
/// temperature and power in the usual extensions). Element names are matched without their namespace prefix.
enum XMLTrack {
    static func decode(_ data: Data) throws -> Track {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse() else { throw ActivityFile.Failure.unknownFormat }
        var track = reader.track
        track.points.sort { $0.time < $1.time }
        fillDistances(&track)
        return track
    }

    /// GPX has no distance per point: add it up from the coordinates, so splits and bests work.
    static func fillDistances(_ track: inout Track) {
        guard !track.points.isEmpty, track.points.allSatisfy({ $0.distance == nil }), track.hasRoute else { return }
        var total = 0.0
        var previous: CLLocation?
        for i in track.points.indices {
            if let c = track.points[i].coordinate {
                let here = CLLocation(latitude: c.latitude, longitude: c.longitude)
                if let previous { total += here.distance(from: previous) }
                previous = here
            }
            track.points[i].distance = total
        }
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var track = Track()
        private var stack: [String] = []
        private var text = ""
        private var point: TrackPoint?
        private var pointTime: Date?
        private var latitude: Double?
        private var lap: Lap?

        private static let isoFractional: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()
        private static let iso = ISO8601DateFormatter()
        static func date(_ s: String) -> Date? { isoFractional.date(from: s) ?? iso.date(from: s) }

        private static func local(_ name: String) -> String { name.split(separator: ":").last.map(String.init) ?? name }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            let element = Self.local(name)
            stack.append(element)
            text = ""
            switch element {
            case "Trackpoint", "trkpt":
                point = TrackPoint(time: .distantPast)
                pointTime = nil
                latitude = nil
                if let lat = attributes["lat"].flatMap(Double.init), let lon = attributes["lon"].flatMap(Double.init) {
                    point?.coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                }
            case "Lap":
                lap = Lap()
                lap?.start = attributes["StartTime"].flatMap(Self.date)
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let element = Self.local(name)
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let number = Double(value)
            let parent = stack.count >= 2 ? stack[stack.count - 2] : ""
            defer { stack.removeLast(); text = "" }

            if point != nil {
                switch (element, parent) {
                case ("Time", _), ("time", _): pointTime = Self.date(value)
                case ("LatitudeDegrees", _): latitude = number
                case ("LongitudeDegrees", _):
                    if let lat = latitude, let lon = number { point?.coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon) }
                case ("AltitudeMeters", _), ("ele", _): point?.altitude = number
                case ("DistanceMeters", "Trackpoint"): point?.distance = number
                case ("Value", "HeartRateBpm"), ("hr", _), ("heartrate", _): point?.heartRate = number
                case ("Cadence", "Trackpoint"), ("RunCadence", _), ("cad", _), ("cadence", _): point?.cadence = number
                case ("Speed", _), ("speed", _): point?.speed = number
                case ("Watts", _), ("power", _), ("PowerInWatts", _): point?.power = number
                case ("atemp", _), ("temp", _): point?.temperature = number
                case ("Trackpoint", _), ("trkpt", _):
                    if var p = point, let time = pointTime {
                        p.time = time
                        track.points.append(p)
                    }
                    point = nil
                default: break
                }
                return
            }

            guard lap != nil else { return }
            switch (element, parent) {
            case ("TotalTimeSeconds", "Lap"): lap?.elapsed = number
            case ("DistanceMeters", "Lap"): lap?.distance = number
            case ("Calories", "Lap"): lap?.calories = number
            case ("Value", "AverageHeartRateBpm"): lap?.averageHR = number
            case ("Value", "MaximumHeartRateBpm"): lap?.maxHR = number
            case ("AvgSpeed", _): lap?.averageSpeed = number
            case ("AvgWatts", _): lap?.averagePower = number
            case ("Lap", _):
                if var l = lap {
                    if l.averageSpeed == nil, let d = l.distance, let t = l.elapsed, t > 0 { l.averageSpeed = d / t }
                    track.laps.append(l)
                }
                lap = nil
            default: break
            }
        }
    }
}
