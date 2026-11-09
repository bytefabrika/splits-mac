import CoreLocation
import XCTest
@testable import Splits

final class RouteTests: XCTestCase {
    func testThinKeepsAPointEveryFifteenMetres() {
        // 1 km due north, a point every metre.
        let points = (0...1000).map { CLLocationCoordinate2D(latitude: 52 + Double($0) / 111_320, longitude: 5) }
        let thin = RouteStore.thin(points)
        // About one every 15 m (rounding can push a gap to 16 m), plus the first and last points.
        XCTAssertTrue((60...70).contains(thin.count), "\(thin.count)")
        XCTAssertEqual(thin.first?.latitude, points.first?.latitude)
        XCTAssertEqual(thin.last?.latitude, points.last?.latitude)
    }

    func testEncodeRoundTrip() {
        let points = [CLLocationCoordinate2D(latitude: 52.0907, longitude: 5.1214), .init(latitude: -33.8688, longitude: 151.2093)]
        let back = RouteStore.decode(RouteStore.encode(points))
        XCTAssertEqual(back.count, 2)
        XCTAssertEqual(back[1].latitude, -33.8688, accuracy: 0.0001)
        XCTAssertEqual(back[1].longitude, 151.2093, accuracy: 0.0001)
        XCTAssertTrue(RouteStore.decode(Data()).isEmpty)
    }
}
