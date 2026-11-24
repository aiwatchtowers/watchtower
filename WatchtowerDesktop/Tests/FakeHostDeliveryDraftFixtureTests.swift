import Foundation
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

/// The test fake of the session host (`FakeHostDelivery`), which the
/// Desktop delivery tests run against, reads the owner's keys by the same
/// shared key table as the host (`internal/sessionhost/draft.go`) and the
/// Mac mirror (`DraftModel`): `internal/sessionhost/testdata/draft_cases.json`.
@MainActor
final class FakeHostDeliveryDraftFixtureTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Expect: Decodable {
            let count: Int
            let exact: Bool
            let holds: Bool
        }
        struct Case: Decodable {
            let name: String
            let profile: String
            let keys: [String]
            let dialog: Bool
            let expect: Expect
        }
        let cases: [Case]
    }

    func testTheFakeHostReadsKeysByTheSharedTable() throws {
        let url = URL(fileURLWithPath: #filePath) // …/WatchtowerDesktop/Tests/<this file>
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("internal/sessionhost/testdata/draft_cases.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        XCTAssertFalse(fixture.cases.isEmpty)
        for c in fixture.cases {
            let host = FakeHostDelivery()
            host.tracksDrafts = true
            host.profile = switch c.profile {
            case "claude": .claude
            case "codex": .codex
            default: .unidentified
            }
            host.dialog = { c.dialog }
            for key in c.keys {
                host.ownerInput(Array(key.utf8))
            }
            XCTAssertEqual(host.draft.count, c.expect.count, "\(c.name): count")
            XCTAssertEqual(host.draft.exact, c.expect.exact, "\(c.name): exact")
            XCTAssertEqual(host.draft.holdsText, c.expect.holds, "\(c.name): holds")
        }
    }
}
