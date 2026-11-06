import XCTest
@testable import WatchtowerCore
import WatchtowerTestSupport

final class QuickConnectionsProviderNoticeTests: XCTestCase {

    /// The caption follows the provider's capability row (the Go table):
    /// claude, codex and ollama (runtime B) take the connections.
    @MainActor
    func testCaptionFollowsTheCapabilityRow() {
        let catalog = AIModelCatalog(providers: ProviderCatalogFixture.providers())
        for id in ["claude", "codex", "ollama"] {
            XCTAssertNil(QuickConnectionsProviderNotice.caption(capabilities: catalog.capabilities(for: id)), id)
        }
        XCTAssertNotNil(QuickConnectionsProviderNotice.caption(capabilities: catalog.capabilities(for: "lmstudio")),
                        "a provider with no row takes nothing")
        XCTAssertNil(QuickConnectionsProviderNotice.caption(capabilities: nil), "no caption before the catalog is read")
    }

    func testCodexImportNoticeShowsOnceForCodexUsersWithServers() {
        let notice = QuickConnectionsProviderNotice.self
        XCTAssertNotNil(notice.codexImportNotice(forProvider: "codex", dismissed: false, codexServers: 2))
        XCTAssertNil(notice.codexImportNotice(forProvider: "codex", dismissed: true, codexServers: 2))
        XCTAssertNil(notice.codexImportNotice(forProvider: "claude", dismissed: false, codexServers: 2))
        XCTAssertNil(notice.codexImportNotice(forProvider: "codex", dismissed: false, codexServers: 0))
        XCTAssertNil(notice.codexImportNotice(forProvider: "codex", dismissed: false, codexServers: nil))
    }
}
