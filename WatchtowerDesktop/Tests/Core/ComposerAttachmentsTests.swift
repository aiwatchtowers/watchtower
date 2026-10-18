import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

@MainActor
final class ComposerAttachmentsTests: XCTestCase {
    private var dbQueue: DatabaseQueue!
    private var root: URL!
    private var src: URL!
    private var conversationID: Int64 = 0

    override func setUp() async throws {
        dbQueue = try TestDatabase.create()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cf-\(UUID().uuidString)")
        src = FileManager.default.temporaryDirectory.appendingPathComponent("cs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        conversationID = try await dbQueue.write { db in
            try db.execute(sql: "INSERT INTO chat_conversations (title, created_at, updated_at) VALUES ('', 0, 0)")
            return db.lastInsertedRowID
        }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: src)
    }

    private func source(_ name: String, _ data: Data) throws -> URL {
        let url = src.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func testAddKeepsValidAndReportsRejected() async throws {
        let model = ComposerAttachments(store: ChatAttachmentStore(db: dbQueue, rootDir: root))
        model.add(urls: [try source("a.png", AttachmentValidatorTests.png), try source("b.zip", AttachmentValidatorTests.zip)],
                  conversationID: conversationID)
        await model.settled()
        XCTAssertEqual(model.pending.map(\.name), ["a.png"])
        XCTAssertEqual(model.errorMessage, AttachmentRejection.unsupportedType(fileName: "b.zip").message)

        model.add(urls: [try source("c.md", Data("x".utf8))], conversationID: conversationID)
        await model.settled()
        XCTAssertNil(model.errorMessage, "a clean add clears the previous rejection")
    }

    func testRemoveDiscardsRowAndFile() async throws {
        let model = ComposerAttachments(store: ChatAttachmentStore(db: dbQueue, rootDir: root))
        model.add(urls: [try source("a.png", AttachmentValidatorTests.png)], conversationID: conversationID)
        await model.settled()
        let path = try XCTUnwrap(model.pending.first?.path)
        model.remove(id: try XCTUnwrap(model.pending.first?.id))
        XCTAssertEqual(model.pending.count, 1, "shown until its removal landed")
        await model.settled()
        XCTAssertTrue(model.pending.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testTakeForSendHandsOverAndClears() async throws {
        let model = ComposerAttachments(store: ChatAttachmentStore(db: dbQueue, rootDir: root))
        await model.addPasted(AttachmentValidatorTests.png, name: "Pasted image.png", conversationID: conversationID)
        let taken = model.takeForSend()
        XCTAssertEqual(taken.map(\.name), ["Pasted image.png"])
        XCTAssertTrue(model.pending.isEmpty)
        XCTAssertNil(model.errorMessage)
    }

    func testAddPastedReportsSuccessAndRejection() async {
        let model = ComposerAttachments(store: ChatAttachmentStore(db: dbQueue, rootDir: root))
        let attached = await model.addPasted(Data("long text".utf8), name: "Pasted text.txt", conversationID: conversationID)
        XCTAssertTrue(attached)
        XCTAssertEqual(model.pending.map(\.mime), ["text/plain"])
        let rejected = await model.addPasted(AttachmentValidatorTests.zip, name: "Pasted image.png",
                                             conversationID: conversationID)
        XCTAssertFalse(rejected)
        XCTAssertEqual(model.errorMessage, AttachmentRejection.unsupportedType(fileName: "Pasted image.png").message)
    }

    /// Board #670: an add that lands after the composer switched chats stays
    /// stored for its own chat and is not shown in the new one.
    func testAnAddLandingAfterAChatSwitchIsNotShown() async throws {
        let model = ComposerAttachments(store: ChatAttachmentStore(db: dbQueue, rootDir: root))
        model.add(urls: [try source("a.png", AttachmentValidatorTests.png)], conversationID: conversationID)
        model.replacePending(with: [])
        await model.settled()
        XCTAssertTrue(model.pending.isEmpty)
        let stored = try await dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM chat_attachments") }
        XCTAssertEqual(stored, 1, "kept as the first chat's pending file")
    }

    func testNoWorkspaceSaysSo() {
        let model = ComposerAttachments(store: nil)
        model.add(urls: [URL(fileURLWithPath: "/tmp/x.png")], conversationID: 1)
        XCTAssertTrue(model.pending.isEmpty)
        XCTAssertEqual(model.errorMessage, "Attachments need an active workspace")
    }
}
