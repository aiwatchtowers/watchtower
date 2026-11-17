import Foundation
import GRDB
import os
import WatchtowerCore
import WatchtowerInterface

/// A tower that serves one `"desktop": true` case of the Go feed fixture
/// (`internal/inboxfeed/testdata/inbox_feed_cases.json`, regenerated and
/// checked by `TestInboxFeedCases`). The test's database is seeded with the
/// case's SQL; `inbox.feed` answers the case's `expect` until a step's write
/// has landed on that database (its Go-written `when` query holds), then
/// that step's `expect`. The Mac lists what Go lists: no test filters cards.
package final class FeedCaseTransport: TowerTransport, @unchecked Sendable {
    /// One case of the fixture (the fields the Desktop reads).
    package struct Case: Decodable, Sendable {
        package let name: String
        package let seed: [String]
        package let expect: Feed
        package let desktop: Bool
        package let steps: [Step]

        private enum CodingKeys: String, CodingKey { case name, seed, expect, desktop, steps }

        package init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            seed = try container.decode([String].self, forKey: .seed)
            expect = try container.decode(Feed.self, forKey: .expect)
            desktop = try container.decodeIfPresent(Bool.self, forKey: .desktop) ?? false
            steps = try container.decodeIfPresent([Step].self, forKey: .steps) ?? []
        }
    }

    /// One write of a case: its SQL (a write from elsewhere: the CLI,
    /// another process), the query telling it landed, and the feed after it.
    package struct Step: Decodable, Sendable {
        package let name: String
        package let sql: [String]?
        package let when: String
        package let expect: Feed
    }

    private struct State {
        var served: Int?
        var acts: [ActRequest] = []
        var feedReads = 0
    }

    package let fixture: Case
    private let pool: DatabasePool
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// The case `name` over `pool` (not seeded yet: `seed()`).
    package init(_ name: String, pool: DatabasePool) throws {
        guard let found = try Self.cases().first(where: { $0.name == name }) else {
            throw FixtureError.noCase(name)
        }
        guard found.desktop else { throw FixtureError.notDesktop(name) }
        fixture = found
        self.pool = pool
    }

    /// The case `name`, its database seeded: the folders Go's migration
    /// makes (the root, Needs approval, revision 1), then the case's seed.
    package static func seeded(_ name: String, pool: DatabasePool) throws -> FeedCaseTransport {
        let transport = try FeedCaseTransport(name, pool: pool)
        try transport.seed()
        return transport
    }

    /// Seeds the test's database as Go seeds the case's.
    package func seed() throws {
        try seedFolders()
        let seed = fixture.seed
        try pool.write { db in
            for statement in seed { try db.execute(sql: statement) }
        }
    }

    /// The folders Go's migration makes (the root 1, Needs approval 2,
    /// revision 1), unless the test made its own: the feed's folder ids.
    package func seedFolders() throws {
        try pool.write { db in
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM inbox_folders") == 0 else { return }
            try db.execute(sql: """
                INSERT INTO inbox_folders (id, kind, parent_id, slug, title, icon, position)
                VALUES (1, 'root', NULL, 'inbox', 'Inbox', '', 0),
                       (2, 'approvals', 1, 'needs-approval', 'Needs approval', '', 0);
                INSERT OR IGNORE INTO inbox_folder_state (id, revision) VALUES (1, 1);
                """)
        }
    }

    /// The case's feed for a test whose own setUp seeded the rows the case
    /// mirrors: throws unless the database's folder tree is the feed's.
    package func mirroredFeed() throws -> Feed {
        let feed = current().feed
        let rows = try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT id, kind, parent_id, slug, title, position FROM inbox_folders ORDER BY id")
        }
        .map { row in
            "\(row["id"] as Int64) \(row["kind"] as String) \((row["parent_id"] as Int64?) ?? 0) "
                + "\(row["slug"] as String) \(row["title"] as String) \(row["position"] as Int)"
        }
        let folders = feed.folders.sorted { $0.id < $1.id }
            .map { "\($0.id) \($0.kind.rawValue) \($0.parentID ?? 0) \($0.slug) \($0.title) \($0.position)" }
        guard rows == folders else { throw FixtureError.notMirrored(fixture.name, rows: rows, feed: folders) }
        return feed
    }

    /// Makes step `name`'s write on the test's database (the write the CLI
    /// or another process makes in the case).
    package func write(_ name: String) throws {
        guard let step = fixture.steps.first(where: { $0.name == name }), let sql = step.sql else {
            throw FixtureError.noStep(name)
        }
        try pool.write { db in
            for statement in sql { try db.execute(sql: statement) }
        }
    }

    /// The feed of the last step whose write has landed, else the seed's;
    /// and that step's index (nil: the seed's).
    package func current() -> (feed: Feed, step: Int?) {
        let steps = fixture.steps
        let landed = try? pool.read { db in
            steps.lastIndex { step in ((try? Int.fetchOne(db, sql: step.when)) ?? 0) != 0 }
        }
        return (landed.map { steps[$0].expect } ?? fixture.expect, landed)
    }

    /// A step's write has landed (or gone) since the last `inbox.feed` read.
    package var hasNewStep: Bool {
        let step = current().step
        return state.withLock { $0.feedReads == 0 || $0.served != step }
    }

    /// The sidebar's Inbox badge as the app reads it beside the screen: one
    /// `inbox.feed` read through a `TowerClient`, its visible folders'
    /// counts summed (`InboxRootModel.countBadge`); nil when it fails.
    @MainActor
    package func badge() async -> Int? {
        let client = TowerClient(transport: self, clock: ContinuousClock(), restartDaemon: nil, startDaemon: nil)
        guard let feed: Feed = await client.readAside(.inboxFeed, params: FeedRequest(limit: 1)) else { return nil }
        return InboxRootModel(feed: feed, platform: .mac).countBadge
    }

    /// The number of `inbox.feed` reads answered.
    package var feedReads: Int { state.withLock { $0.feedReads } }

    /// Every `inbox.act` request, in order (each is answered ok).
    package var acts: [ActRequest] { state.withLock { $0.acts } }

    package func call(_ request: Request) async throws -> Response {
        switch request.command {
        case TowerCommand.towerHello.rawValue:
            return try Self.ok(request, HelloResponse(
                interfaceVersion: InterfaceVersion.current, build: "test", syncPaused: false, noSync: false))
        case TowerCommand.inboxFeed.rawValue:
            let (feed, step) = current()
            state.withLock { $0.served = step; $0.feedReads += 1 }
            return try Self.ok(request, feed)
        case TowerCommand.inboxAct.rawValue:
            if let params = request.params, let act = try? JSONDecoder().decode(ActRequest.self, from: params.data) {
                state.withLock { $0.acts.append(act) }
            }
            return try Self.ok(request, ActResult())
        default:
            return Response(id: request.id, status: .refused, refusal: Refusal(code: .unsupported, sentence: "no"))
        }
    }

    /// A watch that stays open and quiet: the test's refreshes read the feed.
    package func watch(_ request: Request) -> AsyncThrowingStream<ChangedEvent, Error> {
        AsyncThrowingStream { _ in }
    }

    private static func ok(_ request: Request, _ value: some Encodable) throws -> Response {
        Response(id: request.id, status: .ok, result: try RawJSON(data: JSONEncoder().encode(value)))
    }

    package enum FixtureError: Error, CustomStringConvertible {
        case noCase(String)
        case notDesktop(String)
        case noStep(String)
        case notMirrored(String, rows: [String], feed: [String])

        package var description: String {
            switch self {
            case let .noCase(name): "inbox_feed_cases.json has no case \(name)"
            case let .notDesktop(name): "case \(name) is not marked \"desktop\": true"
            case let .noStep(name): "the case has no SQL step \(name)"
            case let .notMirrored(name, rows, feed): "case \(name) does not mirror the test's folders: \(rows) vs \(feed)"
            }
        }
    }

    private static let loaded = Result { () throws -> [Case] in
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Support
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent()
        let url = root.appendingPathComponent("internal/inboxfeed/testdata/inbox_feed_cases.json")
        return try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
    }

    private static func cases() throws -> [Case] { try loaded.get() }
}

