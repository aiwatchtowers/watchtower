import WatchtowerE2ETesting
import XCTest
@testable import WatchtowerSync

/// RelayFeed routing for `recording_upload` records: hub verdicts reach the
/// `RecordingUploadAcking` seam, the phone's own pending saves are skipped,
/// and a missing uploader only skips (never wedges the token).
final class RelayFeedRecordingUploadTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private actor CapturingUploads: RecordingUploadAcking {
        private(set) var echoes: [RecordingUploadPayload] = []
        func applyEcho(_ upload: RecordingUploadPayload) async throws {
            echoes.append(upload)
        }
    }

    /// The paired test phone's feed and the test hub over one in-memory zone; the hub seals its verdicts to the
    /// phone named in the payload's `device_id`.
    private struct Stack {
        let phone: SecureTransport
        let hub: SecureTransport
        let store: ReplicaStore
        let feed: RelayFeed
    }

    private func makeStack(uploads: (any RecordingUploadAcking)?) throws -> Stack {
        let inner = InMemoryCloudTransport()
        let keys = try TestE2E.phoneStore()
        let phone = TestE2E.phoneTransport(try TestE2E.phone(store: keys), inner: inner)
        let store = try ReplicaStore.inMemory(opener: TestE2E.opener(store: keys))
        let feed = RelayFeed(
            transport: phone,
            store: store,
            outbox: ActionOutbox(transport: phone, store: store, deviceID: TestE2E.deviceID.uuidString),
            uploads: uploads
        )
        return Stack(phone: phone, hub: TestE2E.hubTransport(inner: inner), store: store, feed: feed)
    }

    private func uploadRecord(
        id: String,
        status: RecordingUploadStatus,
        errorMessage: String? = nil
    ) throws -> CloudRecord {
        var payload = RecordingUploadPayload(
            id: id,
            startedAt: base,
            endedAt: base.addingTimeInterval(60),
            durationSec: 60,
            titleHint: nil,
            sampleFormat: "aac-64k-mono",
            deviceID: TestE2E.deviceID.uuidString
        )
        payload.status = status
        payload.errorMessage = errorMessage
        return try CloudRecordFactory.record(for: payload, modifiedAt: base, assetFileURL: nil)
    }

    func testHubVerdictsRouteToTheSeam() async throws {
        let uploads = CapturingUploads()
        let stack = try makeStack(uploads: uploads)

        try await stack.hub.save([
            try uploadRecord(id: "R1", status: .received),
            try uploadRecord(id: "R2", status: .failed, errorMessage: "no asset")
        ])
        let result = try await stack.feed.pollOnce()

        XCTAssertEqual(result, 2)
        let routed = await uploads.echoes
        XCTAssertEqual(routed.map(\.id), ["R1", "R2"])
        XCTAssertEqual(routed.map(\.status), [.received, .failed])
    }

    func testOwnPendingSaveIsSkipped() async throws {
        let uploads = CapturingUploads()
        let stack = try makeStack(uploads: uploads)

        try await stack.phone.save([try uploadRecord(id: "R1", status: .pending)])
        let result = try await stack.feed.pollOnce()

        XCTAssertEqual(result, 0)
        let routed = await uploads.echoes
        XCTAssertTrue(routed.isEmpty)
    }

    func testMissingUploaderSkipsWithoutWedgingTheToken() async throws {
        let stack = try makeStack(uploads: nil)

        try await stack.hub.save([try uploadRecord(id: "R1", status: .received)])
        _ = try await stack.feed.pollOnce()

        // The token advanced past the skipped record: an empty follow-up
        // poll routes nothing and the stored token matches the zone head.
        let token = try XCTUnwrap(try stack.store.relayToken())
        XCTAssertEqual(token.value, 1)
    }
}
