import XCTest
@testable import WatchtowerCore

/// `internal/sessionstart/testdata/launch_cases.json` is the shared fixture of
/// Go `sessionstart.Launch`, the twin of `TerminalLaunch.make` (Go hub spec
/// 2026-10-31 §11, a dual path pinned from both sides). The file is written
/// from the Swift type with `WT_E2E_REGENERATE=1`, which rewrites it from
/// `inputs` alone: a new case is added there, never by hand in the file.
/// Every case in the file must give the same launch here and in Go.
final class TerminalLaunchFixtureTests: XCTestCase {
    struct Mode: Codable {
        /// "claude", "codex", or "" for a shell.
        let agent: String
        let sessionID: String
        let prompt: String?
        let resume: Bool

        enum CodingKeys: String, CodingKey {
            case agent, prompt, resume
            case sessionID = "session_id"
        }
    }

    struct Codex: Codable {
        let binary: String
        let pathPrepend: String
        let args: [String]

        enum CodingKeys: String, CodingKey {
            case binary, args
            case pathPrepend = "path_prepend"
        }
    }

    struct Want: Codable, Equatable {
        let executable: String
        let args: [String]
        let dir: String
        let env: [String]
        /// 0 = no row.
        let row: Int64
    }

    struct Case: Codable {
        let name: String
        let shell: String
        let folder: String
        let row: Int64
        let mode: Mode
        let codex: Codex?
        let setup: String
        let automationRunID: Int64
        var want: Want?

        enum CodingKeys: String, CodingKey {
            case name, shell, folder, row, mode, codex, setup, want
            case automationRunID = "automation_run_id"
        }
    }

    private static let claudeID = "0e5c5d2a-1b3c-4d5e-8f90-a1b2c3d4e5f6"
    private static let codexID = "019a1b2c-3d4e-7f50-8a6b-7c8d9e0f1a2b"
    private static let codexArgs = Codex(
        binary: "/opt/co'dex/bin/codex",
        pathPrepend: "/opt/co'dex/bin",
        args: ["--no-daemon", "-c", "check_for_update_on_startup=false", "-c", "mcp_servers.w.args=['mcp']"]
    )
    private static let setup = "npm ci && echo 'ready'"

    private static func input(
        _ name: String,
        shell: String = "/bin/zsh",
        row: Int64 = 7,
        mode: Mode,
        codex: Codex? = nil,
        setup: String = "",
        automationRunID: Int64 = 0
    ) -> Case {
        Case(name: name, shell: shell, folder: "/work/acme", row: row, mode: mode, codex: codex,
             setup: setup, automationRunID: automationRunID, want: nil)
    }

    private static func claude(_ prompt: String? = nil) -> Mode {
        Mode(agent: "claude", sessionID: claudeID, prompt: prompt, resume: false)
    }

    private static func codex(_ prompt: String? = nil) -> Mode {
        Mode(agent: "codex", sessionID: "", prompt: prompt, resume: false)
    }

    private static let resumeClaude = Mode(agent: "claude", sessionID: claudeID, prompt: nil, resume: true)
    private static let resumeCodex = Mode(agent: "codex", sessionID: codexID, prompt: nil, resume: true)
    private static let shell = Mode(agent: "", sessionID: "", prompt: nil, resume: false)

