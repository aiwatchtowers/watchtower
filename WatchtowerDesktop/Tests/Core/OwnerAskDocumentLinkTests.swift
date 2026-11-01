import XCTest
@testable import WatchtowerCore

final class OwnerAskDocumentLinkTests: XCTestCase {
    func testLocalAndRelativeDestinationsDecodeTheirPaths() throws {
        for (raw, path) in [("file:///work/demo/shot%20dark.png", "/work/demo/shot dark.png"),
                            ("file://localhost/work/demo/shot.png", "/work/demo/shot.png"),
                            ("docs/shot.png", "docs/shot.png")] {
            XCTAssertEqual(OwnerAskDocumentLink.path(try XCTUnwrap(URL(string: raw))), path)
        }
    }

    func testRemoteMalformedAndEscapingDestinationsAreRejected() throws {
        for raw in ["file://remote/work/shot.png", "file:///work/%2E%2E/secret.png", "../secret.png",
                    "file:///work/shot.png?download=1", "file:///work/shot.png#anchor", "#anchor",
                    "https://example.com/shot.png", "file:relative.png"] {
            XCTAssertNil(OwnerAskDocumentLink.path(try XCTUnwrap(URL(string: raw))), raw)
        }
    }

    func testAbsolutePathsMustBeInsideTheExactFolderBoundary() {
        XCTAssertEqual(OwnerAskDocumentLink.relativePath("/work/demo/docs/shot.png", folder: "/work/demo"), "docs/shot.png")
        XCTAssertEqual(OwnerAskDocumentLink.relativePath("docs/shot.png", folder: "/work/demo"), "docs/shot.png")
        XCTAssertNil(OwnerAskDocumentLink.relativePath("/work/demo-other/shot.png", folder: "/work/demo"))
        XCTAssertNil(OwnerAskDocumentLink.relativePath("/etc/hosts", folder: "/work/demo"))
    }
}
