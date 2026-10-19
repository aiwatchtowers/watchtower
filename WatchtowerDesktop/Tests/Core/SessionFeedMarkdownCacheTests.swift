import XCTest
@testable import WatchtowerCore

@MainActor
final class SessionFeedMarkdownCacheTests: XCTestCase {
    func testCacheReusesUnchangedEntry() {
        let cache = SessionFeedMarkdownCache()
        let a = cache.blocks(id: "e1", text: "hello **x**", lineBreaks: false)
        let b = cache.blocks(id: "e1", text: "hello **x**", lineBreaks: false)
        XCTAssertEqual(cache.parseCount, 1)
        XCTAssertEqual(a.count, b.count)
    }

    func testCacheReparsesGrownEntry() {
        let cache = SessionFeedMarkdownCache()
        _ = cache.blocks(id: "e1", text: "hello", lineBreaks: false)
        _ = cache.blocks(id: "e2", text: "other", lineBreaks: false)
        _ = cache.blocks(id: "e1", text: "hello world", lineBreaks: false)
        XCTAssertEqual(cache.parseCount, 3)
        _ = cache.blocks(id: "e2", text: "other", lineBreaks: false)
        XCTAssertEqual(cache.parseCount, 3)
    }
}
