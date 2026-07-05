import XCTest
import GRDB
@testable import WatchtowerKit

final class RowPayloadCoderTests: XCTestCase {
    func testRowRoundTripPreservesAllStorageClasses() throws {
        let original = Row([
            "id": 42,
            "score": 0.5,
            "title": "hello",
            "raw": "bytes".data(using: .utf8)!,
            "missing": nil,
        ])

        let payload = try RowPayloadCoder.payload(from: original)
        let decoded = try RowPayloadCoder.row(from: payload)

        XCTAssertEqual(decoded["id"] as Int64?, 42)
        XCTAssertEqual(decoded["score"] as Double?, 0.5)
        XCTAssertEqual(decoded["title"] as String?, "hello")
        XCTAssertEqual(decoded["raw"] as Data?, "bytes".data(using: .utf8)!)
        XCTAssertTrue((decoded["missing"] as DatabaseValue?)?.isNull ?? false)
        XCTAssertEqual(decoded.count, original.count)
    }

    func testRowFromRealDatabaseQueryRoundTrips() throws {
        let queue = try DatabaseQueue()
        let payload: Data = try queue.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT 7 AS n, 'x' AS s, NULL AS z, 1.5 AS f")!
            return try RowPayloadCoder.payload(from: row)
        }
        let decoded = try RowPayloadCoder.row(from: payload)
        XCTAssertEqual(decoded["n"] as Int64?, 7)
        XCTAssertEqual(decoded["s"] as String?, "x")
        XCTAssertEqual(decoded["f"] as Double?, 1.5)
    }

    func testPayloadIsAJSONObject() throws {
        let payload = try RowPayloadCoder.payload(from: Row(["a": 1]))
        let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        XCTAssertNotNil(object)
    }

    func testSliceKindRecordName() {
        XCTAssertEqual(SliceKind.target.recordName(id: "123"), "target-123")
        XCTAssertEqual(SliceKind.inboxItem.recordName(id: "9"), "inbox_item-9")
    }

    func testSliceRecordRecordName() {
        let record = SliceRecord(kind: .digest, id: "55", modifiedAt: Date(timeIntervalSince1970: 0), payload: Data())
        XCTAssertEqual(record.recordName, "digest-55")
    }

    func testIntegralDoubleBecomesIntegerAfterRoundTrip() throws {
        // Frozen behavior: JSON cannot distinguish 2.0 from 2, and the decoder
        // tries Int64 before Double, so an integral REAL round-trips as INTEGER.
        // Typed reads still yield the correct Double; this test pins the storage
        // class so a future Foundation or coder change cannot silently move the
        // wire format.
        let original = Row(["f": 2.0])
        let payload = try RowPayloadCoder.payload(from: original)

        let jsonDict = try JSONDecoder().decode([String: JSONValue].self, from: payload)
        XCTAssertEqual(jsonDict["f"], .integer(2))

        let decoded = try RowPayloadCoder.row(from: payload)
        XCTAssertEqual(decoded["f"] as Double?, 2.0)
    }

    func testAllSliceKindRawValuesAreFrozen() {
        XCTAssertEqual(
            SliceKind.allCases.map(\.rawValue),
            ["briefing", "inbox_item", "target", "track", "digest", "digest_topic", "calendar_event", "person_card"]
        )
    }

    func testRowFromMalformedPayloadThrows() {
        XCTAssertThrowsError(try RowPayloadCoder.row(from: Data("not json".utf8)))
        XCTAssertThrowsError(try RowPayloadCoder.row(from: Data("[1,2,3]".utf8)))
    }

    func testPayloadOutputIsDeterministic() throws {
        // .sortedKeys makes the payload byte-stable across processes —
        // Plan 2 hashes payloads for change detection.
        let row = Row(["zebra": 1, "alpha": "x", "mid": 2.5])
        let payload = try RowPayloadCoder.payload(from: row)
        XCTAssertEqual(
            String(data: payload, encoding: .utf8),
            #"{"alpha":"x","mid":2.5,"zebra":1}"#
        )
    }
}
