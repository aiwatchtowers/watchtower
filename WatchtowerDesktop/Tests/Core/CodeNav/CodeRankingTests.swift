import XCTest
@testable import WatchtowerCore

/// Ranking boosts (spec §7): open tabs > recently opened > git modified >
/// the rest; symbol kinds type > method/function > others; equal ranks keep
/// their input order.
final class CodeRankingTests: XCTestCase {
    private let boosts = CodeRankingBoosts(openTabs: ["d.go"], recent: ["c.go"], gitModified: ["b.go"])

    func testBoostTiersOrderEqualScores() {
        let candidates = ["a.go", "b.go", "c.go", "d.go"].map { CodeRankCandidate(score: 50, path: $0, kind: nil) }
        let order = CodeRanking.rank(candidates, boosts: boosts).map { candidates[$0].path }
        XCTAssertEqual(order, ["d.go", "c.go", "b.go", "a.go"])
    }

    func testKindOrderTypeThenCallableThenOthers() {
        let kinds: [CodeSymbolKind] = [.field, .function, .const, .method, .struct, .module, .protocol]
        let candidates = kinds.map { CodeRankCandidate(score: 50, path: "a.go", kind: $0) }
        let order = CodeRanking.rank(candidates, boosts: .none).map { candidates[$0].kind }
        XCTAssertEqual(order, [.struct, .protocol, .function, .method, .field, .const, .module])
    }

    func testTiesKeepInputOrder() {
        let candidates = (0 ..< 50).map { CodeRankCandidate(score: 10, path: "f\($0).go", kind: .var) }
        XCTAssertEqual(CodeRanking.rank(candidates, boosts: .none), Array(0 ..< 50))
    }

    func testAMuchBetterMatchOutranksABoost() {
        let candidates = [
            CodeRankCandidate(score: 40, path: "d.go", kind: nil),
            CodeRankCandidate(score: 120, path: "a.go", kind: nil)
        ]
        XCTAssertEqual(CodeRanking.rank(candidates, boosts: boosts), [1, 0])
    }

    func testEmptyQueryOrderIsTheBoostOrder() {
        let boosts = CodeRankingBoosts(openTabs: ["z.go", "y.go"], recent: ["y.go", "gone.go", "x.go", "w.go"], gitModified: ["v.go", "a.go"])
        let files = ["a.go", "b.go", "v.go", "w.go", "x.go", "y.go", "z.go", "c.go"]
        XCTAssertEqual(
            CodeRanking.emptyQueryOrder(files: files, boosts: boosts),
            ["z.go", "y.go", "x.go", "w.go", "a.go", "v.go", "b.go", "c.go"]
        )
    }
}
