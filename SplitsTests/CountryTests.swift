import XCTest
@testable import Splits

final class CountryTests: XCTestCase {
    let atlas = Atlas(data: try! Data(contentsOf: Bundle(for: Atlas.self).url(forResource: "countries", withExtension: "json")!))

    func testPlaces() {
        XCTAssertEqual(atlas.country(lat: 52.37, lon: 4.90)?.iso, "NL")   // Amsterdam
        XCTAssertEqual(atlas.country(lat: 41.01, lon: 28.98)?.iso, "TR")  // Istanbul, European side
        XCTAssertEqual(atlas.country(lat: 40.99, lon: 29.03)?.iso, "TR")  // Kadıköy, Asian side
        XCTAssertEqual(atlas.country(lat: 48.86, lon: 2.35)?.iso, "FR")   // Paris
        XCTAssertEqual(atlas.country(lat: 49.61, lon: 6.13)?.iso, "LU")   // Luxembourg
        XCTAssertEqual(atlas.country(lat: -29.31, lon: 27.48)?.iso, "LS") // Maseru, inside South Africa
        XCTAssertEqual(atlas.country(lat: 52.10, lon: 4.27)?.iso, "NL")   // Scheveningen beach
        XCTAssertNil(atlas.country(lat: 0, lon: -30))                     // mid-Atlantic
        XCTAssertEqual(atlas.country(lat: 52.37, lon: 4.90)?.flag, "🇳🇱")
    }

    func testTravels() {
        func point(_ day: String, _ lat: Double, _ lon: Double) -> Travels.Point {
            Travels.Point(id: 0, start: GarminDate.day(day)!, lat: lat, lon: lon, distance: 10_000)
        }
        let t = Travels(points: [
            point("2025-03-01", 52.37, 4.90), point("2025-05-01", 41.01, 28.98), point("2025-06-01", 52.37, 4.90),
            point("2026-01-01", 52.37, 4.90), point("2026-02-01", 48.86, 2.35),
        ], atlas: atlas)
        XCTAssertEqual(t.visits.map(\.country.iso), ["NL", "TR", "FR"])
        XCTAssertEqual(t.visits.first?.count, 3)
        XCTAssertEqual(t.legs.count, 3)
        XCTAssertEqual(t.years.map(\.year), [2026, 2025])
        XCTAssertEqual(t.years[0].countries.map(\.iso), ["NL", "FR"])
        XCTAssertEqual(t.years[0].new.map(\.iso), ["FR"])
    }
}
