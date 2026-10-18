import Foundation
import GRDB
import WatchtowerCore
import WatchtowerSync

/// The `session_chat` slice, record name `session_chat-<session id>` (a
/// subagent's feed: `session_chat-<session id>-<agent id>`): the capped chat
/// of a workbench session (`SessionChatPayload`). It publishes only what
/// `SessionChatRunner` holds for the feeds the phone currently watches, so a
/// session the phone never opened has no record, and a record leaves the
/// phone when its watch expires. Not an urgent kind. Wire shape: the Kit
/// mirror `WatchtowerKit.SessionChat`.
struct SessionChatSlice: SliceSource {
    let kind = SliceKind.sessionChat

    let runner: SessionChatRunner

    func records(_ db: Database) throws -> [SliceRecord] {
        runner.snapshots().map {
            SliceRecord(kind: kind, id: $0.id, modifiedAt: $0.fetchedAt, payload: $0.payload)
        }
    }
}
