import XCTest
import SwiftUI
import ViewInspector
@testable import DesignKit
@testable import WatchtowerDesktop

/// A row with a `ref`: its own press sits on the line, never on the footer
/// under it (a failed press's selectable error, the Reply composer).
@MainActor
final class ArtifactListRowPressTests: XCTestCase {
    func testRowPressCoversTheLineNotTheFooter() throws {
        var pressed = 0
        let hooks = ArtifactRefHooks(
            nativeFooter: { _, _ in AnyView(Text("footer line")) },
            open: { _ in { pressed += 1 } }
        )
        let row = ArtifactListRow(title: "Row title", ref: ArtifactRef(kind: .idea, id: 1))
        let view = ArtifactListRowView(row: row, firstIndex: 0, mode: .inbox)
            .environment(\.artifactEnvironment, ArtifactEnvironment(refHooks: hooks))
        let outer = try view.inspect().find(ViewType.VStack.self)
        XCTAssertThrowsError(try outer.callOnTapGesture(), "the footer sits outside the press")
        XCTAssertNoThrow(try outer.find(text: "footer line"))
        try view.inspect().find(ViewType.HStack.self).callOnTapGesture()
        XCTAssertEqual(pressed, 1)
    }
}
