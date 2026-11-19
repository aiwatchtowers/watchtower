import Foundation
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The Inbox shots list what Go lists (Task 11e): each shot's database is
/// a `"desktop": true` case of `internal/inboxfeed/testdata/inbox_feed_cases.json`
/// (`desktop_shot_*`), seeded as Go seeds it, and the view model reads its
/// Go-written feed through the fake tower (`FeedCaseTransport`). No shot
/// builds an Inbox list in Swift.
@MainActor
enum InboxShotFeed {
    /// Seeds case `name` into `pool`: the folders Go's migration makes, then the case's rows.
    static func seeded(_ name: String, _ pool: DatabasePool) throws -> FeedCaseTransport {
        try FeedCaseTransport.seeded(name, pool: pool)
    }

    /// Lists the case through `vm` (its feed, then the panes' records),
    /// then runs `then`, awaited by the shot's `prepare`: no run-loop spin,
    /// no deadline.
    static func listed(
        _ vm: ActionStripViewModel, _ tower: FeedCaseTransport, then: @MainActor () async -> Void = {}
    ) async {
        await vm.follow(tower)
        await then()
    }
}
