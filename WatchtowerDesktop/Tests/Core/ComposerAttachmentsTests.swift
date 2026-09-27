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

    func testAddKeepsValidAndReportsRejected() throws {
        let model = ComposerAttachments(store: ChatAttachmentStore(db: dbQueue, rootDir: root))
        model.add(urls: [try source("a.png", AttachmentValidatorTests.png), try source("b.zip", AttachmentValidatorTests.zip)],
                  conversationID: conversationID)
        XCTAssertEqual(model.pending.map(\.name), ["a.png"])
        XCTAssertEqual(model.errorMessage, AttachmentRejection.unsupportedType(fileName: "b.zip").message)

        model.add(urls: [try source("c.md", Data("x".utf8))], conversationID: conversationID)
        XCTAssertNil(model.errorMessage, "a clean add clears the previous rejection")
    }

    func testRemoveDiscardsRowAndFile() throws {
        let model = ComposerAttachments(store: ChatAttachmentStore(db: dbQueue, rootDir: root))
        model.add(urls: [try source("a.png", AttachmentValidatorTests.png)], conversationID: conversationID)
        let path = try XCTUnwrap(model.pending.first?.path)
        model.remove(id: try XCTUnwrap(model.pending.first?.id))
        XCTAssertTrue(model.pending.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testTakeForSendHandsOverAndClears() throws {
        let model = ComposerAttachments(store: ChatAttachmentStore(db: dbQueue, rootDir: root))
        model.addPastedImage(AttachmentValidatorTests.png, conversationID: conversationID)
        let taken = model.takeForSend()
        XCTAssertEqual(taken.map(\.name), ["Pasted image.png"])
        XCTAssertTrue(model.pending.isEmpty)
        XCTAssertNil(model.errorMessage)
    }

    func testNoWorkspaceSaysSo() {
        let model = ComposerAttachments(store: nil)
        model.add(urls: [URL(fileURLWithPath: "/tmp/x.png")], conversationID: 1)
        XCTAssertTrue(model.pending.isEmpty)
        XCTAssertEqual(model.errorMessage, "Attachments need an active workspace")
    }
}
