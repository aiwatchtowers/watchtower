import XCTest
@testable import WatchtowerCore

/// The Desktop's session adapters (`SessionAgent`, the twin of Go's
/// `internal/sessionagent`): each kind's adapter, its wire name, input
/// profile, start command and transcript lookup.
final class SessionAgentTests: XCTestCase {
    private let id = "0e5c5d2a-1b3c-4d5e-8f90-a1b2c3d4e5f6"

    func testEveryKindHasItsOwnAdapter() {
        for kind in AgentKind.allCases {
            XCTAssertEqual(kind.session.kind, kind)
            XCTAssertEqual(kind.session.caps, AgentSessionCaps.of(kind))
        }
    }

    /// Go's `Adapter.WireAgent` values, the Kit's `TerminalSessionState.Agent`.
    func testWireAgentAndInputProfile() {
        XCTAssertEqual(AgentKind.claude.session.wireAgent, "claude_code")
        XCTAssertEqual(AgentKind.codex.session.wireAgent, "codex_cli")
        XCTAssertNil(AgentKind.claude.session.inputProfile.newline)
        XCTAssertEqual(AgentKind.codex.session.inputProfile.newline, [0x0A], "Ctrl+J inserts a line break")
    }

    /// The same start commands as Go's `TestSessionAgent_LaunchCommand`.
    func testLaunchCommand() {
        let prompt = "-fix it"
        let claude = AgentKind.claude.session
        XCTAssertEqual(claude.launchCommand(AgentStart(sessionID: id, prompt: nil, resume: false, launchArgs: nil)),
                       AgentLaunchCommand(command: "exec claude --session-id \(id)", runs: true))
        XCTAssertEqual(
            claude.launchCommand(AgentStart(sessionID: id, prompt: prompt, resume: false, launchArgs: nil)),
            AgentLaunchCommand(
                command: "exec /bin/sh -c 'exec env -u WATCHTOWER_FIRST_PROMPT claude --session-id \(id) "
                    + "\"$WATCHTOWER_FIRST_PROMPT\"'",
                prompt: " -fix it", runs: true
            )
        )
        XCTAssertEqual(claude.launchCommand(AgentStart(sessionID: id, prompt: nil, resume: true, launchArgs: nil)),
                       AgentLaunchCommand(command: "exec claude --resume \(id)", runs: true))

        let codex = AgentKind.codex.session
        XCTAssertEqual(codex.launchCommand(AgentStart(sessionID: nil, prompt: prompt, resume: false, launchArgs: nil)),
                       AgentLaunchCommand(command: "exit 127", prompt: prompt, runs: false))
        let args = CodexLaunchArgs(binary: "/opt/codex", pathPrepend: "/opt/node", args: ["-c", "a='b'"])
        XCTAssertEqual(
            codex.launchCommand(AgentStart(sessionID: nil, prompt: prompt, resume: false, launchArgs: args)),
            AgentLaunchCommand(
                command: #"exec /bin/sh -c 'eval "$WATCHTOWER_CODEX_COMMAND"'"#,
                environment: [#"WATCHTOWER_CODEX_COMMAND=PATH='/opt/node':"$PATH" exec env -u WATCHTOWER_FIRST_PROMPT "#
                    + #"-u WATCHTOWER_CODEX_COMMAND '/opt/codex' '-c' 'a='\''b'\''' -- "$WATCHTOWER_FIRST_PROMPT""#],
                prompt: prompt, runs: true
            )
        )
        let bare = CodexLaunchArgs(binary: "codex", pathPrepend: "", args: [])
        XCTAssertEqual(
            codex.launchCommand(AgentStart(sessionID: id, prompt: nil, resume: true, launchArgs: bare)),
            AgentLaunchCommand(
                command: #"exec /bin/sh -c 'eval "$WATCHTOWER_CODEX_COMMAND"'"#,
                environment: ["WATCHTOWER_CODEX_COMMAND=exec env -u WATCHTOWER_FIRST_PROMPT -u WATCHTOWER_CODEX_COMMAND "
                    + "'codex' resume '\(id)'"],
                runs: true
            )
        )
    }

    /// An adapter calls only its own lookup, with what its agent reads.
    func testTranscriptLookupIsTheAdaptersOwn() throws {
        var calls: [String] = []
        let home = URL(fileURLWithPath: "/Users/example/.codex")
        let lookups = AgentTranscriptLookups(
            claude: { calls.append("claude \($0)"); return true },
            codex: { calls.append("codex \($0) \($1 ?? "-") \($2?.path ?? "-")"); return false }
        )
        XCTAssertTrue(try AgentKind.claude.session.transcriptExists(id: id, storedPath: "/x", home: home, in: lookups))
        XCTAssertFalse(try AgentKind.codex.session.transcriptExists(id: id, storedPath: "/r.jsonl", home: home, in: lookups))
        XCTAssertEqual(calls, ["claude \(id)", "codex \(id) /r.jsonl /Users/example/.codex"])
    }

    /// The phone's reason for a start whose binary is missing (the Kit's
    /// `ActionReason` raw values; Go `Adapter.NotFoundReason`).
    func testNotFoundReason() {
        XCTAssertEqual(AgentKind.claude.session.notFoundReason, "claude_not_found")
        XCTAssertEqual(AgentKind.codex.session.notFoundReason, "codex_not_found")
    }

    func testTranscriptHome() {
        XCTAssertNil(AgentKind.claude.session.transcriptHome(environment: ["CODEX_HOME": "/x"]))
        XCTAssertEqual(AgentKind.codex.session.transcriptHome(environment: ["CODEX_HOME": "/x/codex"])?.path, "/x/codex")
    }
}
