import XCTest
@testable import WatchtowerCore

final class ReleaseLinksTests: XCTestCase {
    func testNotesLinkTheReleaseTagOnlyForACleanVersion() {
        let prefix = "https://github.com/aiwatchtowers/watchtower/"
        let cases: [String: String] = [
            "1.2.3": "releases/tag/v1.2.3",
            "v0.26.0": "releases/tag/v0.26.0",
            "v0.19.0-12-gabc-dirty": "releases",
            "dev": "releases",
            "": "releases",
            "0.2": "releases",
            "1.2.3.4": "releases",
            "1.x.3": "releases"
        ]
        for (version, path) in cases {
            XCTAssertEqual(ReleaseLinks.notes(version: version).absoluteString, prefix + path, version)
        }
    }

    func testRepository() {
        XCTAssertEqual(ReleaseLinks.repository.absoluteString, "https://github.com/aiwatchtowers/watchtower")
    }
}
