import Foundation
import os
import XCTest
@testable import WatchtowerSync

/// The phone's epoch keys (relay client Phase 3, Task 6): an epoch is kept 7 days after a newer one arrived (the
/// owner's "7 days everywhere", ask #843), the newest always, at most `maxEpochs`; an epoch stored before this build
/// carries no stamp and is stamped on the next merge, never dropped; the NSE's alert material follows the kept set.
final class EpochRetentionTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private let day: TimeInterval = 86_400

    private func epoch(_ number: UInt32, supersededAt: Date? = nil) -> EpochKeys {
        EpochKeys(
            epoch: number, dataKey: Data(repeating: UInt8(number), count: 32),
            alertKey: Data(repeating: UInt8(number) &+ 100, count: 32), supersededAt: supersededAt)
    }

    private func link(_ epochs: [EpochKeys]) -> HubLinkKeys {
        HubLinkKeys(
            hubID: "hub-1", hubSigningKey: Data(repeating: 7, count: 32), hubAgreementKey: Data(repeating: 8, count: 32),
            linkNonce: Data(repeating: 9, count: 16), metaKey: Data(repeating: 0xA1, count: 32), epochs: epochs)
    }

    func testAnEpochIsKeptSevenDaysAfterItWasSuperseded() {
        let keys = link([epoch(1, supersededAt: base), epoch(2)])
        let almost = base.addingTimeInterval(7 * day - 3600)
        XCTAssertEqual(keys.retained(now: almost).epochs.map(\.epoch), [1, 2], "6 d 23 h after: kept")
        XCTAssertEqual(keys.retained(now: base.addingTimeInterval(7 * day)).epochs.map(\.epoch), [2], "7 d after: dropped")
        XCTAssertEqual(HubLinkKeys.previousEpochGrace, 7 * day)
    }

    func testThreeSwitchesInSevenDaysKeepFourEpochs() {
        let keys = link([
            epoch(1, supersededAt: base), epoch(2, supersededAt: base.addingTimeInterval(2 * day)),
            epoch(3, supersededAt: base.addingTimeInterval(4 * day)), epoch(4)
        ])
        XCTAssertEqual(keys.retained(now: base.addingTimeInterval(6 * day)).epochs.map(\.epoch), [1, 2, 3, 4])
    }

    /// An epoch from before this build has no stamp: it stays until a merge stamps it, then 7 days more.
    func testAnUnstampedEpochIsStampedNotDropped() {
        let today = link([epoch(1), epoch(2)])
        XCTAssertEqual(today.retained(now: base.addingTimeInterval(400 * day)).epochs.map(\.epoch), [1, 2])

        var withThree = today
        withThree.epochs.append(epoch(3))
        let merged = withThree.stampingSuperseded(from: today, now: base)
        XCTAssertEqual(merged.epochs.map(\.supersededAt), [base, base, nil], "the previous newest and the unstamped one")
        XCTAssertTrue(merged.newestEpochRaised(over: today))
        XCTAssertEqual(merged.retained(now: base.addingTimeInterval(6 * day)).epochs.map(\.epoch), [1, 2, 3])
        XCTAssertEqual(merged.retained(now: base.addingTimeInterval(7 * day)).epochs.map(\.epoch), [3])

        // A stamp already there is kept; a merge that adds nothing newer raises nothing.
        let again = merged.stampingSuperseded(from: merged, now: base.addingTimeInterval(day))
        XCTAssertEqual(again.epochs.map(\.supersededAt), [base, base, nil])
        XCTAssertFalse(again.newestEpochRaised(over: merged))
    }

    func testTheCapKeepsTheNewest() {
        XCTAssertEqual(HubLinkKeys.maxEpochs, 8)
        let keys = link((1...10).map { epoch(UInt32($0)) })
        XCTAssertEqual(keys.retained(now: base).epochs.map(\.epoch), Array(3...10))
    }

    func testAlertMaterialFollowsTheRetainedSet() throws {
        let clock = OSAllocatedUnfairLock(initialState: base)
        let store = KeychainPhoneKeyStore(
            backend: FakeKeychainBackend(), privateGroup: "TEAM.private", alertGroup: "TEAM.alerts"
        ) { clock.withLock { $0 } }
        try store.saveHubLink(link([
            epoch(1, supersededAt: base.addingTimeInterval(-8 * day)), epoch(2, supersededAt: base.addingTimeInterval(-day)),
            epoch(3)
        ]))
        XCTAssertEqual(try store.hubLink("hub-1")?.epochs.map(\.epoch), [2, 3])
        let alert = try XCTUnwrap(try store.alertMaterial("hub-1"))
        XCTAssertEqual(alert.epochs.map(\.epoch), [2, 3])
        XCTAssertEqual(alert.epochs.map(\.dataKey), [Data(), Data()], "no data key reaches the NSE")
        XCTAssertEqual(alert.epochs.map(\.alertKey), [epoch(2).alertKey, epoch(3).alertKey])
    }

    /// A Keychain item written before this build (no `supersededAt` key) decodes; an unstamped epoch encodes as
    /// it did.
    func testTodaysKeychainJSONStillDecodes() throws {
        let key = Data(repeating: 1, count: 32).base64EncodedString()
        let json = """
            {"hubID":"hub-1","hubSigningKey":"\(key)","hubAgreementKey":"\(key)","linkNonce":"\(key)",
             "epochs":[{"epoch":1,"dataKey":"\(key)","alertKey":"\(key)"},{"epoch":2,"dataKey":"\(key)","alertKey":"\(key)"}]}
            """
        let decoded = try JSONDecoder().decode(HubLinkKeys.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.epochs.map(\.epoch), [1, 2])
        XCTAssertEqual(decoded.epochs.map(\.supersededAt), [nil, nil])
        let encoded = try XCTUnwrap(String(data: try JSONEncoder().encode(decoded.epochs[0]), encoding: .utf8))
        XCTAssertFalse(encoded.contains("supersededAt"))

        let stamped = try JSONDecoder().decode(
            EpochKeys.self, from: try JSONEncoder().encode(epoch(1, supersededAt: base)))
        XCTAssertEqual(stamped.supersededAt, base)
    }
}
