import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// #1873: the line that says how old the replica is (spec 2026-11-16-phone-stale-data-line-design).
final class ReplicaFreshnessTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }()

    private let locale = Locale(identifier: "en_GB")
    /// 2026-11-16 16:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_794_844_800)

    private func beat(
        age: TimeInterval, published: TimeInterval? = nil, stuck: TimeInterval? = nil, name: String = "Acme Mac"
    ) -> HeartbeatPayload {
        HeartbeatPayload(
            updatedAt: now.addingTimeInterval(-age), appVersion: "1", hubID: "h", macName: name, flavor: .default,
            lastPublishAt: published.map { now.addingTimeInterval(-$0) }, lastRelayAt: nil, relayBacklog: 0,
            accounts: [], enabledAt: now, ownerUser: "", sharing: .none,
            stuckSince: stuck.map { now.addingTimeInterval(-$0) })
    }

    private func line(
        _ heartbeat: HeartbeatPayload?, linked: Bool = true, unansweredFor: TimeInterval? = nil, showsOffline: Bool = true
    ) -> ReplicaFreshness? {
        ReplicaFreshness(
            heartbeat: heartbeat, linked: linked, relayUnansweredSince: unansweredFor.map { now.addingTimeInterval(-$0) },
            showsOffline: showsOffline, now: now, calendar: calendar, locale: locale)
    }

    func testFreshDataShowsNothing() {
        XCTAssertNil(line(beat(age: 60, published: 60)))
        XCTAssertNil(line(beat(age: 35 * 60 - 1, published: 40 * 60)), "34:59 is still online")
    }

    func testLoadingAndUnlinkedShowNothing() {
        XCTAssertNil(line(nil), "no heartbeat yet")
        XCTAssertNil(line(nil, unansweredFor: 3_600), "no heartbeat yet, even offline")
        XCTAssertNil(line(beat(age: 3 * 3_600), linked: false))
    }

    func testStaleFromTheHeartbeatsAgeNamesTheLastPublish() throws {
        let model = try XCTUnwrap(line(beat(age: 35 * 60, published: 40 * 60)))
        XCTAssertEqual(model.state, .stale)
        XCTAssertEqual(model.text, "Updated 15:20 · Acme Mac is not sending updates")
    }

    func testStaleWithoutALastPublishFallsBackToTheStamp() throws {
        XCTAssertEqual(try XCTUnwrap(line(beat(age: 2 * 3_600))).text, "Updated 14:00 · Acme Mac is not sending updates")
    }

    func testStuckAfterTenMinutesNamesWhenItStuck() throws {
        XCTAssertNil(line(beat(age: 60, published: 60, stuck: 10 * 60 - 1)), "a short refusal does not flash the line")
        let model = try XCTUnwrap(line(beat(age: 60, published: 60, stuck: 7 * 3_600 + 34 * 60)))
        XCTAssertEqual(model.state, .stuck)
        XCTAssertEqual(model.text, "Updated 8:26 · Acme Mac is not sending some updates")
    }

    func testOfflineWinsOverStaleAndStaleOverStuck() throws {
        let both = beat(age: 3_600, published: 3_600, stuck: 2 * 3_600)
        XCTAssertEqual(try XCTUnwrap(line(both)).state, .stale)
        let offline = try XCTUnwrap(line(both, unansweredFor: 60))
        XCTAssertEqual(offline.state, .offline)
        XCTAssertEqual(offline.text, "Updated 15:00 · this iPhone can't reach Relay")
        XCTAssertEqual(try XCTUnwrap(line(beat(age: 60, published: 60), unansweredFor: 60)).state, .offline)
    }

    /// A short Relay failure does not flash the line: offline waits the Relay banner's 60 s.
    func testOfflineWaitsAMinute() {
        XCTAssertNil(line(beat(age: 60, published: 60), unansweredFor: 59))
        XCTAssertEqual(line(beat(age: 3_600, published: 3_600), unansweredFor: 59)?.state, .stale)
    }

    /// Now's Relay banner says Relay does not answer: the line there leaves offline out, and does not fall back
    /// to stale (the phone cannot tell then).
    func testNowLeavesOfflineToTheRelayBanner() {
        XCTAssertNil(line(beat(age: 3_600, published: 3_600), unansweredFor: 120, showsOffline: false))
        XCTAssertEqual(line(beat(age: 3_600, published: 3_600), showsOffline: false)?.state, .stale)
    }

    func testAnUnnamedTowerIsYourTower() throws {
        XCTAssertEqual(
            try XCTUnwrap(line(beat(age: 3_600, published: 3_600, name: ""))).text,
            "Updated 15:00 · your tower is not sending updates")
    }

    func testTheThreeDateForms() {
        func clock(_ ago: TimeInterval) -> String {
            ReplicaFreshness.clock(now.addingTimeInterval(-ago), now: now, calendar: calendar, locale: locale)
        }
        XCTAssertEqual(clock(40 * 60), "15:20")
        XCTAssertEqual(clock(20 * 3_600), "yesterday 20:00")
        XCTAssertEqual(clock(2 * 86_400), "14 Nov, 16:00")
    }

    func testAnOlderHubWithoutStuckSinceIsNeverStuck() {
        XCTAssertNil(line(beat(age: 60, published: 60, stuck: nil)))
    }

    func testTheLineIsNeverOrange() throws {
        let model = try XCTUnwrap(line(beat(age: 3_600)))
        XCTAssertNotEqual(model.toneUse.tone, .orange)
        XCTAssertFalse(model.toneUse.isWaitingOrAsk)
    }
}
