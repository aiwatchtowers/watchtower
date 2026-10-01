import XCTest
@testable import WatchtowerCore

final class ProjectDriftReportTests: XCTestCase {

    /// The shape `watchtower project check --json` prints (Go
    /// `projectcheck.Report`, cmd/project_check_test.go's JSON test).
    func testDecodesTheGoReport() throws {
        let json = """
        {"project_id":7,"git":true,"base":"origin/main","pr_checked":false,
         "findings":[
          {"target_id":12,"title":"Feature","status":"in_progress","branch":"feature/x",
           "kind":"merged_but_open","detail":"branch feature/x is merged into origin/main","fix":"set it done"},
          {"target_id":13,"title":"Task","status":"in_progress","kind":"stale","detail":"no movement","fix":"move it on"}],
         "notes":["gh CLI not found"]}
        """
        let report = try JSONDecoder().decode(ProjectDriftReport.self, from: Data(json.utf8))
        XCTAssertEqual(report.projectID, 7)
        XCTAssertEqual(report.base, "origin/main")
        XCTAssertFalse(report.incomplete)
        XCTAssertEqual(report.findings.count, 2)
        XCTAssertEqual(report.findings[0].branch, "feature/x")
        XCTAssertEqual(report.findings[1].pr, "")
        XCTAssertTrue(report.findings[0].isConflict)
        XCTAssertFalse(report.findings[1].isConflict, "stale is advisory, as in the Go hook")
        XCTAssertEqual(report.notes, ["gh CLI not found"])
    }

    func testDoneButUnmergedIsAdvisory() {
        let f = ProjectDriftFinding(targetID: 1, title: "t", status: "done", kind: "done_but_unmerged", detail: "", fix: "")
        XCTAssertFalse(f.isConflict)
        XCTAssertEqual(f.kindLabel, "Done, not merged")
    }

    func testAMinimalReportDecodes() throws {
        let report = try JSONDecoder().decode(ProjectDriftReport.self, from: Data(#"{"project_id":3,"findings":[]}"#.utf8))
        XCTAssertTrue(report.findings.isEmpty)
        XCTAssertFalse(report.git)
    }
}
