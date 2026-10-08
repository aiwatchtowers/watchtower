import XCTest
@testable import WatchtowerSync

/// ActionStatus is wire format (mobile POC spec §5.2). Only the Mac moves a
/// record out of `pending`, and a phone build treats a status it does not
/// know as `pending`, so a newer Mac's echo never fails to decode.
final class ActionStatusTests: XCTestCase {
    private let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    func testRawValuesAreFrozen() {
        XCTAssertEqual(
            ActionStatus.allCases.map(\.rawValue),
            ["pending", "received", "held", "applied", "failed", "expired", "cancelled"]
        )
    }

    func testEveryKnownStatusDecodes() throws {
        for status in ActionStatus.allCases {
            let json = Data("\"\(status.rawValue)\"".utf8)
            XCTAssertEqual(try RelayCoder.makeDecoder().decode(ActionStatus.self, from: json), status)
        }
    }

    func testUnknownStatusDecodesAsPending() throws {
        let json = Data("\"teleported\"".utf8)
        XCTAssertEqual(try RelayCoder.makeDecoder().decode(ActionStatus.self, from: json), .pending)
    }

    func testUnknownStatusInsideAnEchoDecodesAsPending() throws {
        let json = #"{"created_at":1700000000,"id":"A1","kind":"probe","params":{},"status":"teleported"}"#
        let decoded = try RelayCoder.makeDecoder().decode(ActionRequestPayload.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.status, .pending)
        XCTAssertEqual(decoded.kind, .probe)
    }

    // MARK: - Overlay resolution per status

    private func echo(_ status: ActionStatus, outbox: ActionOutbox, store: ReplicaStore) async throws {
        var action = try XCTUnwrap(store.pendingActions().first).action
        action.status = status
        try await outbox.applyEcho(action)
    }

    func testReceivedAndHeldKeepTheOverlayPending() async throws {
        for status in [ActionStatus.received, .held] {
            let store = try ReplicaStore.inMemory()
            let outbox = ActionOutbox(transport: InMemoryCloudTransport(), store: store) { self.stamp }
            _ = try await outbox.enqueue(kind: .probe, entityRecordName: nil)

            try await echo(status, outbox: outbox, store: store)

            XCTAssertEqual(try XCTUnwrap(store.pendingActions().first).state, .pending, "\(status)")
        }
    }

    func testExpiredAndCancelledFailTheOverlay() async throws {
        for status in [ActionStatus.expired, .cancelled] {
            let store = try ReplicaStore.inMemory()
            let outbox = ActionOutbox(transport: InMemoryCloudTransport(), store: store) { self.stamp }
            _ = try await outbox.enqueue(kind: .probe, entityRecordName: nil)

            try await echo(status, outbox: outbox, store: store)

            XCTAssertEqual(try XCTUnwrap(store.pendingActions().first).state, .failed, "\(status)")
        }
    }
}
