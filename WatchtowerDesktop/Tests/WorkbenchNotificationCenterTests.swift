import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

final class RecordingWorkbenchNotifier: WorkbenchNotifying, @unchecked Sendable {
    private(set) var sent: [WorkbenchNotice] = []
    func sendWorkbenchNotice(_ notice: WorkbenchNotice) { sent.append(notice) }
}

/// Fails one named project's read and delegates every other one to the real
/// reader, so a test can pin that one project's error never skips the rest
/// of the poll (T18).
struct FailingWorkbenchActivityReader: WorkbenchActivityReading {
    struct Boom: Error {}
    let failingWorkbenchID: Int64
    func snapshot(_ db: Database, project: Workbench, afterAgentCommentID: Int64) throws -> WorkbenchNotificationPolicy.Snapshot {
        if project.id == failingWorkbenchID { throw Boom() }
        return try DefaultWorkbenchActivityReader().snapshot(db, project: project, afterAgentCommentID: afterAgentCommentID)
    }
}

@MainActor
final class WorkbenchNotificationCenterTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!
    private var notifier: RecordingWorkbenchNotifier!
    private var projectID: Int64!
    private var targetID: Int64!

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "ProjectNotificationCenterTests-\(UUID().uuidString)"))
        notifier = RecordingWorkbenchNotifier()
        (projectID, targetID) = try pool.write { d in
            let p = try TestDatabase.insertWorkbench(d)
            return (p, try TestDatabase.insertWorkbenchTarget(d, projectID: p, text: "Task 1"))
        }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    private func makeCenter(activityReader: WorkbenchActivityReading = DefaultWorkbenchActivityReader()) -> WorkbenchNotificationCenter {
        WorkbenchNotificationCenter(dbPool: pool, notifier: notifier, activityReader: activityReader, defaults: defaults)
    }

    private func write(_ body: @escaping (Database) throws -> Void) async throws {
        try await pool.write { try body($0) }
    }

    func testFirstPollBaselinesSilentlyThenReportsWhatIsNew() async throws {
        try await write { _ = try TestDatabase.insertWorkbenchComment($0, projectID: self.projectID, targetID: self.targetID) }
        let center = makeCenter()
        await center.poll()
        XCTAssertTrue(notifier.sent.isEmpty, "a project seen for the first time never replays its history")

        try await write { _ = try TestDatabase.insertWorkbenchComment($0, projectID: self.projectID, body: "Which queue?", targetID: self.targetID) }
        await center.poll()
        XCTAssertEqual(notifier.sent.map(\.title), ["Agent asks on Task 1"])
        await center.poll()
        XCTAssertEqual(notifier.sent.count, 1, "the watermark moved: no repeat")
    }

    func testWatermarkSurvivesRelaunch() async throws {
        await makeCenter().poll()
        try await write { _ = try TestDatabase.insertWorkbenchComment($0, projectID: self.projectID, targetID: self.targetID) }
        await makeCenter().poll()   // a new center = a relaunched app, same defaults
        XCTAssertEqual(notifier.sent.count, 1)
        await makeCenter().poll()
        XCTAssertEqual(notifier.sent.count, 1)
    }

    func testOwnerCommentNeverNotifies() async throws {
        let center = makeCenter()
        await center.poll()
        try await write { _ = try TestDatabase.insertWorkbenchComment($0, projectID: self.projectID, author: "owner", targetID: self.targetID) }
        await center.poll()
        XCTAssertTrue(notifier.sent.isEmpty)
    }

    func testOwnerResolvingTheLastCommentDoesNotAnnounceAllAnswered() async throws {
        var root: Int64 = 0
        try await write { d in
            let doc = try TestDatabase.insertWorkbenchDocument(d, projectID: self.projectID, title: "Plan")
            root = try TestDatabase.insertWorkbenchComment(d, projectID: self.projectID, author: "owner", documentID: doc, quote: "x")
        }
        let center = makeCenter()
        await center.poll()
        let doc = try await pool.read { try Int64.fetchOne($0, sql: "SELECT id FROM project_documents") }
        try await write { try WorkbenchQueries.setStatus($0, commentID: root, status: "resolved") }
        center.recordOwnerWrite(projectID: projectID, subject: .document(try XCTUnwrap(doc)))
        await center.poll()
        XCTAssertTrue(notifier.sent.isEmpty)
    }

    func testAgentResolvingTheLastCommentAnnouncesAllAnswered() async throws {
        var root: Int64 = 0
        try await write { d in
            let doc = try TestDatabase.insertWorkbenchDocument(d, projectID: self.projectID, title: "Plan")
            root = try TestDatabase.insertWorkbenchComment(d, projectID: self.projectID, author: "owner", documentID: doc, quote: "x")
        }
        let center = makeCenter()
        await center.poll()
        try await write { try $0.execute(sql: "UPDATE project_comments SET status = 'resolved' WHERE id = ?", arguments: [root]) }
        await center.poll()
        XCTAssertEqual(notifier.sent.map(\.title), ["All comments on Plan answered"])
        XCTAssertEqual(notifier.sent.first?.route.pane, .documents)
    }

    func testSeededBaselineReportsADocumentAttachedRightAfterCreate() async throws {
        let center = makeCenter()
        let pid = try XCTUnwrap(projectID)
        let fetched = try await pool.read { try WorkbenchQueries.fetch($0, id: pid) }
        let project = try XCTUnwrap(fetched)
        center.seedBaseline(project: project)
        try await write { _ = try TestDatabase.insertWorkbenchDocument($0, projectID: self.projectID, title: "Spec") }
        await center.poll()
        XCTAssertEqual(notifier.sent.map(\.title), ["Spec ready for review"])
    }

    func testDisabledOrQuietHoursSendNothingButStillAdvanceTheWatermark() async throws {
        let center = makeCenter()
        await center.poll()
        defaults.set(false, forKey: WorkbenchNotificationCenter.enabledKey)
        try await write { _ = try TestDatabase.insertWorkbenchComment($0, projectID: self.projectID, targetID: self.targetID) }
        await center.poll()
        XCTAssertTrue(notifier.sent.isEmpty)

        defaults.set(true, forKey: WorkbenchNotificationCenter.enabledKey)
        defaults.set(true, forKey: "quietHoursEnabled")
        try await write { _ = try TestDatabase.insertWorkbenchComment($0, projectID: self.projectID, targetID: self.targetID) }
        await center.poll()
        XCTAssertTrue(notifier.sent.isEmpty)

        defaults.set(false, forKey: "quietHoursEnabled")
        await center.poll()
        XCTAssertTrue(notifier.sent.isEmpty, "turning notifications back on never replays what happened while off")
    }

    func testPollReloadsTheProjectsList() async {
        let center = makeCenter()
        var reloaded = 0
        center.onPolled = { reloaded += 1 }
        await center.poll()
        XCTAssertEqual(reloaded, 1)
    }

    // T18: one project's read failing must not skip the others' polls (nor
    // abort the whole cycle's prune) — only that project stays unreported.
    func testOneProjectsFailingReadDoesNotSkipTheOthers() async throws {
        let (otherID, otherTarget) = try await pool.write { d in
            let p = try TestDatabase.insertWorkbench(d, name: "beta", folder: "/tmp/beta")
            return (p, try TestDatabase.insertWorkbenchTarget(d, projectID: p, text: "Other task"))
        }
        let center = makeCenter(activityReader: FailingWorkbenchActivityReader(failingWorkbenchID: projectID))
        await center.poll() // baseline both, projectID's read fails every time

        try await write { _ = try TestDatabase.insertWorkbenchComment($0, projectID: self.projectID, targetID: self.targetID) }
        try await write { _ = try TestDatabase.insertWorkbenchComment($0, projectID: otherID, targetID: otherTarget) }
        await center.poll()

        XCTAssertEqual(notifier.sent.map(\.title), ["Agent asks on Other task"],
                       "the healthy project is still reported despite the other one's read failing")
        XCTAssertNotNil(defaults.data(forKey: WorkbenchNotificationCenter.snapshotKey(otherID)),
                        "the healthy project's snapshot is still saved")
    }

    func testDeletedProjectSnapshotIsPruned() async throws {
        let center = makeCenter()
        await center.poll()
        XCTAssertNotNil(defaults.data(forKey: WorkbenchNotificationCenter.snapshotKey(projectID)))
        try await write { try $0.execute(sql: "DELETE FROM projects WHERE id = ?", arguments: [self.projectID]) }
        await center.poll()
        XCTAssertNil(defaults.data(forKey: WorkbenchNotificationCenter.snapshotKey(projectID)))
    }
}