package extension ActionStripViewModel {
    /// Reads the Inbox from `transport` as the app reads the tower (a loader
    /// over a `TowerClient`), and keeps following it: after every refresh
    /// that finds a newly landed step (the VM's own write, a CLI's, a poll's
    /// read of another process's), the tower is read again and listed.
    @MainActor
    func follow(_ transport: FeedCaseTransport) async {
        let client = TowerClient(transport: transport, clock: ContinuousClock(), restartDaemon: nil, startDaemon: nil)
        let loader = InboxFeedLoader(client: client) { FeedRequest() }
        attach(loader)
        // Each answer is listed here, then read at once (`list`), so no
        // records read the listing starts is left running when a test acts.
        loader.onFeed = nil
        let previous = onFeedRefreshed
        onFeedRefreshed = { [weak self, weak loader] in
            if let self, let loader, transport.hasNewStep { await self.list(loader) }
            await previous?()
        }
        await list(loader)
    }

    /// One read of the loader, waited for; its feed listed and the panes'
    /// records read. The refresh starts in the same turn as the listing, so
    /// the refresh `receiveTowerFeed` queues joins it instead of trailing it.
    @MainActor
    private func list(_ loader: InboxFeedLoader) async {
        loader.reload()
        while let read = loader.pendingRead { await read.value }
        guard let feed = loader.feed else { return }
        receiveTowerFeed(feed)
        await refresh()
    }
}
