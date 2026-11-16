import CloudBridgeCore
import CloudKit
import XCTest

/// `CloudKitBridgeCloud` keeps each modify request CloudKit-sized (#1745): a frame's saves and deletes go in
/// batches of at most 200 records and about 1 MiB, a request CloudKit still refuses as too large is halved,
/// and only a record refused alone is answered `record_too_large`, alone.
final class CloudKitBridgeCloudBatchTests: XCTestCase {
    private let hub = "hub-acme"
    private var data: String { "DataZone-\(hub)" }
    private var db: FakeDatabase!
    private var cloud: CloudKitBridgeCloud!

    override func setUp() {
        db = FakeDatabase()
        cloud = CloudKitBridgeCloud(hubID: hub, database: db) { true }
    }

    private var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: data, ownerName: CKCurrentUserDefaultName)
    }

    private func writes(_ count: Int, bytes: Int = 16) -> [CloudWrite] {
        (0..<count).map { CloudWrite(name: "k\($0)", envelope: Data(repeating: UInt8($0 % 251), count: bytes)) }
    }

    private func savedNames(_ results: [CloudWriteResult]) -> [String?] {
        results.map { result in
            if case .done(let item?) = result { return item.name }
            return nil
        }
    }

    func testManyRecordsGoInBatchesOfAtMost200() async throws {
        let frame = writes(450)
        let results = try await cloud.save(zone: data, frame)
        XCTAssertEqual(db.saveSizes, [200, 200, 50])
        XCTAssertEqual(savedNames(results), frame.map(\.name), "one result per write, in the frame's order")
    }

    func testBigEnvelopesGoInBatchesOfAboutAMegabyte() async throws {
        let results = try await cloud.save(zone: data, writes(5, bytes: 400 << 10))
        XCTAssertEqual(db.saveSizes, [2, 2, 1], "two 400 KiB envelopes fit a request, a third does not")
        XCTAssertEqual(savedNames(results), ["k0", "k1", "k2", "k3", "k4"])
    }

    func testOneRecordOverTheByteBudgetStillGoesAlone() async throws {
        let frame = [CloudWrite(name: "small", envelope: Data([1])), CloudWrite(name: "huge", envelope: Data(count: 2 << 20))]
        let results = try await cloud.save(zone: data, frame)
        XCTAssertEqual(db.saveSizes, [1, 1])
        XCTAssertEqual(savedNames(results), ["small", "huge"])
    }

    func testARequestCloudKitRefusesAsTooLargeIsHalved() async throws {
        db.requestLimit = 3
        let frame = writes(8)
        let results = try await cloud.save(zone: data, frame)
        XCTAssertEqual(savedNames(results), frame.map(\.name), "every record saved once the request fits")
        XCTAssertEqual(db.saveSizes, [8, 4, 2, 2, 4, 2, 2], "8 refused, then halves until each fits")
        for write in frame {
            XCTAssertEqual(db.payload(name: write.name, zone: zoneID), write.envelope)
        }
    }

    func testARecordTooLargeAloneIsRefusedAloneAndTheRestSave() async throws {
        db.tooLarge = ["k2"]
        let results = try await cloud.save(zone: data, writes(5))
        XCTAssertEqual(results[2], .refused("record_too_large"))
        XCTAssertEqual(savedNames(results), ["k0", "k1", nil, "k3", "k4"])
        XCTAssertEqual(db.saveSizes, [5, 2, 3, 1, 2], "halved until k2 went alone")
        XCTAssertNil(db.record(name: "k2", zone: zoneID))
    }

    func testConditionalAndPlainSavesAreBatchedApart() async throws {
        var frame = writes(3)
        frame[1].precondition = .absent
        db.tooLarge = ["k0"]
        let results = try await cloud.save(zone: data, frame)
        XCTAssertEqual(db.saveSizes, [1, 2, 1, 1], "the conditional one alone, then the refused plain pair halved")
        XCTAssertEqual(db.policies, [.ifServerRecordUnchanged, .allKeys])
        XCTAssertEqual(results[0], .refused("record_too_large"))
        XCTAssertEqual(savedNames(results), [nil, "k1", "k2"])
    }

    func testAnotherFailureFailsTheCallUnsplit() async throws {
        db.saveFailure = CKError(.networkFailure)
        do {
            _ = try await cloud.save(zone: data, writes(4))
            XCTFail("a failed request passed")
        } catch {
            XCTAssertEqual(bridgeFailureClass(error), "unavailable")
        }
        XCTAssertEqual(db.saveSizes, [4], "only limitExceeded splits a request")
    }

    func testAFailureAfterAnAppliedRequestKeepsItsResults() async throws {
        db.saveFailure = CKError(.requestRateLimited)
        db.saveFailureAfter = 1
        let frame = writes(250)
        let results = try await cloud.save(zone: data, frame)
        XCTAssertEqual(db.saveSizes, [200, 50])
        XCTAssertEqual(Array(savedNames(results).prefix(200)), frame.prefix(200).map(\.name), "the applied request is answered")
        XCTAssertTrue(results.suffix(50).allSatisfy { $0 == .refused("rate_limited") }, "the rest carry the failure's class")
    }

    func testDeletesAreBatchedAndHalvedToo() async throws {
        for i in 0..<450 {
            db.put(name: "k\(i)", zone: zoneID, payload: Data([1]), tag: "t")
        }
        let deletions = (0..<450).map { CloudDeletion(name: "k\($0)") }
        let results = try await cloud.delete(zone: data, deletions)
        XCTAssertEqual(db.deleteSizes, [200, 200, 50])
        XCTAssertTrue(results.allSatisfy { $0 == .done(nil) })

        db.requestLimit = 1
        db.tooLarge = ["odd"]
        let small = try await cloud.delete(zone: data, [CloudDeletion(name: "a"), CloudDeletion(name: "odd")])
        XCTAssertEqual(small, [.done(nil), .refused("record_too_large")])
        XCTAssertEqual(db.deleteSizes.suffix(3), [2, 1, 1], "the refused pair was halved")
    }
}
