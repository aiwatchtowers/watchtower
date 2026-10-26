import WatchtowerE2ETesting
import XCTest
@testable import WatchtowerSync

/// The stored `ask_alert` envelopes a shared-scope phone opens itself after a fetch (ask #622): every alert-class
/// row the replica holds, indexed or not, so a phone still locked (data keys unreadable) finds them too.
final class ReplicaAlertEnvelopeTests: XCTestCase {
    private let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    private func record(_ kind: SliceKind, id: String) -> CloudRecord {
        CloudRecord(
            recordName: kind.recordName(id: id), zone: .data, kind: kind.rawValue, modifiedAt: stamp,
            payload: Data("{\"id\":\(id)}".utf8))
    }

    private func sealed(_ records: [CloudRecord]) async throws -> [CloudRecord] {
        let transport = TestE2E.hubTransport(TestE2E.hub())
        var out: [CloudRecord] = []
        for record in records { out.append(try await transport.seal(record)) }
        return out
    }

    func testOnlyAlertEnvelopesAreListedLockedOrNot() async throws {
        let keys = try TestE2E.phoneStore()
        keys.isLocked = true
        let store = try ReplicaStore.inMemory(opener: TestE2E.opener(store: keys))
        let wire = try await sealed([record(.askAlert, id: "7"), record(.ownerAsk, id: "7"), record(.askAlert, id: "8")])
        XCTAssertTrue(try store.apply(CloudChangeBatch(changed: wire, deletedRecordNames: [], newToken: CloudChangeToken(value: 1))))

        let locked = try store.alertEnvelopes()
        XCTAssertEqual(Set(locked.map(\.wireName)), [wire[0].recordName, wire[2].recordName], "unindexed rows by class")
        XCTAssertEqual(locked.first { $0.wireName == wire[0].recordName }?.envelope, wire[0].payload)

        keys.isLocked = false
        _ = try store.indexPending()
        XCTAssertEqual(Set(try store.alertEnvelopes().map(\.wireName)), [wire[0].recordName, wire[2].recordName], "indexed rows")

        XCTAssertTrue(try store.apply(CloudChangeBatch(
            changed: [], deletedRecordNames: [wire[0].recordName], newToken: CloudChangeToken(value: 2))))
        XCTAssertEqual(try store.alertEnvelopes().map(\.wireName), [wire[2].recordName], "a deleted alert is gone")
    }
}
