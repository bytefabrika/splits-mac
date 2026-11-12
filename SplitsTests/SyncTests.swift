import SwiftData
import XCTest
@testable import Splits

/// The sync against a fake Garmin: empty answers, and a first sync that stops part way and is tried again.
@MainActor
final class SyncTests: XCTestCase {
    /// Answers requests by path. Set before each test; read from URLSession's loading thread.
    final class FakeGarmin: URLProtocol {
        nonisolated(unsafe) static var answer: (URLRequest) -> (Int, String) = { _ in (404, "") }
        nonisolated(unsafe) static var asked: [URLRequest] = []
        private static let lock = NSLock()

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let (status, body) = Self.lock.withLock { Self.asked.append(request); return Self.answer(request) }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}

        static var hrvRanges: [String] {
            lock.withLock { asked.compactMap { $0.url?.path }.filter { $0.hasPrefix("/hrv-service/hrv/daily/") } }
        }
    }

    private let today = Date(timeIntervalSince1970: 1_794_441_600)  // 12 November 2026
    private var container: ModelContainer!
    private var defaults: UserDefaults!

    override func setUp() {
        container = try! ModelContainer(for: Activity.self, Day.self,
                                        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        defaults = UserDefaults(suiteName: "SyncTests")!
        defaults.removePersistentDomain(forName: "SyncTests")
        FakeGarmin.asked = []
    }

    private func makeSync() -> Sync {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeGarmin.self]
        let client = GarminClient(key: { "key" }, session: URLSession(configuration: config), gap: 0)
        return Sync(client: client, context: container.mainContext, defaults: defaults, today: { self.today })
    }

    /// A plain account: two activities, a night of sleep and an HRV reading on the newest day. `hrv` can override HRV.
    private func garmin(hrv: @escaping (_ from: String, _ to: String) -> (Int, String)? = { _, _ in nil }) -> (URLRequest) -> (Int, String) {
        { request in
            let path = request.url!.path
            switch path {
            case GarminClient.tokenPath: return (200, "token")
            case Endpoint.profile.0: return (200, "{}")
            case "/activitylist-service/activities/search/activities":
                return (200, """
                [{"activityId": 1, "startTimeLocal": "2019-05-01 08:00:00", "activityType": {"typeKey": "running"}, "distance": 10000, "movingDuration": 3000},
                 {"activityId": 2, "startTimeLocal": "2026-11-10 08:00:00", "activityType": {"typeKey": "cycling"}, "distance": 30000, "movingDuration": 3600}]
                """)
            case "/usersummary-service/v2/dailysummaries": return (200, #"{"data": []}"#)
            case "/sleep-service/sleep/dailySleepSummariesByDate":
                return (200, #"[{"calendarDate": "2026-11-12", "sleepTimeSeconds": 27000}]"#)
            default:
                if path.hasPrefix("/hrv-service/hrv/daily/") {
                    let parts = path.split(separator: "/")
                    let from = String(parts[parts.count - 2]), to = String(parts[parts.count - 1])
                    if let override = hrv(from, to) { return override }
                    return (200, to == "2026-11-12" ? #"{"hrvSummaries": [{"calendarDate": "2026-11-12", "lastNightAvg": 55}]}"# : #"{"hrvSummaries": []}"#)
                }
                if path.hasPrefix("/usersummary-service/stats/steps/daily/") { return (200, "[]") }
                return (404, "")
            }
        }
    }

    /// The bug a user hit: the last, one-day stretch of the year had no HRV, Garmin answered 204, and the first sync stopped.
    func testEmptyAnswersDoNotStopTheFirstSync() async throws {
        FakeGarmin.answer = garmin(hrv: { from, to in from == to ? (204, "") : nil })
        let sync = makeSync()
        await sync.run()
        XCTAssertEqual(sync.state, .idle)
        XCTAssertNotNil(sync.lastSync)
        XCTAssertTrue(FakeGarmin.hrvRanges.contains("/hrv-service/hrv/daily/2025-11-13/2025-11-13"), "the year ends on a one-day stretch")
        let days = try container.mainContext.fetch(FetchDescriptor<Day>())
        XCTAssertEqual(days.first { $0.date == "2026-11-12" }?.hrvLastNight, 55)
    }

    /// A second user: a watch that doesn't measure HRV at all, so even the newest stretch came back empty.
    func testWatchWithoutHRV() async throws {
        FakeGarmin.answer = garmin(hrv: { _, _ in (204, "") })
        let sync = makeSync()
        await sync.run()
        XCTAssertEqual(sync.state, .idle)
        let days = try container.mainContext.fetch(FetchDescriptor<Day>())
        XCTAssertEqual(days.first { $0.date == "2026-11-12" }?.sleepSeconds, 27000, "the rest of the day is still stored")
        await sync.run()
        XCTAssertEqual(sync.state, .idle, "and later syncs work too")
    }

    /// Every wellness answer empty, and no activities: a new account, or a watch that records little.
    func testEverythingEmpty() async throws {
        let plain = garmin()
        FakeGarmin.answer = { request in
            let path = request.url!.path
            if path == GarminClient.tokenPath || path == Endpoint.profile.0 { return plain(request) }
            return (204, "")
        }
        let sync = makeSync()
        await sync.run()
        XCTAssertEqual(sync.state, .idle)
        XCTAssertTrue(FakeGarmin.asked.contains { $0.url?.path == "/sleep-service/sleep/dailySleepSummariesByDate" })
        XCTAssertEqual(sync.found.activities, 0)
        XCTAssertEqual(sync.found.nights, 0)
    }

    /// Try Again after a failure part way: carry on with the older days, and keep the counts on screen.
    func testTryAgainCarriesOnFromWhereItStopped() async throws {
        var failing = true
        FakeGarmin.answer = garmin(hrv: { from, _ in failing && from < "2026-03-01" ? (500, "down") : nil })
        let sync = makeSync()
        await sync.run()
        guard case .failed = sync.state else { return XCTFail("expected the first try to fail, got \(sync.state)") }
        XCTAssertNil(sync.lastSync)
        let reached = try XCTUnwrap(defaults.object(forKey: Sync.reachedBackKey) as? Date)
        XCTAssertGreaterThan(GarminDate.string(reached), "2026-03-01")

        failing = false
        FakeGarmin.asked = []
        await sync.run()
        XCTAssertEqual(sync.state, .idle)
        let ranges = FakeGarmin.hrvRanges
        // The last few days again, then straight on from the day before where the first try got to.
        XCTAssertEqual(ranges.first, "/hrv-service/hrv/daily/2026-11-09/2026-11-12")
        let dayBefore = GarminDate.string(Calendar.current.date(byAdding: .day, value: -1, to: reached)!)
        XCTAssertTrue(ranges[1].hasSuffix("/\(dayBefore)"), "\(ranges)")
        XCTAssertEqual(ranges.last, "/hrv-service/hrv/daily/2025-11-13/2025-11-13")
        XCTAssertEqual(sync.found.activities, 2, "the counts don't drop to what's new this time")
        XCTAssertEqual(sync.found.nights, 1)
        XCTAssertEqual(GarminDate.string(try XCTUnwrap(defaults.object(forKey: Sync.reachedBackKey) as? Date)), "2025-11-13")
    }

    /// Stores from 0.1 have no record of how far back they reached: read the year once more, then only the last days.
    func testOlderStoresFillTheYearOnce() async throws {
        FakeGarmin.answer = garmin()
        let sync = makeSync()
        await sync.run()
        defaults.removeObject(forKey: Sync.reachedBackKey)

        FakeGarmin.asked = []
        await sync.run()
        XCTAssertTrue(FakeGarmin.hrvRanges.last?.hasPrefix("/hrv-service/hrv/daily/2025-11-13/") == true, "\(FakeGarmin.hrvRanges)")

        FakeGarmin.asked = []
        await sync.run()
        XCTAssertEqual(FakeGarmin.hrvRanges, ["/hrv-service/hrv/daily/2026-11-09/2026-11-12"])
    }
}
