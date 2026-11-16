import Foundation
import GRDB
import WatchtowerCore

// Test-only initializers in the shapes the tests used before the chat writes
// moved to Go: each wires a `FakeChatTower` over the same test database, so
// a test that writes through the Mac's code still finds its rows there.

extension ChatWrites {
    /// The chat writes over a `FakeChatTower` on `db`.
    package static func fake(_ db: any DatabaseWriter) -> ChatWrites {
        ChatWrites(tower: FakeChatTower(db: db))
    }
}

extension ArtifactPanelModel {
    package convenience init(db: any DatabaseWriter, conversationID: Int64, key: String) {
        self.init(db: db, writes: .fake(db), conversationID: conversationID, key: key)
    }
}

extension ArtifactCommentsModel {
    package convenience init(db: any DatabaseWriter, conversationID: Int64, key: String) {
        self.init(db: db, writes: .fake(db), conversationID: conversationID, key: key)
    }
}

extension ChatAttachmentStore {
    package convenience init(db: any DatabaseWriter, rootDir: URL) {
        self.init(db: db, rootDir: rootDir, writes: .fake(db))
    }
}

extension DatabaseEmbeddedChatStore {
    package convenience init(dbPool: DatabasePool, conversationID: Int64) {
        self.init(dbPool: dbPool, writes: .fake(dbPool), conversationID: conversationID)
    }

    package static func conversationID(
        dbPool: DatabasePool, contextType: String, contextID: String, title: String
    ) async throws -> Int64 {
        try await conversationID(dbPool: dbPool, writes: .fake(dbPool), contextType: contextType, contextID: contextID,
                                 title: title)
    }

    package static func rekeyConversation(
        dbPool: DatabasePool, conversationID: Int64, toContextType: String, contextID: String
    ) async throws -> Bool {
        try await rekeyConversation(writes: .fake(dbPool), conversationID: conversationID,
                                    toContextType: toContextType, contextID: contextID)
    }
}
