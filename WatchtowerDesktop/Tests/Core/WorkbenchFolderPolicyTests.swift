import XCTest
@testable import WatchtowerCore

final class WorkbenchFolderPolicyTests: XCTestCase {
    private let home = "/Users/owner"

    func testFoldersUnderProtectedLocationsAreNamed() {
        XCTAssertEqual(WorkbenchFolderPolicy.tccSensitiveLocation(path: "/Users/owner/Documents/acme", home: home), "~/Documents")
        XCTAssertEqual(WorkbenchFolderPolicy.tccSensitiveLocation(path: "/Users/owner/Desktop", home: home), "~/Desktop")
        XCTAssertEqual(WorkbenchFolderPolicy.tccSensitiveLocation(path: "/Users/owner/Downloads/x/y", home: home), "~/Downloads")
        XCTAssertEqual(
            WorkbenchFolderPolicy.tccSensitiveLocation(path: "/Users/owner/Library/CloudStorage/Drive/acme", home: home + "/"),
            "~/Library/CloudStorage"
        )
    }

    func testOtherFoldersAndLookalikesAreNotFlagged() {
        XCTAssertNil(WorkbenchFolderPolicy.tccSensitiveLocation(path: "/Users/owner/code/acme", home: home))
        XCTAssertNil(WorkbenchFolderPolicy.tccSensitiveLocation(path: "/Users/owner/DocumentsArchive/acme", home: home))
        XCTAssertNil(WorkbenchFolderPolicy.tccSensitiveLocation(path: "/tmp/Documents/acme", home: home))
    }
}
