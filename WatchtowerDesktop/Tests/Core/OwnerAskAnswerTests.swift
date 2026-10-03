import XCTest
@testable import WatchtowerCore

/// `owner_asks.answer` is written by Swift and read by Go: each valid
/// `internal/asks/testdata/answers` fixture, decoded and re-encoded, must be
/// its `canonical` byte for byte (README there).
final class OwnerAskAnswerTests: XCTestCase {
    func testEncoderReproducesEveryCanonicalAnswer() throws {
        let files = try OwnerAskFixtures.files("answers").filter { $0.name.hasPrefix("valid_") }
        XCTAssertGreaterThanOrEqual(files.count, 4)
        for file in files {
            let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: file.data) as? [String: Any], file.name)
            let canonical = try XCTUnwrap(fixture["canonical"] as? String, file.name)
            let answer = try OwnerAskAnswer.decode(OwnerAskFixtures.json(try XCTUnwrap(fixture["answer"])))
            XCTAssertEqual(Data(try answer.encoded().utf8), Data(canonical.utf8), "\(file.name): byte for byte")
            XCTAssertEqual(try OwnerAskAnswer.decode(canonical), answer, "\(file.name) round-trips")
        }
    }

    /// Built in Swift (not decoded), every key is still written — Go reads
    /// missing lists as empty, but the canonical form has them all.
    func testAnEmptyAnswerWritesEveryKey() throws {
        XCTAssertEqual(try OwnerAskAnswer().encoded(),
                       #"{"answers":[],"checklist":[],"comments":[],"note":"","verdict":""}"#)
        let built = OwnerAskAnswer(
            verdict: .changes,
            comments: [.init(anchor: CommentAnchor(quote: "q", prefix: "p", suffix: "s", heading: "H"), body: "b")]
        )
        XCTAssertEqual(
            try built.encoded(),
            #"{"answers":[],"checklist":[],"comments":[{"body":"b","heading":"H","prefix":"p","quote":"q","suffix":"s"}],"#
                + #""note":"","verdict":"changes"}"#
        )
    }

    func testMissingListsDecodeEmptyAndAnUnknownVerdictIsAnError() throws {
        XCTAssertEqual(try OwnerAskAnswer.decode(#"{"verdict":"approved"}"#), OwnerAskAnswer(verdict: .approved))
        XCTAssertThrowsError(try OwnerAskAnswer.decode(#"{"verdict":"maybe"}"#))
        XCTAssertThrowsError(try OwnerAskAnswer.decode(#"{"checklist":[{"id":"1","state":"fine"}]}"#))
    }

    /// The one invalid fixture Swift refuses already at decode (its item
    /// state is a typed enum).
    private static let undecodableFixture = "invalid_unknown_state.json"

    /// The Swift twin of Go's reader: every valid fixture passes, every
    /// invalid one fails — on decode (an unknown state) or with Go's exact error.
    func testProblemMatchesGoOnEveryAnswersFixture() throws {
        let files = try OwnerAskFixtures.files("answers")
        XCTAssertGreaterThanOrEqual(files.count, 9)
        for file in files {
            let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: file.data) as? [String: Any], file.name)
            let kind = try XCTUnwrap(OwnerAskKind(rawValue: fixture["kind"] as? String ?? ""), file.name)
            let payload = try OwnerAskPayload.decode(OwnerAskFixtures.json(try XCTUnwrap(fixture["payload"])))
            let decoded = try? OwnerAskAnswer.decode(OwnerAskFixtures.json(try XCTUnwrap(fixture["answer"])))
            if file.name.hasPrefix("valid_") {
                let answer = try XCTUnwrap(decoded, file.name)
                XCTAssertNil(answer.problem(kind: kind, payload: payload), file.name)
            } else if let answer = decoded {
                XCTAssertNotEqual(file.name, Self.undecodableFixture, "it must fail at decode")
                XCTAssertEqual(answer.problem(kind: kind, payload: payload)?.message, fixture["error"] as? String, file.name)
            } else {
                XCTAssertEqual(file.name, Self.undecodableFixture, "only an unknown state fails at decode")
            }
        }
    }

    func testProblemsGoAlsoRefuses() throws {
        let check = OwnerAskPayload(checklist: [OwnerAskCheckItem(id: "1", text: "Launch")])
        let broken = OwnerAskAnswer(checklist: [.init(id: "1", state: .broken, note: " ")])
        XCTAssertEqual(broken.problem(kind: .check, payload: check), .brokenWithoutNote(index: 0))
        let long = OwnerAskAnswer(checklist: [.init(id: "1", state: .ok)], note: String(repeating: "я", count: 4001))
        XCTAssertEqual(long.problem(kind: .check, payload: check)?.message, "note: at most 4000 characters")
        let atBound = OwnerAskAnswer(checklist: [.init(id: "1", state: .ok)], note: String(repeating: "я", count: 4000))
        XCTAssertNil(atBound.problem(kind: .check, payload: check), "4000 runes, not bytes")
        let verdict = OwnerAskAnswer(verdict: .approved, checklist: [.init(id: "1", state: .ok)])
        XCTAssertEqual(verdict.problem(kind: .check, payload: check), .verdictNotAllowed)
        let twice = OwnerAskAnswer(checklist: [.init(id: "1", state: .ok), .init(id: "1", state: .skipped)])
        XCTAssertEqual(twice.problem(kind: .check, payload: check)?.message, #"checklist[1].id: item "1" marked twice"#)
    }
}
