import Foundation
import GRDB
import Combine

/// Centralized GRDB ValueObservation manager for live UI updates
package final class DatabaseObserver: Sendable {
    private let dbPool: DatabasePool

    package init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    package func observeWorkspace() -> some Publisher<Workspace?, any Error> {
        ValueObservation.tracking { db in
            try Workspace.fetchOne(db, sql: "SELECT * FROM workspace LIMIT 1")
        }
        .removeDuplicates { $0?.syncedAt == $1?.syncedAt }
        .publisher(in: dbPool, scheduling: .async(onQueue: .main))
    }

    package func observeStats() -> some Publisher<WorkspaceStats, any Error> {
        ValueObservation.tracking { db in
            try WorkspaceStats.fetch(db)
        }
        .removeDuplicates()
        .publisher(in: dbPool, scheduling: .async(onQueue: .main))
    }

    package func observeMessages(channelID: String, limit: Int = 50) -> some Publisher<[Message], any Error> {
        ValueObservation.tracking { db in
            try Message.fetchAll(
                db,
                sql: """
                    SELECT * FROM messages
                    WHERE channel_id = ?
                    ORDER BY ts_unix DESC
                    LIMIT ?
                    """,
                arguments: [channelID, limit]
            )
        }
        .publisher(in: dbPool, scheduling: .async(onQueue: .main))
    }

    package func observeDigests(type: String? = nil, limit: Int = 50) -> some Publisher<[Digest], any Error> {
        ValueObservation.tracking { db in
            if let type {
                return try Digest.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM digests WHERE type = ?
                        ORDER BY created_at DESC LIMIT ?
                        """,
                    arguments: [type, limit]
                )
            } else {
                return try Digest.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM digests
                        ORDER BY created_at DESC LIMIT ?
                        """,
                    arguments: [limit]
                )
            }
        }
        .publisher(in: dbPool, scheduling: .async(onQueue: .main))
    }

    package func observeWatchList() -> some Publisher<[WatchItem], any Error> {
        ValueObservation.tracking { db in
            try WatchItem.fetchAll(db, sql: "SELECT * FROM watch_list ORDER BY created_at DESC")
        }
        .publisher(in: dbPool, scheduling: .async(onQueue: .main))
    }
}

package struct WorkspaceStats: Equatable {
    package var channelCount: Int
    package var userCount: Int
    package var messageCount: Int
    package var digestCount: Int

    package init(channelCount: Int, userCount: Int, messageCount: Int, digestCount: Int) {
        self.channelCount = channelCount
        self.userCount = userCount
        self.messageCount = messageCount
        self.digestCount = digestCount
    }

    package static func fetch(_ db: Database) throws -> Self {
        let channels = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM channels") ?? 0
        let users = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM users WHERE is_deleted = 0") ?? 0
        let messages = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages") ?? 0
        let digests = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM digests") ?? 0
        return Self(
            channelCount: channels,
            userCount: users,
            messageCount: messages,
            digestCount: digests
        )
    }
}
