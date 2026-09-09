import XCTest
@testable import WatchtowerCore

final class QuickConnectionsProviderNoticeTests: XCTestCase {

    func testClaudeProviderShowsNoCaption() {
        XCTAssertNil(QuickConnectionsProviderNotice.caption(forProvider: "claude"))
    }

    func testNonClaudeProvidersShowCaptionNamingClaude() {
        for provider in ["ollama", "codex"] {
            let caption = QuickConnectionsProviderNotice.caption(forProvider: provider)
            XCTAssertNotNil(caption, provider)
            XCTAssertTrue(caption?.contains("claude") == true, provider)
        }
    }

    func testUnknownOrAbsentProviderWarnsByDefault() {
        XCTAssertNotNil(QuickConnectionsProviderNotice.caption(forProvider: nil))
        XCTAssertNotNil(QuickConnectionsProviderNotice.caption(forProvider: ""))
        XCTAssertNotNil(QuickConnectionsProviderNotice.caption(forProvider: "something-new"))
    }
}
