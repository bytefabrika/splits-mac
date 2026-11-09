import XCTest
@testable import Splits

final class FITTests: XCTestCase {
    /// Builds a little FIT file: one record definition (timestamp, lat, long, heart rate, distance), then records.
    /// `points` are (seconds after start, heart rate or nil, metres). Every third record uses a compressed timestamp.
    private func fitFile(points: [(Int, UInt8?, Double)], start: UInt32 = 1_000_000_000) -> Data {
        var body: [UInt8] = []
        func u32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)] }
        // Definition, local type 0, little endian, global 20 (record), 5 fields.
        body += [0x40, 0, 0, 20, 0, 5,
                 253, 4, 0x86,  // timestamp uint32
                 0, 4, 0x85,    // position_lat sint32
                 1, 4, 0x85,    // position_long sint32
                 3, 1, 0x02,    // heart_rate uint8
                 5, 4, 0x86]    // distance uint32, cm
        let semicircles = Int32(52.09 * 2_147_483_648.0 / 180.0)
        for (i, point) in points.enumerated() {
            let ts = start + UInt32(point.0)
            let compressed = i % 3 == 2 && point.0 - points[i - 1].0 < 31
            if compressed {
                body.append(0x80 | UInt8(ts & 0x1F))  // compressed header, local type 0
            } else {
                body.append(0x00)
            }
            if !compressed { body += u32(ts) } else { body += u32(0xFFFF_FFFF) }  // invalid timestamp field: use the header's
            body += u32(UInt32(bitPattern: semicircles)) + u32(UInt32(bitPattern: semicircles / 2))
            body.append(point.1 ?? 0xFF)
            body += u32(UInt32(point.2 * 100))
        }
        var header: [UInt8] = [14, 0x10, 0xAD, 0x52] + u32(UInt32(body.count)) + Array(".FIT".utf8) + [0, 0]
        header += body
        return Data(header + [0, 0])  // file CRC, not checked
    }

    func testDecodesRecordsAndCompressedTimestamps() throws {
        let points: [(Int, UInt8?, Double)] = [(0, 120, 0), (1, 121, 3), (2, 122, 6), (3, nil, 9), (4, 125, 12), (5, 126, 15)]
        let track = try FIT.decode(fitFile(points: points))
        XCTAssertEqual(track.points.count, 6)
        XCTAssertEqual(track.points.map { Int($0.time.timeIntervalSince(track.points[0].time)) }, [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(track.points[0].time, Date(timeIntervalSince1970: 1_000_000_000 + FIT.epochOffset))
        XCTAssertEqual(track.points[1].heartRate, 121)
        XCTAssertNil(track.points[3].heartRate, "0xFF is FIT's invalid uint8")
        XCTAssertEqual(track.points[5].distance, 15)
        XCTAssertEqual(track.points[0].coordinate?.latitude ?? 0, 52.09, accuracy: 0.0001)
        XCTAssertTrue(track.hasRoute)
    }

    func testRejectsOtherFiles() {
        XCTAssertThrowsError(try FIT.decode(Data("not a fit file at all".utf8)))
    }

    func testSplitsAndFastestStretch() throws {
        // 3.5 km: the first km at 5:00, the second at 3:20, the third at 6:40, then 500 m. (Whole seconds per 10 m.)
        var points: [(Int, UInt8?, Double)] = []
        var t = 0, d = 0.0
        for (km, secondsPerKm) in [(1, 300), (2, 200), (3, 400), (4, 300)] {
            let metres = km == 4 ? 500.0 : 1000.0
            let steps = Int(metres / 10)
            for _ in 0..<steps {
                t += secondsPerKm / 100
                d += 10
                points.append((t, 140, d))
            }
        }
        let track = try FIT.decode(fitFile(points: [(0, 140, 0)] + points))
        let analysis = TrackAnalysis(track)
        XCTAssertEqual(analysis.splits.count, 4)
        XCTAssertEqual(analysis.splits[0].seconds, 300, accuracy: 4)
        XCTAssertEqual(analysis.splits[1].seconds, 200, accuracy: 4)
        XCTAssertEqual(analysis.splits[3].length, 500, accuracy: 15)
        XCTAssertEqual(analysis.bests.first { $0.id == "1 km" }?.seconds ?? 0, 200, accuracy: 4)
        XCTAssertNil(analysis.bests.first { $0.id == "5 km" }, "too short")
        XCTAssertFalse(analysis.route.isEmpty)
    }

    func testSportsFromGarminKeys() {
        XCTAssertEqual(Sport(typeKey: "paddelball"), .racket)
        XCTAssertEqual(Sport(typeKey: "virtual_ride"), .ride)
        XCTAssertEqual(Sport(typeKey: "treadmill_running"), .run)
        XCTAssertEqual(Sport(typeKey: "lap_swimming"), .swim)
        XCTAssertEqual(Sport(typeKey: "resort_skiing_snowboarding_ws"), .snow)
        XCTAssertEqual(Sport(typeKey: "kayaking_v2"), .water)
        XCTAssertTrue(Sport.isIndoor("indoor_cycling"))
        XCTAssertFalse(Sport.isIndoor("road_biking"))
    }
}
