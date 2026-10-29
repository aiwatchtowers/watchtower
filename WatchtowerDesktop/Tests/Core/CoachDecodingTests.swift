import XCTest
@testable import WatchtowerCore

final class CoachDecodingTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name).json")
        return try Data(contentsOf: url)
    }

    func testStatusDecodes() throws {
        let s = try JSONDecoder().decode(CoachStatus.self, from: fixture("coach-status"))
        XCTAssertTrue(s.ok)
        XCTAssertEqual(s.open, 2)
        XCTAssertEqual(s.period.since, "2026-10-14T00:00:00Z")
        XCTAssertEqual(s.metrics.corrections.value, 2.1)
        XCTAssertNil(s.metrics.taskHours.value)
        XCTAssertNil(s.metrics.taskHours.previous)
        XCTAssertFalse(s.metrics.taskHours.known)
        XCTAssertEqual(s.metrics.ownerLoop.previous, 0.31)
        XCTAssertEqual(s.lastRun, "2026-10-25T09:00:00Z")
    }

    func testProposalsDecode() throws {
        let list = try JSONDecoder().decode(CoachProposalList.self, from: fixture("coach-proposals"))
        XCTAssertEqual(list.proposals.count, 2)
        let open = list.proposals[0]
        XCTAssertEqual(open.workbenchID, 0)
        XCTAssertEqual(open.budget, 1000)
        XCTAssertEqual(open.evidence.map(\.ref), ["ask:12", "sess-acme-1"])
        XCTAssertNil(open.decidedAt)
        XCTAssertNil(open.baseline)
        let done = list.proposals[1]
        XCTAssertEqual(done.workbenchID, 3)
        XCTAssertEqual(done.baseline, 3.0)
        XCTAssertEqual(done.verdictValue, 2.1)
        XCTAssertEqual(done.verdictAt, "2026-10-25T09:00:00Z")
    }

    func testFailureParsePicksJSONLineBeforeProse() {
        let err = "junk\n{\"ok\":false,\"error\":\"busy\",\"code\":\"busy\"}\ncoach: the coach is already running\n"
        let f = CoachFailure.parse(stderr: err)
        XCTAssertEqual(f?.code, "busy")
        XCTAssertEqual(f?.error, "busy")
        XCTAssertNil(f?.diff)
    }

    func testFailureParseLastJSONWins() {
        let err = "{\"ok\":false,\"error\":\"a\"}\n{\"ok\":false,\"error\":\"b\",\"diff\":\"d\"}\n"
        XCTAssertEqual(CoachFailure.parse(stderr: err)?.error, "b")
        XCTAssertEqual(CoachFailure.parse(stderr: err)?.diff, "d")
    }

    func testFailureParseNoJSON() {
        XCTAssertNil(CoachFailure.parse(stderr: "just prose\nmore prose"))
        XCTAssertNil(CoachFailure.parse(stderr: "{\"x\":1}\n"))
        XCTAssertNil(CoachFailure.parse(stderr: ""))
    }
}
