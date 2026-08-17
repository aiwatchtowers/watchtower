import XCTest
@testable import WatchtowerKit

/// Wire-format freeze + factory mapping for the phone recording upload
/// envelope. Fixture timestamps are frozen wire constants (like every other
/// relay fixture), never clock reads.
final class RecordingUploadPayloadTests: XCTestCase {
    func testPendingWireFormatIsFrozen() throws {
        let upload = RecordingUploadPayload(
            id: "R1",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_754),
            durationSec: 754,
            titleHint: "Standup",
            sampleFormat: "aac-64k-mono"
        )
        let json = try XCTUnwrap(String(data: try RelayCoder.makeEncoder().encode(upload), encoding: .utf8))
        // swiftlint:disable:next line_length
        XCTAssertEqual(json, #"{"duration_sec":754,"ended_at":1700000754,"id":"R1","sample_format":"aac-64k-mono","started_at":1700000000,"status":"pending","title_hint":"Standup"}"#)
        XCTAssertEqual(try RelayCoder.makeDecoder().decode(RecordingUploadPayload.self, from: Data(json.utf8)), upload)
        XCTAssertEqual(upload.recordName, "recupload-R1")
    }

    func testNilTitleHintOmitsTheKey() throws {
        // Absent-key discipline: a hint-less upload must carry NO title_hint
        // key, so old and new builds interoperate without a wire change.
        let upload = RecordingUploadPayload(
            id: "R2",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_060),
            durationSec: 60,
            titleHint: nil,
            sampleFormat: "aac-64k-mono"
        )
        let json = try XCTUnwrap(String(data: try RelayCoder.makeEncoder().encode(upload), encoding: .utf8))
        // swiftlint:disable:next line_length
        XCTAssertEqual(json, #"{"duration_sec":60,"ended_at":1700000060,"id":"R2","sample_format":"aac-64k-mono","started_at":1700000000,"status":"pending"}"#)
        XCTAssertNil(try RelayCoder.makeDecoder().decode(RecordingUploadPayload.self, from: Data(json.utf8)).titleHint)
    }

    func testReceivedWriteBackWireFormatIsFrozen() throws {
        var upload = RecordingUploadPayload(
            id: "R1",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_754),
            durationSec: 754,
            titleHint: "Standup",
            sampleFormat: "aac-64k-mono"
        )
        upload.status = .received
        let json = try XCTUnwrap(String(data: try RelayCoder.makeEncoder().encode(upload), encoding: .utf8))
        // swiftlint:disable:next line_length
        XCTAssertEqual(json, #"{"duration_sec":754,"ended_at":1700000754,"id":"R1","sample_format":"aac-64k-mono","started_at":1700000000,"status":"received","title_hint":"Standup"}"#)
    }

    func testFailedWriteBackWireFormatIsFrozen() throws {
        var upload = RecordingUploadPayload(
            id: "R1",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_010),
            durationSec: 10,
            titleHint: nil,
            sampleFormat: "aac-64k-mono"
        )
        upload.status = .failed
        upload.errorMessage = "recording asset is missing"
        let json = try XCTUnwrap(String(data: try RelayCoder.makeEncoder().encode(upload), encoding: .utf8))
        // swiftlint:disable:next line_length
        XCTAssertEqual(json, #"{"duration_sec":10,"ended_at":1700000010,"error_message":"recording asset is missing","id":"R1","sample_format":"aac-64k-mono","started_at":1700000000,"status":"failed"}"#)
        XCTAssertEqual(try RelayCoder.makeDecoder().decode(RecordingUploadPayload.self, from: Data(json.utf8)), upload)
    }

    func testRelayRecordKindIsStable() {
        XCTAssertEqual(RelayRecordKind.recordingUpload.rawValue, "recording_upload")
        XCTAssertEqual(
            RelayRecordKind.allCases.map(\.rawValue),
            ["action", "chat_message", "chat_chunk", "heartbeat", "recording_upload"]
        )
    }

    func testFactoryAttachesAssetAndZone() throws {
        let upload = RecordingUploadPayload(
            id: "R9",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_120),
            durationSec: 120,
            titleHint: nil,
            sampleFormat: "aac-64k-mono"
        )
        let asset = URL(fileURLWithPath: "/tmp/r9.m4a")
        let record = try CloudRecordFactory.record(
            for: upload, modifiedAt: Date(timeIntervalSince1970: 1_700_000_200), assetFileURL: asset
        )
        XCTAssertEqual(record.recordName, "recupload-R9")
        XCTAssertEqual(record.zone, .relay)
        XCTAssertEqual(record.kind, "recording_upload")
        XCTAssertEqual(record.assetFileURL, asset)
        XCTAssertNil(record.notifyLevel)

        // The desktop's status write-back drops the asset.
        var ack = upload
        ack.status = .received
        let writeBack = try CloudRecordFactory.record(
            for: ack, modifiedAt: Date(timeIntervalSince1970: 1_700_000_300), assetFileURL: nil
        )
        XCTAssertNil(writeBack.assetFileURL)
        XCTAssertEqual(writeBack.recordName, record.recordName)
    }

    func testAssetURLSurvivesInMemoryTransportRoundTrip() async throws {
        let transport = InMemoryCloudTransport()
        let asset = URL(fileURLWithPath: "/tmp/roundtrip.m4a")
        let record = CloudRecord(
            recordName: "recupload-RT",
            zone: .relay,
            kind: "recording_upload",
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            payload: Data("{}".utf8),
            assetFileURL: asset
        )
        try await transport.save([record])
        let batch = try await transport.changes(in: .relay, since: nil)
        XCTAssertEqual(batch.changed.first?.assetFileURL, asset)
    }
}
