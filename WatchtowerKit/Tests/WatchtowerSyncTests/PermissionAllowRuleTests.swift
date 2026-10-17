import XCTest
@testable import WatchtowerSync

/// When the phone may only deny a permission request (#517, owner decision
/// in ask #268): a shortened summary, or an Edit/Write/NotebookEdit of a
/// settings path. The hub's handler and the phone's card share this rule.
final class PermissionAllowRuleTests: XCTestCase {
    func testProj21_AClippedRequestCannotBeAllowed() {
        XCTAssertEqual(PermissionAllowBlock.check(toolName: "Bash", summary: "ls", clipped: true), .clipped)
        XCTAssertEqual(PermissionAllowBlock.check(toolName: "Edit", summary: "/tmp/acme/a.go", clipped: true), .clipped)
        XCTAssertNil(PermissionAllowBlock.check(toolName: "Bash", summary: "ls", clipped: false))
        XCTAssertEqual(PermissionAllowBlock.clipped.note, "Shortened — answer on the Mac to allow")
    }

    func testProj21_ASettingsPathEditCannotBeAllowed() {
        let blocked = [
            "/tmp/home/acme/.claude/settings.local.json",
            "/tmp/home/acme/.claude/hooks/x.sh",
            "/tmp/home/.codex/config.toml",
            "/tmp/home/acme/.agents/skills/x/SKILL.md",
            "/tmp/home/acme/.git/hooks/pre-commit",
            "/tmp/home/.zshrc", "/tmp/home/.zshenv", "/tmp/home/.zprofile", "/tmp/home/.zlogin",
            "/tmp/home/.bashrc", "/tmp/home/.bash_profile", "/tmp/home/.bash_login", "/tmp/home/.profile",
            // Owner decision, ask #312: files that run code or steer an agent.
            "/tmp/home/acme/.git/config", "/tmp/home/acme/.mcp.json", "/tmp/home/acme/.envrc",
            "/tmp/home/.gitconfig", "/tmp/home/acme/.watchtower/workflow.md",
            "/tmp/home/acme/.CLAUDE/settings.json", // the Mac's file system ignores case
            ".claude/settings.json"
        ]
        for tool in ["Edit", "Write", "NotebookEdit"] {
            for path in blocked {
                XCTAssertEqual(PermissionAllowBlock.check(toolName: tool, summary: path, clipped: false), .settingsPath, "\(tool) \(path)")
            }
        }
        XCTAssertEqual(
            PermissionAllowBlock.settingsPath.note,
            "Changes Watchtower or shell settings — answer on the Mac to allow"
        )
    }

    func testEveryOtherPathAndToolKeepsAllowOnce() {
        let allowed = [
            "/tmp/home/acme/main.go",
            "/tmp/home/acme/docs/claude.md",
            "/tmp/home/acme/.github/workflows/ci.yml",
            "/tmp/home/acme/.git/info/exclude",
            "/tmp/home/acme/.watchtower/review.md",
            "/tmp/home/acme/config",
            "/tmp/home/acme/hooks/pre-commit",
            "/tmp/home/acme/zshrc.md",
            "/tmp/home/acme/.claude-notes/x.md"
        ]
        for path in allowed {
            XCTAssertNil(PermissionAllowBlock.check(toolName: "Write", summary: path, clipped: false), path)
        }
        // Only the path tools: a Bash command naming a settings file is shown in full and confirmed.
        XCTAssertNil(PermissionAllowBlock.check(toolName: "Bash", summary: "cat ~/.zshrc", clipped: false))
        XCTAssertNil(PermissionAllowBlock.check(toolName: "WebFetch", summary: "https://example.com/.claude/x", clipped: false))
    }
}
