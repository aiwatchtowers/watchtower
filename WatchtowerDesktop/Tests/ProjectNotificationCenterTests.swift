import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

final class RecordingProjectNotifier: ProjectNotifying, @unchecked Sendable {
    private(set) var sent: [ProjectNotice] = []
    func sendProjectNotice(_ notice: ProjectNotice) { sent.append(notice) }
}

@MainActor
final class ProjectNotificationCenterTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!
    private var notifier: RecordingProjectNotifier!
    private var projectID: Int64!
    private var targetID: Int64!

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "ProjectNotificationCenterTests-\(UUID().uuidString)"))
        notifier = RecordingProjectNotifier()
        (projectID, targetID) = try pool.write { d in
            let p = try TestDatabase.insertProject(d)
            return (p, try TestDatabase.insertProjectTarget(d, projectID: p, text: "Task 1"))
        }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    private func makeCenter() -> ProjectNotificationCenter {
        ProjectNotificationCenter(dbPool: pool, notifier: notifier, defaults: defaults)
    }

    private func write(_ body: @escaping (Database) throws -> Void) async throws {
        try await pool.write { try body($0) }
    }

    func testFirstPollBaselinesSilentlyThenReportsWhatIsNew() async throws {
        try await write { _ = try TestDatabase.insertProjectComment($0, projectID: self.projectID, targetID: self.targetID) }
        let center = makeCenter()
        await center.poll()
        XCTAssertTrue(notifier.sent.isEmpty, "a project seen for the first time never replays its history")

        try await write { _ = try TestDatabase.insertProjectComment($0, projectID: self.projectID, body: "Which queue?", targetID: self.targetID) }
        await center.poll()
        XCTAssertEqual(notifier.sent.map(\.title), ["Agent asks on Task 1"])
        await center.poll()
        XCTAssertEqual(notifier.sent.count, 1, "the watermark moved: no repeat")
    }

    func testWatermarkSurvivesRelaunch() async throws {
        await makeCenter().poll()
        try await write { _ = try TestDatabase.insertProjectComment($0, projectID: self.projectID, targetID: self.targetID) }
        await makeCenter().poll()   // a new center = a relaunched app, same defaults
        XCTAssertEqual(notifier.sent.count, 1)
        await makeCenter().poll()
        XCTAssertEqual(notifier.sent.count, 1)
    }

    func testOwnerCommentNeverNotifies() async throws {
        let center = makeCenter()
        await center.poll()
        try await write { _ = try TestDatabase.insertProjectComment($0, projectID: self.projectID, author: "owner", targetID: self.targetID) }
        await center.poll()
        XCTAssertTrue(notifier.sent.isEmpty)
    }

    func testOwnerResolvingTheLastCommentDoesNotAnnounceAllAnswered() async throws {
        var root: Int64 = 0
        try await write { d in
            let doc = try TestDatabase.insertProjectDocument(d, projectID: self.projectID, title: "Plan")
            root = try TestDatabase.insertProjectComment(d, projectID: self.projectID, author: "owner", documentID: doc, quote: "x")
        }
        let center = makeCenter()
        await center.poll()
        let doc = try await pool.read { try Int64.fetchOne($0, sql: "SELECT id FROM project_documents") }
        try await write { try ProjectQueries.setStatus($0, commentID: root, status: "resolved") }
        center.recordOwnerWrite(projectID: projectID, subject: .document(try XCTUnwrap(doc)))
        await center.poll()
        XCTAssertTrue(notifier.sent.isEmpty)
    }

    func testAgentResolvingTheLastCommentAnnouncesAllAnswered() async throws {
        var root: Int64 = 0
        try await write { d in
            let doc = try TestDatabase.insertProjectDocument(d, projectID: self.projectID, title: "Plan")
            root = try TestDatabase.insertProjectComment(d, projectID: self.projectID, author: "owner", documentID: doc, quote: "x")
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
        let fetched = try await pool.read { try ProjectQueries.fetch($0, id: pid) }
        let project = try XCTUnwrap(fetched)
        center.seedBaseline(project: project)
        try await write { _ = try TestDatabase.insertProjectDocument($0, projectID: self.projectID, title: "Spec") }
        await center.poll()
        XCTAssertEqual(notifier.sent.map(\.title), ["Spec ready for review"])
    }

    func testDisabledOrQuietHoursSendNothingButStillAdvanceTheWatermark() async throws {
        let center = makeCenter()
        await center.poll()
        defaults.set(false, forKey: ProjectNotificationCenter.enabledKey)
        try await write { _ = try TestDatabase.insertProjectComment($0, projectID: self.projectID, targetID: self.targetID) }
        await center.poll()
        XCTAssertTrue(notifier.sent.isEmpty)

        defaults.set(true, forKey: ProjectNotificationCenter.enabledKey)
        defaults.set(true, forKey: "quietHoursEnabled")
        try await write { _ = try TestDatabase.insertProjectComment($0, projectID: self.projectID, targetID: self.targetID) }
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

    func testDeletedProjectSnapshotIsPruned() async throws {
        let center = makeCenter()
        await center.poll()
        XCTAssertNotNil(defaults.data(forKey: ProjectNotificationCenter.snapshotKey(projectID)))
        try await write { try $0.execute(sql: "DELETE FROM projects WHERE id = ?", arguments: [self.projectID]) }
        await center.poll()
        XCTAssertNil(defaults.data(forKey: ProjectNotificationCenter.snapshotKey(projectID)))
    }
}
