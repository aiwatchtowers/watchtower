import XCTest
@testable import WatchtowerCore

final class QuickConnectionsProviderNoticeTests: XCTestCase {

    func testClaudeProviderShowsNoCaption() {
        XCTAssertNil(QuickConnectionsProviderNotice.caption(forProvider: "claude"))
    }

    /// The codex chat mounts Quick Connections in its own CODEX_HOME (#594).
    func testCodexProviderShowsNoCaption() {
        XCTAssertNil(QuickConnectionsProviderNotice.caption(forProvider: "codex"))
    }

    func testNonClaudeProvidersShowCaptionNamingClaude() {
        let caption = QuickConnectionsProviderNotice.caption(forProvider: "ollama")
        XCTAssertNotNil(caption)
        XCTAssertTrue(caption?.contains("claude") == true)
        XCTAssertTrue(caption?.contains("codex") == true)
    }

    func testCodexImportNoticeShowsOnceForCodexUsersWithServers() {
        let notice = QuickConnectionsProviderNotice.self
        XCTAssertNotNil(notice.codexImportNotice(forProvider: "codex", dismissed: false, codexServers: 2))
        XCTAssertNil(notice.codexImportNotice(forProvider: "codex", dismissed: true, codexServers: 2))
        XCTAssertNil(notice.codexImportNotice(forProvider: "claude", dismissed: false, codexServers: 2))
        XCTAssertNil(notice.codexImportNotice(forProvider: "codex", dismissed: false, codexServers: 0))
        XCTAssertNil(notice.codexImportNotice(forProvider: "codex", dismissed: false, codexServers: nil))
    }

    func testUnknownOrAbsentProviderWarnsByDefault() {
        XCTAssertNotNil(QuickConnectionsProviderNotice.caption(forProvider: nil))
        XCTAssertNotNil(QuickConnectionsProviderNotice.caption(forProvider: ""))
        XCTAssertNotNil(QuickConnectionsProviderNotice.caption(forProvider: "something-new"))
    }
}
