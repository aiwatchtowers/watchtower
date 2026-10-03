import XCTest
@testable import WatchtowerCore

/// The line typed into an ask's session (PROJ-12): the same text as Go's
/// `asks.DeliveryLine` for every `internal/asks/testdata/lines` fixture.
final class OwnerAskPromptTests: XCTestCase {
    func testTheLineMatchesEveryGoFixture() throws {
        let files = try OwnerAskFixtures.files("lines")
        XCTAssertGreaterThanOrEqual(files.count, 5)
        for file in files {
            let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: file.data) as? [String: Any], file.name)
            let id = try XCTUnwrap((fixture["id"] as? NSNumber)?.int64Value, file.name)
            let kind = try XCTUnwrap(OwnerAskKind(rawValue: fixture["kind"] as? String ?? ""), file.name)
            let answer = try OwnerAskAnswer.decode(OwnerAskFixtures.json(try XCTUnwrap(fixture["answer"])))
            XCTAssertEqual(OwnerAskPrompt.line(id: id, kind: kind, answer: answer), fixture["line"] as? String, file.name)
        }
    }

    func testTheLineIsOneLineWithNoControlCharacters() {
        let line = OwnerAskPrompt.line(id: 1, kind: .check, answer: OwnerAskAnswer(checklist: [
            .init(id: "1", state: .broken, note: "a\nb"), .init(id: "2", state: .skipped)
        ]))
        XCTAssertEqual(line, "Ask #1 answered (check: 0 ok, 1 broken, 1 skipped) — read it with get_ask 1 using the watchtower-workbench skill.")
        XCTAssertFalse(line.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) })
    }
}
