import XCTest
@testable import WatchtowerCore

/// `internal/sessionstart/testdata/placement_cases.json` is the shared fixture
/// of Go `sessionstart.Place`, the twin of `SessionStartPlacement.decide` (Go
/// hub spec 2026-10-31 §11, a dual path pinned from both sides). Written from
/// the Swift type with `WT_E2E_REGENERATE=1`.
final class SessionStartPlacementFixtureTests: XCTestCase {
    struct Git: Codable {
        let gitAvailable: Bool
        let git: Bool
        let unborn: Bool
        let statusOK: Bool

        enum CodingKeys: String, CodingKey {
            case git, unborn
            case gitAvailable = "git_available"
            case statusOK = "status_ok"
        }
    }

    struct Want: Codable, Equatable {
        let worktree: Bool
        let note: String?
    }

    struct Case: Codable {
        let name: String
        let choice: String
        let occupied: Bool
        /// nil = the status could not be read.
        let git: Git?
        var want: Want?
    }

    private static let statuses: [(String, Git?)] = [
        ("git ok", Git(gitAvailable: true, git: true, unborn: false, statusOK: true)),
        ("status unread", nil),
        ("no git binary", Git(gitAvailable: false, git: false, unborn: false, statusOK: false)),
        ("not a repository", Git(gitAvailable: true, git: false, unborn: false, statusOK: false)),
        ("status failed", Git(gitAvailable: true, git: true, unborn: false, statusOK: false)),
        ("unborn", Git(gitAvailable: true, git: true, unborn: true, statusOK: true))
    ]

    private static var inputs: [Case] {
        WorktreeChoice.allCases.flatMap { choice in
            [false, true].flatMap { occupied in
                statuses.map { label, git in
                    Case(name: "\(choice.rawValue), \(occupied ? "occupied" : "free"), \(label)",
                         choice: choice.rawValue, occupied: occupied, git: git, want: nil)
                }
            }
        }
    }

    static func decide(_ c: Case) throws -> Want {
        let status = c.git.map {
            WorkbenchGitStatus(gitAvailable: $0.gitAvailable, git: $0.git, unborn: $0.unborn, statusOK: $0.statusOK)
        }
        let choice = try XCTUnwrap(WorktreeChoice(rawValue: c.choice), c.name)
        switch SessionStartPlacement.decide(choice: choice, gitStatus: status, occupied: c.occupied) {
        case let .folder(note): return Want(worktree: false, note: note)
        case .worktree: return Want(worktree: true, note: nil)
        }
    }

    func testEveryGoPlacementCase() throws {
        let file = GoFixture.url("placement_cases.json")
        if GoFixture.regenerate {
            try GoFixture.write(try Self.inputs.map { c in var c = c; c.want = try Self.decide(c); return c }, to: file)
            return XCTFail("regenerated \(file.lastPathComponent), re-run without WT_E2E_REGENERATE")
        }
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: file))
        XCTAssertGreaterThanOrEqual(cases.count, Self.inputs.count)
        for c in cases {
            XCTAssertEqual(try Self.decide(c), c.want, c.name)
        }
    }
}
