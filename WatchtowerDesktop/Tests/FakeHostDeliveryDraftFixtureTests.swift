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
        struct App: Decodable {
            let after: Int
            let line: String
            let pause: Bool
        }
        struct Case: Decodable {
            let name: String
            let profile: String
            let keys: [String]
            let dialog: Bool
            let app: App?
            let expect: Expect
        }
        let cases: [Case]
    }

    func testTheFakeHostReadsKeysByTheSharedTable() async throws {
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
            let draft = await Self.run(c, on: host)
            XCTAssertEqual(draft.count, c.expect.count, "\(c.name): count")
            XCTAssertEqual(draft.exact, c.expect.exact, "\(c.name): exact")
            XCTAssertEqual(draft.holdsText, c.expect.holds, "\(c.name): holds")
        }
    }

    /// Feeds the case's keys; its app line goes through `deliver` after
    /// `app.after` of them — left typed (no `submitIf`), or in its pause,
    /// the rest of the keys typed during it. The draft after the last key.
    private static func run(_ c: Fixture.Case, on host: FakeHostDelivery) async -> DraftModel {
        let type = { (keys: ArraySlice<String>) in keys.forEach { host.ownerInput(Array($0.utf8)) } }
        guard let app = c.app else {
            type(c.keys[...])
            return host.draft
        }
        type(c.keys[..<app.after])
        let rest = c.keys[app.after...]
        var draft: DraftModel?
        host.pause = { _ in
            type(rest)
            draft = host.draft
        }
        _ = await host.deliver(SessionDeliverLine(text: app.line, submitIf: app.pause)) {
            DeliverCheckReply(fresh: false, canSubmit: false)
        }
        if let draft { return draft } // the keys went in its pause
        type(rest) // left typed at once
        return host.draft
    }
}
