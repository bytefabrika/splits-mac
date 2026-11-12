import CoreLocation
import Foundation

/// One second (or so) of an activity, from the FIT file's record messages.
struct TrackPoint {
    var time: Date
    var coordinate: CLLocationCoordinate2D?
    var altitude: Double?     // m
    var heartRate: Double?    // bpm
    var cadence: Double?      // rpm, or steps per minute per foot for running
    var distance: Double?     // m from the start
    var speed: Double?        // m/s
    var power: Double?        // W
    var temperature: Double?  // °C
}

struct Lap {
    var start: Date?
    var elapsed: Double?   // s
    var moving: Double?    // s
    var distance: Double?  // m
    var averageSpeed: Double?
    var averageHR: Double?
    var maxHR: Double?
    var ascent: Double?
    var averagePower: Double?
    var calories: Double?
}

struct Track {
    var points: [TrackPoint] = []
    var laps: [Lap] = []

    var hasRoute: Bool { points.contains { $0.coordinate != nil } }
}

/// A small FIT decoder: definition and data messages, both byte orders, compressed timestamps and developer
/// fields (skipped). Reads record (20) and lap (19) messages, the rest is ignored.
/// Spec: FIT protocol, garmin.com/fit. Invalid values (all bits set for the type) become nil.
enum FIT {
    enum Failure: LocalizedError {
        case notFIT, truncated
        var errorDescription: String? {
            switch self {
            case .notFIT: "The activity file isn't a FIT file."
            case .truncated: "The activity file is cut short."
            }
        }
    }

    private struct FieldDef { let number: UInt8; let size: Int; let baseType: UInt8 }
    private struct Definition { let global: UInt16; let bigEndian: Bool; let fields: [FieldDef]; let devSize: Int }

    /// Seconds between the Unix epoch and the FIT epoch (1989-12-31 00:00 UTC).
    static let epochOffset: TimeInterval = 631_065_600

    static func decode(_ data: Data) throws -> Track {
        let b = [UInt8](data)
        guard b.count >= 12 else { throw Failure.notFIT }
        let headerSize = Int(b[0])
        guard headerSize >= 12, b.count >= headerSize, b[8] == 0x2E, b[9] == 0x46, b[10] == 0x49, b[11] == 0x54 else {
            throw Failure.notFIT
        }
        let dataSize = Int(b[4]) | Int(b[5]) << 8 | Int(b[6]) << 16 | Int(b[7]) << 24
        let end = min(headerSize + dataSize, b.count)

        var definitions: [UInt8: Definition] = [:]
        var lastTimestamp: UInt32 = 0
        var track = Track()
        var p = headerSize

        while p < end {
            let header = b[p]
            p += 1
            if header & 0x80 != 0 {
                // Compressed timestamp header: a data message with a 5-bit time offset.
                let local = (header >> 5) & 0x03
                let offset = UInt32(header & 0x1F)
                var timestamp = (lastTimestamp & ~0x1F) + offset
                if offset < (lastTimestamp & 0x1F) { timestamp += 0x20 }
                lastTimestamp = timestamp
                guard let def = definitions[local] else { throw Failure.truncated }
                p = try readData(b, at: p, end: end, def: def, timestamp: timestamp, last: &lastTimestamp, into: &track)
            } else if header & 0x40 != 0 {
                // Definition message.
                let local = header & 0x0F
                let hasDev = header & 0x20 != 0
                guard p + 5 <= end else { throw Failure.truncated }
                let bigEndian = b[p + 1] == 1
                let global = bigEndian ? UInt16(b[p + 2]) << 8 | UInt16(b[p + 3]) : UInt16(b[p + 3]) << 8 | UInt16(b[p + 2])
                let count = Int(b[p + 4])
                p += 5
                guard p + count * 3 <= end else { throw Failure.truncated }
                var fields: [FieldDef] = []
                for i in 0..<count {
                    fields.append(FieldDef(number: b[p + i * 3], size: Int(b[p + i * 3 + 1]), baseType: b[p + i * 3 + 2]))
                }
                p += count * 3
                var devSize = 0
                if hasDev {
                    guard p < end else { throw Failure.truncated }
                    let devCount = Int(b[p])
                    p += 1
                    guard p + devCount * 3 <= end else { throw Failure.truncated }
                    for i in 0..<devCount { devSize += Int(b[p + i * 3 + 1]) }
                    p += devCount * 3
                }
                definitions[local] = Definition(global: global, bigEndian: bigEndian, fields: fields, devSize: devSize)
            } else {
                guard let def = definitions[header & 0x0F] else { throw Failure.truncated }
                p = try readData(b, at: p, end: end, def: def, timestamp: nil, last: &lastTimestamp, into: &track)
            }
        }
        return track
    }

