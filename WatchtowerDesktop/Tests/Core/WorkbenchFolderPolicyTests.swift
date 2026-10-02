import XCTest
@testable import WatchtowerCore

final class ProjectFolderPolicyTests: XCTestCase {
    private let home = "/Users/owner"

    func testFoldersUnderProtectedLocationsAreNamed() {
        XCTAssertEqual(ProjectFolderPolicy.tccSensitiveLocation(path: "/Users/owner/Documents/acme", home: home), "~/Documents")
        XCTAssertEqual(ProjectFolderPolicy.tccSensitiveLocation(path: "/Users/owner/Desktop", home: home), "~/Desktop")
        XCTAssertEqual(ProjectFolderPolicy.tccSensitiveLocation(path: "/Users/owner/Downloads/x/y", home: home), "~/Downloads")
        XCTAssertEqual(
            ProjectFolderPolicy.tccSensitiveLocation(path: "/Users/owner/Library/CloudStorage/Drive/acme", home: home + "/"),
            "~/Library/CloudStorage"
        )
    }

    func testOtherFoldersAndLookalikesAreNotFlagged() {
        XCTAssertNil(ProjectFolderPolicy.tccSensitiveLocation(path: "/Users/owner/code/acme", home: home))
        XCTAssertNil(ProjectFolderPolicy.tccSensitiveLocation(path: "/Users/owner/DocumentsArchive/acme", home: home))
        XCTAssertNil(ProjectFolderPolicy.tccSensitiveLocation(path: "/tmp/Documents/acme", home: home))
    }
}
