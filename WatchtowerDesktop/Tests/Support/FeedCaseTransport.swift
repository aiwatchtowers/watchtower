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
        package let desktop: Bool?
        package let steps: [Step]?
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
        guard found.desktop == true else { throw FixtureError.notDesktop(name) }
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

    /// Makes step `name`'s write on the test's database (the write the CLI
    /// or another process makes in the case).
    package func write(_ name: String) throws {
        guard let step = fixture.steps?.first(where: { $0.name == name }), let sql = step.sql else {
            throw FixtureError.noStep(name)
        }
        try pool.write { db in
            for statement in sql { try db.execute(sql: statement) }
        }
    }

    /// The feed of the last step whose write has landed, else the seed's;
    /// and that step's index (nil: the seed's).
    package func current() -> (feed: Feed, step: Int?) {
        let steps = fixture.steps ?? []
        let landed = (try? pool.read { db in
            steps.lastIndex { step in ((try? Int.fetchOne(db, sql: step.when)) ?? 0) != 0 }
        }) ?? nil
        return (landed.map { steps[$0].expect } ?? fixture.expect, landed)
    }

    /// A step's write has landed (or gone) since the last `inbox.feed` read.
    package var hasNewStep: Bool {
        let step = current().step
        return state.withLock { $0.feedReads == 0 || $0.served != step }
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

        package var description: String {
            switch self {
            case let .noCase(name): "inbox_feed_cases.json has no case \(name)"
            case let .notDesktop(name): "case \(name) is not marked \"desktop\": true"
            case let .noStep(name): "the case has no SQL step \(name)"
            }
        }
    }

    private static let loaded = Result { () throws -> [Case] in
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
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
        let previous = onFeedRefreshed
        onFeedRefreshed = { [weak self, weak loader] in
            if let self, let loader, transport.hasNewStep {
                await Self.read(loader)
                await self.refresh()
            }
            await previous?()
        }
        await Self.read(loader)
        await refresh()
    }

    /// One read of the loader, waited for (its answer is listed at once).
    @MainActor
    private static func read(_ loader: InboxFeedLoader) async {
        loader.reload()
        while let read = loader.pendingRead { await read.value }
    }
}
