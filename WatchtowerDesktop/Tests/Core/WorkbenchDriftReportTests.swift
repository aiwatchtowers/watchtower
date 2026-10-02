import XCTest
@testable import WatchtowerCore

final class WorkbenchDriftReportTests: XCTestCase {

    private func decode(_ json: String) throws -> WorkbenchDriftReport {
        try JSONDecoder().decode(WorkbenchDriftReport.self, from: Data(json.utf8))
    }

    /// The shape `watchtower workbench check --json` prints (Go
    /// `projectcheck.Report`, cmd/project_check_test.go's JSON test).
    func testDecodesTheGoReport() throws {
        let report = try decode("""
        {"project_id":7,"git":true,"base":"origin/main","pr_checked":false,
         "findings":[
          {"target_id":12,"title":"Feature","status":"in_progress","branch":"feature/x",
           "kind":"merged_but_open","detail":"branch feature/x is merged into origin/main","fix":"set it done"},
          {"target_id":12,"title":"Feature","status":"in_progress","kind":"stale","detail":"no movement","fix":"move it on"},
          {"target_id":13,"title":"Task","status":"done","kind":"done_but_unmerged","detail":"d","fix":"f"}],
         "notes":["gh CLI not found"]}
        """)
        XCTAssertEqual(report.base, "origin/main")
        XCTAssertFalse(report.isPartial)
        XCTAssertEqual(report.findings.map(\.isConflict), [true, false, false],
                       "only what Go's Finding.Blocking blocks is a conflict")
        XCTAssertEqual(report.findings[0].fix, "set it done")
        XCTAssertEqual(Set(report.findings.map(\.id)).count, 3)
        XCTAssertEqual(report.notes, ["gh CLI not found"])
    }

    /// No findings does not mean "in step" when the check did not cover the board.
    func testPartialChecks() throws {
        XCTAssertTrue(try decode(#"{"project_id":1,"git":false,"findings":[],"notes":["not a git work tree"]}"#).isPartial)
        XCTAssertTrue(try decode(#"{"project_id":1,"git":true,"base":"main","incomplete":true,"findings":[]}"#).isPartial)
        XCTAssertTrue(try decode(#"{"project_id":1,"git":true,"findings":[]}"#).isPartial, "no default branch")
        XCTAssertFalse(try decode(#"{"project_id":1,"git":true,"base":"main","findings":[]}"#).isPartial)
    }
}
