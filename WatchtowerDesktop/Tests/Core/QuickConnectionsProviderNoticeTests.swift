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

    func testUnknownOrAbsentProviderWarnsByDefault() {
        XCTAssertNotNil(QuickConnectionsProviderNotice.caption(forProvider: nil))
        XCTAssertNotNil(QuickConnectionsProviderNotice.caption(forProvider: ""))
        XCTAssertNotNil(QuickConnectionsProviderNotice.caption(forProvider: "something-new"))
    }
}
