import XCTest
@testable import WatchtowerCore

/// `SpecReviewAnswer.build` against Go's `specreview.BuildAnswer`: both run
/// the cases of `internal/specreview/testdata/answer_marks.json` (Go's
/// `TestBuildAnswer_FixtureCases`) and must give each case's `want`. The Go
/// side is the hub's phone answers and the Watchman twin's marks; a one-sided
/// edit of either builder fails here or there.
final class SpecReviewAnswerFixtureTests: XCTestCase {
    private struct Case: Decodable {
        struct Mark: Decodable {
            var state: String
            var body: String
            var about: String
        }

        var name: String
        var result: SpecReviewResult?
        var ledger: [SpecReviewLedgerEntry]?
        var marks: [String: Mark]
        var base: OwnerAskAnswer
        var verdict: String
        var snapshot: String
        var want: OwnerAskAnswer
    }

    private func cases() throws -> [Case] {
        let url = URL(fileURLWithPath: #filePath)   // …/WatchtowerDesktop/Tests/Core/<this file>
            .deletingLastPathComponent()              // …/Tests/Core
            .deletingLastPathComponent()              // …/Tests
            .deletingLastPathComponent()              // …/WatchtowerDesktop
            .deletingLastPathComponent()              // repo root
            .appendingPathComponent("internal/specreview/testdata/answer_marks.json")
        return try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
    }

    func testFixtureCasesMatchGo() throws {
        let all = try cases()
        XCTAssertGreaterThan(all.count, 10)
        for c in all {
            let marks = try Dictionary(uniqueKeysWithValues: c.marks.map { key, m in
                let state = try XCTUnwrap(SpecReviewMarkState(rawValue: m.state), "\(c.name): state \(m.state)")
                return (key, SpecReviewMark(key: key, state: state, body: m.body, about: m.about))
            })
            let verdict = OwnerAskAnswer.Verdict(rawValue: c.verdict)
            let got = SpecReviewAnswer.build(
                result: c.result, marks: marks, loop: c.ledger, base: c.base, verdict: verdict, snapshot: c.snapshot
            )
            XCTAssertEqual(got, c.want, c.name)
        }
    }
}
