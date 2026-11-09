import CoreLocation
import SwiftData
import SwiftUI
import XCTest
@testable import Splits

/// Draws the activity screen's charts and cards off-screen, so a crash in a view body (like a reversed range)
/// fails a test instead of the app.
@MainActor
final class ViewRenderTests: XCTestCase {
    private func analysis(paceSecondsPerKm: Double, km: Int = 6) -> TrackAnalysis {
        var points: [TrackPoint] = []
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let speed = 1000 / paceSecondsPerKm
        for second in 0..<(km * Int(paceSecondsPerKm)) {
            let wobble = sin(Double(second) / 40)
            points.append(TrackPoint(
                time: start.addingTimeInterval(Double(second)),
                coordinate: .init(latitude: 52.09 + Double(second) * 0.00002, longitude: 5.12 + wobble * 0.001),
                altitude: 5 + wobble * 3,
                heartRate: 130 + Double(second % 300) / 10,
                cadence: 80 + wobble * 3,
                distance: Double(second) * speed,
                speed: second == 0 ? 0.2 : speed * (1 + wobble * 0.1),  // a standing start, like a real file
                power: 250 + wobble * 30,
                temperature: 14
            ))
        }
        return TrackAnalysis(Track(points: points, laps: []))
    }

    private func activity(_ typeKey: String) -> Activity {
        let a = Activity(garminId: 1)
        a.typeKey = typeKey
        a.distance = 6000
        a.movingDuration = 1800
        a.duration = 1900
        a.averageSpeed = 3.3
        a.averageHR = 145
        a.maxHR = 160
        a.hrZones = [60, 300, 900, 400, 140]
        a.aerobicEffect = 3.4
        return a
    }

    private func render<V: View>(_ view: V, imperial: Bool = false) {
        let renderer = ImageRenderer(content: view.environment(\.format, Format(units: imperial ? "statute_us" : "metric"))
            .frame(width: 900))
        XCTAssertNotNil(renderer.nsImage)
    }

    func testRunCharts() {
        let a = analysis(paceSecondsPerKm: 330)
        render(TrackCharts(analysis: a, activity: activity("running"), zoneFloors: [119, 144, 158, 166, 174],
                           isPaceSport: true, selectedKm: .constant(2.5)))
        render(SplitsCard(analysis: a, sport: .run, isPaceSport: true))
        render(BestsCard(analysis: a))
        render(ZonesCard(activity: activity("running"), floors: [119, 144, 158, 166, 174]))
        render(EffectCard(activity: activity("running")))
    }

    func testRideChartsAndMiles() {
        let a = analysis(paceSecondsPerKm: 110, km: 20)
        render(TrackCharts(analysis: a, activity: activity("road_biking"), zoneFloors: [], isPaceSport: false,
                           selectedKm: .constant(nil)), imperial: true)
        render(SplitsCard(analysis: a, sport: .ride, isPaceSport: false), imperial: true)
    }

    func testStatGroupsWithAndWithoutDetail() throws {
        let json = """
        {"summaryDTO": {"avgGradeAdjustedSpeed": 2.3, "waterEstimated": 900, "differenceBodyBattery": -12,
         "beginPotentialStamina": 97, "endPotentialStamina": 60, "strideLength": 89, "groundContactTime": 300,
         "normalizedPower": 330, "vigorousIntensityMinutes": 20, "directWorkoutFeel": 75, "directWorkoutRpe": 60},
         "locationName": "Utrecht"}
        """
        let detail = try JSONDecoder().decode(ActivityDetailDTO.self, from: Data(json.utf8))
        render(StatGroups(activity: activity("running"), detail: detail.summaryDTO, isPaceSport: true))
        render(StatGroups(activity: activity("strength_training"), detail: nil, isPaceSport: false))
    }
}

@MainActor
final class ShareCardTests: XCTestCase {
    func testCardRendersAtInstagramSize() throws {
        let a = Activity(garminId: 7)
        a.typeKey = "running"
        a.name = "Sunday long run"
        a.distance = 21_100
        a.movingDuration = 7_000
        a.elevationGain = 85
        let route = (0..<200).map { i in
            CLLocationCoordinate2D(latitude: 52.09 + sin(Double(i) / 30) * 0.01, longitude: 5.12 + Double(i) * 0.0002)
        }
        let png = try XCTUnwrap(ShareCard.png(activity: a, route: route, format: Format(units: "metric")))
        let image = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(image.pixelsWide, 1080)
        XCTAssertEqual(image.pixelsHigh, 1350)
        // Without a route (an indoor session) it still draws.
        XCTAssertNotNil(ShareCard.png(activity: a, route: [], format: Format(units: "metric")))
    }
}

@MainActor
final class YearStoryTests: XCTestCase {
    func testStatsAndStoryDraw() {
        let calendar = Calendar.current
        var activities: [Activity] = []
        for i in 0..<60 {
            let a = Activity(garminId: Int64(i))
            a.typeKey = i % 3 == 0 ? "road_biking" : "running"
            a.start = calendar.date(from: DateComponents(year: 2026, month: 1 + i % 11, day: 1 + i % 27, hour: 7 + i % 12))!
            a.distance = i % 3 == 0 ? 40_000 : 8_000 + Double(i * 100)
            a.movingDuration = i % 3 == 0 ? 5_400 : 3_000  // runs: 40 × 3,000 s beats rides: 20 × 5,400 s
            a.elevationGain = 120
            activities.append(a)
        }
        let days = (1...200).map { n -> Day in
            let d = Day(date: GarminDate.string(calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!.addingTimeInterval(Double(n) * 86_400)))
            d.sleepSeconds = 25_000 + n * 10
            d.sleepScore = 70 + n % 20
            d.hrvLastNight = 50 + n / 20
            d.restingHR = 58 - n / 50
            d.steps = 9_000
            return d
        }
        let stats = YearStats(year: 2026, activities: activities, days: days)
        XCTAssertEqual(stats.count, 60)
        XCTAssertEqual(stats.sports.first?.0, .run)
        XCTAssertNotNil(stats.trend(\.hrvLastNight))
        XCTAssertGreaterThan(stats.longestStreak, 0)
        let renderer = ImageRenderer(content: YearStory(stats: stats, format: Format(units: "metric")).frame(width: 820, height: 860))
        XCTAssertNotNil(renderer.nsImage)
        let card = ImageRenderer(content: YearSummaryCard(stats: stats, format: Format(units: "metric")).card)
        XCTAssertNotNil(card.nsImage)
    }
}
