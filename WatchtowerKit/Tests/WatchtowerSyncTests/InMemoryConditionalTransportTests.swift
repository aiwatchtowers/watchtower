import XCTest
@testable import WatchtowerSync

final class InMemoryConditionalTransportTests: XCTestCase {
    private func record(_ name: String, zone: CloudZoneID = .relay, payload: String = "{}") -> CloudRecord {
        CloudRecord(
            recordName: name,
            zone: zone,
            kind: "wt",
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            payload: Data(payload.utf8)
        )
    }

    private func saveOne(
        _ transport: InMemoryCloudTransport,
        _ record: CloudRecord,
        _ expect: WriteExpectation
    ) async throws -> SaveOutcome {
        let outcomes = try await transport.save([ConditionalSave(record: record, expect: expect)])
        XCTAssertEqual(outcomes.count, 1)
        return outcomes[0]
    }

    private func deleteOne(
        _ transport: InMemoryCloudTransport,
        _ name: String,
        _ expect: WriteExpectation
    ) async throws -> DeleteOutcome {
        let outcomes = try await transport.delete([ConditionalDelete(recordName: name, zone: .relay, expect: expect)])
        XCTAssertEqual(outcomes.count, 1)
        return outcomes[0]
    }

    func testAbsentCreatesOnceThenConflicts() async throws {
        let transport = InMemoryCloudTransport()
        let first = try await saveOne(transport, record("a-1", payload: "{\"v\":1}"), .absent)
        XCTAssertEqual(first, .saved(recordSeq: 1))

        let second = try await saveOne(transport, record("a-1", payload: "{\"v\":2}"), .absent)
        guard case let .conflict(current) = second else {
            return XCTFail("expected a conflict, got \(second)")
        }
        XCTAssertEqual(current.payload, Data("{\"v\":1}".utf8))
        XCTAssertEqual(current.recordSeq, 1)
    }

    func testSeqOverwritesOnlyTheVersionItNames() async throws {
        let transport = InMemoryCloudTransport()
        _ = try await saveOne(transport, record("c-1"), .absent)

        let overwrite = try await saveOne(transport, record("c-1", payload: "{\"v\":2}"), .seq(1))
        XCTAssertEqual(overwrite, .saved(recordSeq: 2))

        let stale = try await saveOne(transport, record("c-1", payload: "{\"v\":3}"), .seq(1))
        guard case let .conflict(current) = stale else {
            return XCTFail("expected a conflict, got \(stale)")
        }
        XCTAssertEqual(current.recordSeq, 2)
        XCTAssertEqual(current.payload, Data("{\"v\":2}".utf8))
    }

    func testSeqAgainstAnAbsentRecordIsRefusedAsGone() async throws {
        let transport = InMemoryCloudTransport()
        let outcome = try await saveOne(transport, record("c-1"), .seq(4))
        XCTAssertEqual(outcome, .refused(.permanent(code: "gone")))
        let batch = try await transport.changes(in: .relay, since: nil)
        XCTAssertTrue(batch.changed.isEmpty)
    }

    func testNoneAlwaysWrites() async throws {
        let transport = InMemoryCloudTransport()
        let first = try await saveOne(transport, record("c-1"), .none)
        XCTAssertEqual(first, .saved(recordSeq: 1))
        let second = try await saveOne(transport, record("c-1"), .none)
        XCTAssertEqual(second, .saved(recordSeq: 2))
    }

    func testChangesCarryTheRecordSeq() async throws {
        let transport = InMemoryCloudTransport()
        try await transport.save([record("plain-1")])
        _ = try await saveOne(transport, record("a-1"), .absent)
        _ = try await saveOne(transport, record("a-1", payload: "{\"v\":2}"), .seq(2))

        let batch = try await transport.changes(in: .relay, since: nil)
        let seqs = Dictionary(uniqueKeysWithValues: batch.changed.map { ($0.recordName, $0.recordSeq) })
        XCTAssertEqual(seqs["plain-1"], 1)
        XCTAssertEqual(seqs["a-1"], 3)
    }

