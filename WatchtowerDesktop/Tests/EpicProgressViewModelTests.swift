import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The weekly digest's progress section: Jira epics, Linear projects and the
/// active sprints and cycles, loaded from the tracker views.
@MainActor
final class EpicProgressViewModelTests: XCTestCase {
    func testLoadFillsEpicsProjectsAndIterations() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let iso = ISO8601DateFormatter()
        try manager.dbPool.write { db in
            let jira = try TestDatabase.insertJiraAccount(db)
            let linear = try TestDatabase.insertLinearAccount(db)
            try TestDatabase.insertJiraIssue(db, account: jira, key: "PROJ-100") { $0.summary = "Checkout epic" }
            for n in 1...3 {
                try TestDatabase.insertJiraIssue(db, account: jira, key: "PROJ-\(n)") { $0.epicKey = "PROJ-100" }
            }
            try db.execute(sql: "INSERT INTO linear_projects (account_id, id, name) VALUES (?, 'p1', 'Onboarding revamp')",
                           arguments: [linear])
            try db.execute(sql: "INSERT INTO linear_cycles (account_id, id, number, ends_at) VALUES (?, 'c1', 4, ?)",
                           arguments: [linear, iso.string(from: Date().addingTimeInterval(2 * 86400))])
            for n in 1...3 {
                try TestDatabase.insertLinearIssue(db, account: linear, id: "l\(n)", key: "ENG-\(n)") {
                    $0.projectID = "p1"; $0.cycleID = "c1"
                    if n == 1 { $0.category = "done" }
                }
            }
        }
        let vm = EpicProgressViewModel(dbManager: manager)
        vm.load()
        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(Set(vm.epics.map(\.row.name)), ["Checkout epic", "Onboarding revamp"])
        XCTAssertEqual(vm.iterations.map(\.name), ["Cycle 4"])
        XCTAssertEqual(vm.iterations.first?.done, 1)
        XCTAssertEqual(vm.iterations.first?.total, 3)
    }

    /// A Linear-only install shows the weekly progress section but never the
    /// "without Jira" warning.
    func testDigestProgressGateOnALinearOnlyInstall() {
        XCTAssertTrue(DigestDetailView.showsTrackerProgress(jiraConnected: false, connected: ConnectedSources(linear: true)))
        XCTAssertFalse(DigestDetailView.showsWithoutJiraWarning(jiraConnected: false, detectionEnabled: true))
        XCTAssertTrue(DigestDetailView.showsTrackerProgress(jiraConnected: true, connected: .none))
        XCTAssertTrue(DigestDetailView.showsWithoutJiraWarning(jiraConnected: true, detectionEnabled: true))
        XCTAssertFalse(DigestDetailView.showsTrackerProgress(jiraConnected: false, connected: ConnectedSources(slack: true)))
    }
}
