import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerInterface
import WatchtowerTestSupport

/// The Inbox's feed line (mockup §7) as the view model reads it off its
/// loader: none without a loader, "Loading the Inbox…" before the first
/// list, none over a current list, and a failed read over the kept list
/// naming when it was read.
@MainActor
final class InboxFeedStatusTests: XCTestCase {
    func testTheLineFollowsTheLoader() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let tower = try FeedCaseTransport.seeded("desktop_rows_slack_item", pool: pool)
        let vm = ActionStripViewModel(dbPool: pool, cliRunner: FakeCLIRunner())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertNil(vm.feedStatus(now: now), "no loader: the Inbox reads only the database")

        let client = TowerClient(transport: tower, clock: ContinuousClock(), restartDaemon: nil, startDaemon: nil)
        vm.attach(InboxFeedLoader(client: client) { FeedRequest() })
        XCTAssertEqual(vm.feedStatus(now: now), InboxMacFeedStatus(kind: .loading, text: TowerText.loadingInboxMac))

        await vm.follow(tower)
        let loader = try XCTUnwrap(vm.feedLoader)
        XCTAssertNil(vm.feedStatus(now: now), "a current list has no line")

        let down = TowerFailure(kind: .down, sentence: TowerText.daemonDown)
        loader.showForShots(.ready(stale: nil), failure: down, reconnectingLine: false)
        let status = try XCTUnwrap(vm.feedStatus(now: now))
        XCTAssertEqual(status.kind, .failed)
        XCTAssertEqual(status.actionTitle, TowerText.retry)
        XCTAssertTrue(status.text.hasPrefix("Couldn't refresh the Inbox: \(TowerText.daemonDown). Showing the list from"),
                      status.text)
    }
}