    private static func readData(_ b: [UInt8], at start: Int, end: Int, def: Definition, timestamp: UInt32?,
                                 last: inout UInt32, into track: inout Track) throws -> Int {
        var p = start
        var values: [UInt8: Double] = [:]
        let wanted = def.global == 20 || def.global == 19
        for field in def.fields {
            guard p + field.size <= end else { throw Failure.truncated }
            if wanted || field.number == 253, let value = number(b, at: p, size: field.size, type: field.baseType, bigEndian: def.bigEndian) {
                values[field.number] = value
            }
            p += field.size
        }
        p += def.devSize
        guard p <= end else { throw Failure.truncated }

        if let ts = values[253] { last = UInt32(ts) }
        let time = Date(timeIntervalSince1970: Double(values[253].map { UInt32($0) } ?? timestamp ?? last) + epochOffset)

        switch def.global {
        case 20:
            var point = TrackPoint(time: time)
            if let lat = values[0], let lon = values[1] {
                let scale = 180.0 / 2_147_483_648.0
                point.coordinate = CLLocationCoordinate2D(latitude: lat * scale, longitude: lon * scale)
            }
            point.altitude = (values[78] ?? values[2]).map { $0 / 5 - 500 }
            point.heartRate = values[3]
            point.cadence = values[4]
            point.distance = values[5].map { $0 / 100 }
            point.speed = (values[73] ?? values[6]).map { $0 / 1000 }
            point.power = values[7]
            point.temperature = values[13]
            track.points.append(point)
        case 19:
            var lap = Lap()
            lap.start = values[2].map { Date(timeIntervalSince1970: $0 + epochOffset) }
            lap.elapsed = values[7].map { $0 / 1000 }
            lap.moving = values[8].map { $0 / 1000 }
            lap.distance = values[9].map { $0 / 100 }
            lap.averageSpeed = (values[110] ?? values[13]).map { $0 / 1000 }
            lap.averageHR = values[15]
            lap.maxHR = values[16]
            lap.ascent = values[21]
            lap.averagePower = values[19]
            lap.calories = values[11]
            track.laps.append(lap)
        default:
            break
        }
        return p
    }

    /// One numeric field, or nil if it's FIT's "invalid" value for its type. Arrays and strings are skipped.
    private static func number(_ b: [UInt8], at p: Int, size: Int, type: UInt8, bigEndian: Bool) -> Double? {
        let base = type & 0x1F
        func unsigned(_ n: Int) -> UInt64 {
            var v: UInt64 = 0
            for i in 0..<n { v |= UInt64(b[p + (bigEndian ? n - 1 - i : i)]) << (8 * UInt64(i)) }
            return v
        }
        switch (base, size) {
        case (0x00, 1), (0x02, 1), (0x0A, 1), (0x0D, 1):  // enum, uint8, uint8z, byte
            let v = b[p]
            return (base == 0x0A ? v == 0 : v == 0xFF) ? nil : Double(v)
        case (0x01, 1):  // sint8
            let v = Int8(bitPattern: b[p])
            return v == 0x7F ? nil : Double(v)
        case (0x04, 2), (0x0B, 2):  // uint16, uint16z
            let v = UInt16(unsigned(2))
            return (base == 0x0B ? v == 0 : v == 0xFFFF) ? nil : Double(v)
        case (0x03, 2):  // sint16
            let v = Int16(bitPattern: UInt16(unsigned(2)))
            return v == 0x7FFF ? nil : Double(v)
        case (0x06, 4), (0x0C, 4):  // uint32, uint32z
            let v = UInt32(unsigned(4))
            return (base == 0x0C ? v == 0 : v == 0xFFFF_FFFF) ? nil : Double(v)
        case (0x05, 4):  // sint32
            let v = Int32(bitPattern: UInt32(unsigned(4)))
            return v == 0x7FFF_FFFF ? nil : Double(v)
        case (0x08, 4):  // float32
            let v = Float(bitPattern: UInt32(unsigned(4)))
            return v.isNaN ? nil : Double(v)
        default:
            return nil
        }
    }
}
