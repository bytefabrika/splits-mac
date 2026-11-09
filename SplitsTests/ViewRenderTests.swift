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
