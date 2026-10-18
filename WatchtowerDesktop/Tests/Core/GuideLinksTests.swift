import XCTest
@testable import WatchtowerCore

/// The same table as Go `TestBaseURL` (docs/guide/guide_test.go).
final class GuideLinksTests: XCTestCase {
    func testBaseURLLinksTheReleaseTagOnlyForACleanVersion() {
        let prefix = "https://github.com/aiwatchtowers/watchtower/blob/"
        let cases: [String: String] = [
            "1.2.3": "v1.2.3",
            "v0.19.0": "v0.19.0",
            "v0.19.0-12-gabc-dirty": "main",
            "0.19.0-dirty": "main",
            "dev": "main",
            "": "main",
            "0.2": "main",
            "1.2.3.4": "main",
            "vv1.2.3": "main",
            "1.x.3": "main"
        ]
        for (version, ref) in cases {
            XCTAssertEqual(GuideLinks.baseURL(version: version).absoluteString, prefix + ref + "/docs/guide/", version)
        }
    }
}
