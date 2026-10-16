import Foundation
import GRDB
import Testing
@testable import WatchtowerCore
import WatchtowerTestSupport

@Suite("GuideQueries")
struct GuideQueriesTests {
    private func seed(_ db: Database) throws {
        try doc(db, id: "guide:features/inbox.md", source: "guide", title: "Inbox", chunks: [
            ("Why use it\nThe inbox gathers quarantine items.", "why-use-it"),
            ("Another section\nMore about quarantine items here.", "another-section")
        ])
        try doc(db, id: "guide:features/chat.md", source: "guide", title: "Chat", chunks: [
            ("Asking\nTalk to the assistant about a topic.", "asking")
        ])
        try doc(db, id: "slack:C1:1", source: "slack", title: "Chatter", chunks: [
            ("quarantine talk in slack", "")
        ])
    }

    private func doc(
        _ db: Database, id: String, source: String, title: String, chunks: [(String, String)]
    ) throws {
        try db.execute(
            sql: "INSERT INTO kb_documents (id, source, title, chunk_count) VALUES (?, ?, ?, ?)",
            arguments: [id, source, title, chunks.count]
        )
        for (idx, chunk) in chunks.enumerated() {
            try db.execute(
                sql: "INSERT INTO kb_chunks (doc_id, idx, title, body, anchor) VALUES (?, ?, ?, ?, ?)",
                arguments: [id, idx, title, chunk.0, chunk.1]
            )
        }
    }

    private func hits(_ query: String) throws -> [GuideHit] {
        let (pool, _) = try TestDatabase.createPool()
        return try pool.write { db in
            try seed(db)
            return try GuideQueries.search(db, query: query)
        }
    }

    @Test("a word in a guide doc and a Slack doc returns the guide doc only")
    func findsGuidePagesOnly() throws {
        let result = try hits("quarantine")
        #expect(result.map(\.path) == ["features/inbox.md"])
    }

    @Test("two matching chunks of one page give one hit")
    func oneHitPerPage() throws {
        #expect(try hits("quarantine").count == 1)
    }

    @Test("an FTS-hostile query returns nothing and does not throw")
    func hostileQueryDoesNotThrow() throws {
        #expect(try hits("\"*- AND").isEmpty)
        #expect(try hits("   ").isEmpty)
    }

    @Test("the hit URL carries the chunk anchor and the heading is display-only")
    func urlCarriesAnchor() throws {
        let hit = try #require(try hits("inbox gathers").first)
        #expect(hit.url.absoluteString.hasSuffix("features/inbox.md#why-use-it"))
        #expect(hit.heading == "Why use it")
        #expect(hit.title == "Inbox")
    }
}
