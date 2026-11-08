import XCTest
@testable import WatchtowerDesktop
@testable import WatchtowerCore

/// A7b — a session whose kind this build does not know (a newer Mac or CLI
/// wrote it) is never launched: no shell runs in its place and no Claude
/// Code; the pane and the Workchat say it is not supported.
@MainActor
final class UnsupportedAgentSessionTests: XCTestCase {
    private func session(_ kind: TerminalSession.Kind) -> TerminalSession {
        TerminalSession(
            id: 42, projectID: 1, kind: kind, title: "Newer", titleSource: .auto, targetID: nil,
            folderPath: FileManager.default.temporaryDirectory.path, claudeSessionID: nil,
            createdAt: "2026-11-08T10:00:00Z", lastActiveAt: "2026-11-08T10:00:00Z"
        )
    }

    func testTheCenterLaunchesNothingForAnUnknownKind() {
        var made: [FakeTerminalSession] = []
        let center = TerminalCenter {
            let process = FakeTerminalSession(pid: 0)
            made.append(process)
            return process
        }
        center.shell = { "/bin/zsh" }
        let row = session(.unsupported("gemini"))

        XCTAssertNil(center.start(row, fresh: true))
        XCTAssertEqual(center.states[row.id], .unavailable(TerminalSession.Kind.unsupportedMessage("gemini")))
        XCTAssertTrue(made.flatMap(\.launches).isEmpty, "no shell and no Claude Code in its place")
    }

    func testTheWorkchatSaysNotSupportedInsteadOfFinished() {
        XCTAssertEqual(SessionChatView.endedLine(kind: .unsupported("gemini"), finishedShown: true),
                       TerminalSession.Kind.unsupportedMessage("gemini"))
        XCTAssertEqual(SessionChatView.endedLine(kind: .unsupported("gemini"), finishedShown: false),
                       TerminalSession.Kind.unsupportedMessage("gemini"))
        XCTAssertEqual(SessionChatView.endedLine(kind: .codex, finishedShown: true), SessionChatView.finishedLine)
        XCTAssertNil(SessionChatView.endedLine(kind: .codex, finishedShown: false))
        XCTAssertNil(SessionChatView.endedLine(kind: nil, finishedShown: false))
    }
}
