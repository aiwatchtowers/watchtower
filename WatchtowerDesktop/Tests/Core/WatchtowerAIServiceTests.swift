import XCTest
@testable import WatchtowerCore

/// Covers `WatchtowerAIService.buildArgs` — the CLI-flag mapping used to
/// invoke `watchtower ai query`. In particular, the `--provider` flag is what
/// lets the chat provider picker actually switch the backend (previously the
/// provider argument was dropped, so the Go CLI always fell back to whatever
/// `ai.provider` was set in config.yaml).
final class WatchtowerAIServiceTests: XCTestCase {
    func testBuildArgsIncludesProviderFlagWhenSet() {
        let args = WatchtowerAIService.buildArgs(
            prompt: "hello",
            systemPrompt: nil,
            sessionID: nil,
            dbPath: nil,
            model: nil,
            provider: "codex",
            extraAllowedTools: []
        )

        XCTAssertEqual(args, ["ai", "query", "hello", "--provider", "codex"])
    }

    func testBuildArgsOmitsProviderFlagWhenNil() {
        let args = WatchtowerAIService.buildArgs(
            prompt: "hello",
            systemPrompt: nil,
            sessionID: nil,
            dbPath: nil,
            model: nil,
            provider: nil,
            extraAllowedTools: []
        )

        XCTAssertFalse(args.contains("--provider"))
    }

    func testBuildArgsOmitsProviderFlagWhenEmpty() {
        let args = WatchtowerAIService.buildArgs(
            prompt: "hello",
            systemPrompt: nil,
            sessionID: nil,
            dbPath: nil,
            model: nil,
            provider: "",
            extraAllowedTools: []
        )

        XCTAssertFalse(args.contains("--provider"))
    }

    func testBuildArgsIncludesModelAndProviderTogether() {
        let args = WatchtowerAIService.buildArgs(
            prompt: "hello",
            systemPrompt: nil,
            sessionID: nil,
            dbPath: nil,
            model: "gpt-5.4",
            provider: "codex",
            extraAllowedTools: []
        )

        XCTAssertEqual(args, ["ai", "query", "hello", "--model", "gpt-5.4", "--provider", "codex"])
    }
}