    func testDeleteUnderSeqAndAbsentRecord() async throws {
        let transport = InMemoryCloudTransport()
        _ = try await saveOne(transport, record("c-1"), .absent)
        _ = try await saveOne(transport, record("c-1"), .seq(1))
        _ = try await saveOne(transport, record("c-1"), .seq(2))

        let stale = try await deleteOne(transport, "c-1", .seq(2))
        guard case let .conflict(current) = stale else {
            return XCTFail("expected a conflict, got \(stale)")
        }
        XCTAssertEqual(current.recordSeq, 3)

        let applied = try await deleteOne(transport, "c-1", .seq(3))
        XCTAssertEqual(applied, .deleted)
        let batch = try await transport.changes(in: .relay, since: nil)
        XCTAssertEqual(batch.deletedRecordNames, ["c-1"])
        XCTAssertTrue(batch.changed.isEmpty)

        let absentUnderSeq = try await deleteOne(transport, "never-saved", .seq(1))
        XCTAssertEqual(absentUnderSeq, .deleted)
        let absentUnconditional = try await deleteOne(transport, "never-saved", .none)
        XCTAssertEqual(absentUnconditional, .deleted)
    }

    func testScriptedRefusalsComeFirst() async throws {
        let transport = InMemoryCloudTransport()
        await transport.refuseNext(.unreachable, count: 2)

        let outcomes = try await transport.save([
            ConditionalSave(record: record("a-1"), expect: .absent),
            ConditionalSave(record: record("a-2"), expect: .none),
            ConditionalSave(record: record("a-3"), expect: .absent)
        ])
        XCTAssertEqual(outcomes, [.refused(.unreachable), .refused(.unreachable), .saved(recordSeq: 1)])

        let batch = try await transport.changes(in: .relay, since: nil)
        XCTAssertEqual(batch.changed.map(\.recordName), ["a-3"])

        await transport.refuseNext(.rateLimited(retryAfter: 30), count: 1)
        let refused = try await deleteOne(transport, "a-3", .seq(1))
        XCTAssertEqual(refused, .refused(.rateLimited(retryAfter: 30)))
        let retried = try await deleteOne(transport, "a-3", .seq(1))
        XCTAssertEqual(retried, .deleted)
    }

    func testSuspendedSaveWaitsForTheGate() async throws {
        let transport = InMemoryCloudTransport()
        let gate = await transport.suspendNextSave()

        let pending = Task { try await transport.save([ConditionalSave(record: self.record("a-1"), expect: .absent)]) }
        await gate.waitUntilReached()
        let before = try await transport.changes(in: .relay, since: nil)
        XCTAssertTrue(before.changed.isEmpty)

        gate.open()
        let outcomes = try await pending.value
        XCTAssertEqual(outcomes, [.saved(recordSeq: 1)])
    }

    func testRefusalPermanence() {
        XCTAssertTrue(TransportRefusal.permanent(code: "gone").isPermanent)
        XCTAssertFalse(TransportRefusal.unreachable.isPermanent)
        XCTAssertFalse(TransportRefusal.rateLimited(retryAfter: nil).isPermanent)
        XCTAssertFalse(TransportRefusal.quotaExceeded.isPermanent)
        XCTAssertFalse(TransportRefusal.entitlementInactive.isPermanent)
        XCTAssertFalse(TransportRefusal.transient(code: "x").isPermanent)
    }

    func testRecordSeqIsPartOfEquality() {
        let base = record("a-1")
        let versioned = CloudRecord(
            recordName: base.recordName, zone: base.zone, kind: base.kind,
            modifiedAt: base.modifiedAt, payload: base.payload, recordSeq: 7
        )
        XCTAssertNil(base.recordSeq)
        XCTAssertNotEqual(base, versioned)
    }
}
