import XCTest
@testable import WatchtowerCore

/// Round paths are repository-top-relative, code roots folder-relative
/// (board #960, spec §2 "Paths").
final class ReviewPathMapTests: XCTestCase {
    func testAFolderAtTheTopMapsPathsAsTheyAre() {
        let map = ReviewPathMap(repoPrefix: "")
        XCTAssertEqual(map.toRoot("src/a.go"), "src/a.go")
        XCTAssertEqual(map.toRepo("src/a.go"), "src/a.go")
    }

    func testASubfolderDropsAndAddsItsPrefix() {
        for prefix in ["apps/web", "apps/web/", "/apps/web/"] {
            let map = ReviewPathMap(repoPrefix: prefix)
            XCTAssertEqual(map.toRoot("apps/web/x.ts"), "x.ts", prefix)
            XCTAssertEqual(map.toRepo("x.ts"), "apps/web/x.ts", prefix)
        }
    }

    func testARepoPathOutsideTheFolderHasNoRootPath() {
        let map = ReviewPathMap(repoPrefix: "apps/web")
        XCTAssertNil(map.toRoot("apps/api/x.ts"))
        XCTAssertNil(map.toRoot("apps/webby/x.ts"), "a sibling sharing the name's start is outside")
        XCTAssertNil(map.toRoot("README.md"))
        XCTAssertNil(map.toRoot("apps/web"), "the folder itself is not a file in it")
    }
}