    /// The inputs the fixture is regenerated from.
    private static let inputs: [Case] = [
        input("claude new, no prompt", mode: claude()),
        input("claude new, first-run prompt", mode: claude(TerminalLaunch.firstRunPrompt)),
        input("claude new, prompt with quotes and a newline", mode: claude("Say \"hi\" and 'bye'\n$HOME `x`")),
        input("claude new, prompt starting with a dash", mode: claude("-p evil")),
        input("claude new, prompt starting with a dash and a combining mark", mode: claude("-\u{0301}p")),
        input("claude new, empty prompt", mode: claude("")),
        input("claude new, no row", row: 0, mode: claude("hello")),
        input("claude resume", mode: resumeClaude),
        input("codex new, no prompt", mode: codex(), codex: codexArgs),
        input("codex new, prompt starting with a dash", mode: codex("-p not a flag"), codex: codexArgs),
        input("codex new, no path prepend", mode: codex("go"),
              codex: Codex(binary: "/usr/local/bin/codex", pathPrepend: "", args: [])),
        input("codex resume", mode: resumeCodex, codex: codexArgs),
        input("codex new without launch args", mode: codex("go")),
        input("codex resume without launch args", mode: resumeCodex),
        input("shell", mode: shell),
        input("shell, relative login shell", shell: "zsh", mode: shell),
        input("claude new, empty login shell", shell: "", mode: claude()),
        input("shell ignores setup and the automation run", mode: shell, setup: setup, automationRunID: 41),
        input("setup before a new claude", mode: claude("hello"), setup: setup),
        input("setup before a new claude without a prompt", mode: claude(), setup: setup),
        input("setup before a new codex", mode: codex("hello"), codex: codexArgs, setup: setup),
        input("setup never before a resume", mode: resumeClaude, setup: setup),
        input("setup never before a codex resume", mode: resumeCodex, codex: codexArgs, setup: setup),
        input("blank setup is no setup", mode: claude(), setup: " \n\t"),
        input("setup needs codex launch args", mode: codex("go"), setup: setup),
        input("automation run on a new claude", mode: claude("go"), automationRunID: 41),
        input("automation run on a resume", mode: resumeClaude, automationRunID: 41),
        input("automation run on a codex start with setup", mode: codex(), codex: codexArgs, setup: setup,
              automationRunID: 41)
    ]

    static func make(_ c: Case) throws -> Want {
        let mode: TerminalLaunch.Mode
        switch (c.mode.agent, c.mode.resume) {
        case ("", _): mode = .shell
        case (let agent, true):
            mode = .resumeAgent(try XCTUnwrap(AgentKind(rawValue: agent), c.name), sessionID: c.mode.sessionID)
        case (let agent, false):
            mode = .newAgent(
                try XCTUnwrap(AgentKind(rawValue: agent), c.name),
                sessionID: c.mode.sessionID.isEmpty ? nil : c.mode.sessionID,
                prompt: c.mode.prompt
            )
        }
        let launch = TerminalLaunch.make(
            shell: c.shell.isEmpty ? nil : c.shell,
            folder: c.folder,
            mode: mode,
            rowID: c.row == 0 ? nil : c.row,
            codex: c.codex.map { CodexLaunchArgs(binary: $0.binary, pathPrepend: $0.pathPrepend, args: $0.args) },
            setup: c.setup.isEmpty ? nil : c.setup,
            automationRunID: c.automationRunID == 0 ? nil : c.automationRunID
        )
        return Want(executable: launch.executable, args: launch.args, dir: launch.currentDirectory,
                    env: launch.environment, row: launch.rowID ?? 0)
    }

    func testEveryGoLaunchCase() throws {
        let file = GoFixture.url("launch_cases.json")
        if GoFixture.regenerate {
            try GoFixture.write(try Self.inputs.map { c in var c = c; c.want = try Self.make(c); return c }, to: file)
            return XCTFail("regenerated \(file.lastPathComponent), re-run without WT_E2E_REGENERATE")
        }
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: file))
        XCTAssertGreaterThanOrEqual(cases.count, Self.inputs.count)
        for c in cases {
            XCTAssertEqual(try Self.make(c), c.want, c.name)
        }
    }
}

/// The shared Go fixtures under `internal/sessionstart/testdata/`.
enum GoFixture {
    static var regenerate: Bool { ProcessInfo.processInfo.environment["WT_E2E_REGENERATE"] == "1" }

    static func url(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("internal/sessionstart/testdata/\(name)")
    }

    /// Sorted keys, pretty-printed, trailing newline.
    static func write(_ value: some Encodable, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
}
