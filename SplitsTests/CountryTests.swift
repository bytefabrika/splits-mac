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
        // Per year: the Netherlands had 2 runs in 2025 and 1 in 2026, 3 in all.
        let nl = t.visits[0].country.id
        XCTAssertEqual(t.countryYears[2025]?[nl]?.count, 2)
        XCTAssertEqual(t.countryYears[2026]?[nl]?.count, 1)
        XCTAssertEqual(t.countryYears[2026]?[nl]?.distance, 10_000)
        XCTAssertNil(t.countryYears[2026]?[t.visits[1].country.id])  // no Turkey in 2026
    }
}

final class CityTests: XCTestCase {
    let cities = CityAtlas()

    func testCities() {
        XCTAssertEqual(cities.city(lat: 52.0908, lon: 5.1222, iso: "NL")?.name, "Utrecht")
        XCTAssertEqual(cities.city(lat: 52.0817, lon: 5.0361, iso: "NL")?.name, "Utrecht")      // De Meern, inside Utrecht's reach
        XCTAssertEqual(cities.city(lat: 52.3812, lon: 4.6368, iso: "NL")?.name, "Haarlem")      // not swallowed by Amsterdam
        XCTAssertEqual(cities.city(lat: 41.0227, lon: 29.0137, iso: "TR")?.name, "Istanbul")    // Kadıköy
        XCTAssertNotEqual(cities.city(lat: 45.43, lon: 13.53, iso: "HR")?.iso, "SI")            // Istria stays in Croatia
        XCTAssertNil(cities.city(lat: 46.0, lon: 7.85, iso: "CH"))                             // high in the Alps
    }
}

final class MegacityTests: XCTestCase {
    func testDistrictsCountAsTheCity() {
        let cities = CityAtlas()
        XCTAssertEqual(cities.city(lat: 41.027, lon: 28.6773, iso: "TR")?.name, "Istanbul")  // Esenyurt
        XCTAssertEqual(cities.city(lat: 52.1561, lon: 5.3878, iso: "NL")?.name, "Amersfoort")  // not Utrecht
    }
}
