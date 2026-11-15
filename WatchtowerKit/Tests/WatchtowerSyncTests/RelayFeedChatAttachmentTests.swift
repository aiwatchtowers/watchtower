import WatchtowerE2ETesting
import XCTest
@testable import WatchtowerSync

/// RelayFeed routing for `chat_attachment` records (iPhone chat spec §4.5): hub verdicts reach the
/// `ChatAttachmentAcking` seam, the phone's own pending save is skipped, and the phone's sealed upload is a relay
/// record the hub side reads as `chat_attachment`.
final class RelayFeedChatAttachmentTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private actor Capturing: ChatAttachmentAcking {
        private(set) var echoes: [ChatAttachmentUploadPayload] = []
        func applyEcho(_ upload: ChatAttachmentUploadPayload) async throws { echoes.append(upload) }
    }

    private struct Stack {
        let inner: InMemoryCloudTransport
        let phone: SecureTransport
        let hub: SecureTransport
        let feed: RelayFeed
    }

    private func makeStack(chatUploads: (any ChatAttachmentAcking)?) throws -> Stack {
        let inner = InMemoryCloudTransport()
        let keys = try TestE2E.phoneStore()
        let phone = TestE2E.phoneTransport(try TestE2E.phone(store: keys), inner: inner)
        let store = try ReplicaStore.inMemory(opener: TestE2E.opener(store: keys))
        let feed = RelayFeed(
            transport: phone,
            store: store,
            outbox: ActionOutbox(transport: phone, store: store, deviceID: TestE2E.deviceID.uuidString),
            chatUploads: chatUploads
        )
        return Stack(inner: inner, phone: phone, hub: TestE2E.hubTransport(inner: inner), feed: feed)
    }

    private func payload(_ status: ChatAttachmentUploadStatus) -> ChatAttachmentUploadPayload {
        var payload = ChatAttachmentUploadPayload(
            uploadID: "U1", conversationID: 2, name: "notes.md", mime: "text/markdown", size: 6,
            deviceID: TestE2E.deviceID.uuidString)
        payload.status = status
        if status == .applied { payload.attachmentID = 9 }
        return payload
    }

    private func record(_ status: ChatAttachmentUploadStatus) throws -> CloudRecord {
        try CloudRecordFactory.record(for: payload(status), modifiedAt: base, assetFileURL: nil)
    }

    func testHubVerdictsRouteToTheSeam() async throws {
        let seam = Capturing()
        let stack = try makeStack(chatUploads: seam)
        try await stack.hub.save([try record(.applied)])
        let polled = try await stack.feed.pollOnce()
        XCTAssertEqual(polled, 1)
        let routed = await seam.echoes
        XCTAssertEqual(routed.map(\.status), [.applied])
        XCTAssertEqual(routed.first?.attachmentID, 9)
    }

    func testOwnPendingSaveIsSkippedAndAMissingConsumerDoesNotWedgeTheToken() async throws {
        let seam = Capturing()
        let stack = try makeStack(chatUploads: seam)
        try await stack.phone.save([try record(.pending)])
        let polled = try await stack.feed.pollOnce()
        XCTAssertEqual(polled, 0)
        let routed = await seam.echoes
        XCTAssertTrue(routed.isEmpty)

        let bare = try makeStack(chatUploads: nil)
        try await bare.hub.save([try record(.failed)])
        _ = try await bare.feed.pollOnce()
    }

    func testTheSealedUploadReachesTheHubAsAChatAttachment() async throws {
        let stack = try makeStack(chatUploads: nil)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("notes.md")
        try Data("# Hi\n".utf8).write(to: file)

        let sealed = try await ChatAttachmentUploader.seal(
            payload(.pending), file: file, sealedFile: dir.appendingPathComponent("U1.enc"), transport: stack.phone,
            modifiedAt: base)
        XCTAssertEqual(sealed.record.kind, WireKind.envelope)
        XCTAssertNotNil(sealed.record.assetFileURL)
        try await ChatAttachmentUploader.send(sealed, transport: stack.phone)

        let batch = try await stack.hub.changes(in: .relay, since: nil)
        let opened = try XCTUnwrap(batch.changed.first)
        XCTAssertEqual(opened.kind, "chat_attachment")
        XCTAssertEqual(opened.recordName, "chatupload-U1")
        let back = try RelayCoder.makeDecoder().decode(ChatAttachmentUploadPayload.self, from: opened.payload)
        XCTAssertEqual(back.uploadID, "U1")
        XCTAssertEqual(back.status, .pending)
        XCTAssertNotNil(opened.asset)
    }
}
