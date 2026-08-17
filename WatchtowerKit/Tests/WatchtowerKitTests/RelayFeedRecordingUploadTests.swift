import XCTest
@testable import WatchtowerKit

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

    private func makeFeed(
        transport: InMemoryCloudTransport,
        store: ReplicaStore,
        uploads: (any RecordingUploadAcking)?
    ) -> RelayFeed {
        RelayFeed(
            transport: transport,
            store: store,
            outbox: ActionOutbox(transport: transport, store: store),
            uploads: uploads
        )
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
            sampleFormat: "aac-64k-mono"
        )
        payload.status = status
        payload.errorMessage = errorMessage
        return try CloudRecordFactory.record(for: payload, modifiedAt: base, assetFileURL: nil)
    }

    func testHubVerdictsRouteToTheSeam() async throws {
        let transport = InMemoryCloudTransport()
        let store = try ReplicaStore.inMemory()
        let uploads = CapturingUploads()
        let feed = makeFeed(transport: transport, store: store, uploads: uploads)

        try await transport.save([
            try uploadRecord(id: "R1", status: .received),
            try uploadRecord(id: "R2", status: .failed, errorMessage: "no asset")
        ])
        let result = try await feed.pollOnce()

        XCTAssertEqual(result.echoes, 2)
        let routed = await uploads.echoes
        XCTAssertEqual(routed.map(\.id), ["R1", "R2"])
        XCTAssertEqual(routed.map(\.status), [.received, .failed])
    }

    func testOwnPendingSaveIsSkipped() async throws {
        let transport = InMemoryCloudTransport()
        let store = try ReplicaStore.inMemory()
        let uploads = CapturingUploads()
        let feed = makeFeed(transport: transport, store: store, uploads: uploads)

        try await transport.save([try uploadRecord(id: "R1", status: .pending)])
        let result = try await feed.pollOnce()

        XCTAssertEqual(result.echoes, 0)
        let routed = await uploads.echoes
        XCTAssertTrue(routed.isEmpty)
    }

    func testMissingUploaderSkipsWithoutWedgingTheToken() async throws {
        let transport = InMemoryCloudTransport()
        let store = try ReplicaStore.inMemory()
        let feed = makeFeed(transport: transport, store: store, uploads: nil)

        try await transport.save([try uploadRecord(id: "R1", status: .received)])
        _ = try await feed.pollOnce()

        // The token advanced past the skipped record: an empty follow-up
        // poll routes nothing and the stored token matches the zone head.
        let token = try XCTUnwrap(try store.relayToken())
        XCTAssertEqual(token.value, 1)
    }
}
