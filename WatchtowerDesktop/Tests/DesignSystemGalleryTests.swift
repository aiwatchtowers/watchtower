import XCTest
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop

final class DesignSystemGalleryTests: XCTestCase {
    func testGalleryStartsWithTheTokensSection() throws {
        let view = DesignSystemGallery()
        XCTAssertNoThrow(try view.inspect().find(text: "Tokens"))
        XCTAssertNoThrow(try view.inspect().find(text: "Spacing"))
    }

    func testSectionShowsTitleAndContent() throws {
        let view = GallerySection(title: "Chips") { Text("sample") }
        XCTAssertNoThrow(try view.inspect().find(text: "Chips"))
        XCTAssertNoThrow(try view.inspect().find(text: "sample"))
    }
}
