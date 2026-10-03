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
}
