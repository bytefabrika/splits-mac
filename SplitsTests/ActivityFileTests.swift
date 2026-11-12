import XCTest
@testable import Splits

/// Activities that weren't recorded as FIT: uploads from other apps (TCX, GPX) and ones entered by hand (no file).
/// Coordinates are made up.
final class ActivityFileTests: XCTestCase {
    /// A ZIP with each file stored uncompressed, like the ones Garmin sends for small files.
    private func zip(_ files: [(String, Data)]) -> Data {
        var out = Data(), central = Data()
        func u16(_ v: Int) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)]) }
        func u32(_ v: Int) -> Data { u16(v & 0xFFFF) + u16(v >> 16 & 0xFFFF) }
        for (name, data) in files {
            let offset = out.count
            let n = Data(name.utf8)
            out += u32(0x0403_4B50) + u16(20) + u16(0) + u16(0) + u16(0) + u16(0) + u32(0)
            out += u32(data.count) + u32(data.count) + u16(n.count) + u16(0) + n + data
            central += u32(0x0201_4B50) + u16(20) + u16(20) + u16(0) + u16(0) + u16(0) + u16(0) + u32(0)
            central += u32(data.count) + u32(data.count) + u16(n.count) + u16(0) + u16(0) + u16(0) + u16(0)
            central += u32(0) + u32(offset) + n
        }
        let start = out.count
        out += central
        out += u32(0x0605_4B50) + u16(0) + u16(0) + u16(files.count) + u16(files.count) + u32(central.count) + u32(start) + u16(0)
        return out
    }

    private let tcx = Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2" xmlns:ns3="http://www.garmin.com/xmlschemas/ActivityExtension/v2">
      <Activities><Activity Sport="Running"><Id>2026-05-01T08:00:00Z</Id>
        <Lap StartTime="2026-05-01T08:00:00Z">
          <TotalTimeSeconds>300.0</TotalTimeSeconds><DistanceMeters>1000.0</DistanceMeters><Calories>70</Calories>
          <AverageHeartRateBpm><Value>150</Value></AverageHeartRateBpm><MaximumHeartRateBpm><Value>162</Value></MaximumHeartRateBpm>
          <Track>
            <Trackpoint><Time>2026-05-01T08:00:00Z</Time><Position><LatitudeDegrees>45.0</LatitudeDegrees><LongitudeDegrees>7.0</LongitudeDegrees></Position>
              <AltitudeMeters>200</AltitudeMeters><DistanceMeters>0</DistanceMeters><HeartRateBpm><Value>140</Value></HeartRateBpm>
              <Extensions><ns3:TPX><ns3:Speed>3.3</ns3:Speed><ns3:RunCadence>85</ns3:RunCadence></ns3:TPX></Extensions></Trackpoint>
            <Trackpoint><Time>2026-05-01T08:05:00.000Z</Time><Position><LatitudeDegrees>45.009</LatitudeDegrees><LongitudeDegrees>7.0</LongitudeDegrees></Position>
              <DistanceMeters>1000</DistanceMeters><HeartRateBpm><Value>160</Value></HeartRateBpm></Trackpoint>
          </Track>
        </Lap>
      </Activity></Activities>
    </TrainingCenterDatabase>
    """.utf8)

    private let gpx = Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <gpx version="1.1" creator="Some app" xmlns="http://www.topografix.com/GPX/1/1" xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1">
      <trk><name>Morning Run</name><trkseg>
        <trkpt lat="45.0" lon="7.0"><ele>200</ele><time>2026-05-01T08:00:00Z</time>
          <extensions><gpxtpx:TrackPointExtension><gpxtpx:hr>141</gpxtpx:hr><gpxtpx:cad>84</gpxtpx:cad></gpxtpx:TrackPointExtension></extensions></trkpt>
        <trkpt lat="45.009" lon="7.0"><ele>205</ele><time>2026-05-01T08:05:00Z</time></trkpt>
      </trkseg></trk>
    </gpx>
    """.utf8)

    func testTCX() throws {
        let track = try ActivityFile.decode(tcx)
        XCTAssertEqual(track.points.count, 2)
        let first = track.points[0]
        XCTAssertEqual(first.coordinate!.latitude, 45.0, accuracy: 1e-9)
        XCTAssertEqual(first.heartRate, 140)
        XCTAssertEqual(first.cadence, 85)
        XCTAssertEqual(first.speed, 3.3)
        XCTAssertEqual(first.altitude, 200)
        XCTAssertEqual(track.points[1].distance, 1000)
        XCTAssertEqual(track.points[1].time.timeIntervalSince(first.time), 300)
        XCTAssertEqual(track.laps.count, 1)
        XCTAssertEqual(track.laps[0].distance, 1000)
        XCTAssertEqual(track.laps[0].averageHR, 150)
        XCTAssertEqual(track.laps[0].averageSpeed!, 1000 / 300.0, accuracy: 1e-9)
    }

    func testGPXAddsUpDistance() throws {
        let track = try ActivityFile.decode(gpx)
        XCTAssertEqual(track.points.count, 2)
        XCTAssertEqual(track.points[0].heartRate, 141)
        XCTAssertEqual(track.points[0].cadence, 84)
        XCTAssertEqual(track.points[0].distance, 0)
        XCTAssertEqual(track.points[1].distance!, 1000, accuracy: 5, "0.009° of latitude is about a kilometre")
        XCTAssertTrue(track.hasRoute)
        XCTAssertFalse(TrackAnalysis(track).route.isEmpty)
    }

    func testUnpackPrefersFITThenTCXThenGPX() throws {
        let fit = Data([14, 0x10, 0, 0, 0, 0, 0, 0, 0x2E, 0x46, 0x49, 0x54, 0, 0])
        XCTAssertEqual(try ActivityFile.unpack(zip([("a.gpx", gpx), ("a.fit", fit)])), fit)
        XCTAssertEqual(try ActivityFile.unpack(zip([("a.gpx", gpx), ("a.tcx", tcx)])), tcx)
        XCTAssertEqual(try ActivityFile.unpack(zip([("a.gpx", gpx)])), gpx)
    }

    /// The bug a user hit: the download had no FIT in it, and the page showed "Splits.FIT.Failure error 0".
    func testNoFileSaysSoInWords() {
        XCTAssertThrowsError(try ActivityFile.unpack(zip([]))) { error in
            guard case ActivityFile.Failure.noFile = error else { return XCTFail("\(error)") }
            XCTAssertTrue(error.localizedDescription.contains("entered by hand"))
        }
        XCTAssertThrowsError(try ActivityFile.decode(Data())) { error in
            guard case ActivityFile.Failure.noFile = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try ActivityFile.decode(Data("not a file".utf8))) { error in
            XCTAssertFalse(error.localizedDescription.contains("error 0"))
        }
    }
}
