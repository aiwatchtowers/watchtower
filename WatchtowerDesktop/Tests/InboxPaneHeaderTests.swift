import XCTest
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop
import WatchtowerCore

/// The reading pane's header (inbox redesign, phase 1): the tile, the title
/// and its line, the actions; an artifact's Run Now only when its ⋯ offers it.
@MainActor
final class InboxPaneHeaderTests: XCTestCase {
    func testTitleSubtitleAndActions() throws {
        var pressed = 0
        let sut = InboxPaneHeader(tile: InboxTile(kind: .artifact), title: "Release checklist",
                                  subtitle: "ϟ Checklist · run #4") {
            Button("Mark All Seen") { pressed += 1 }
        }

        XCTAssertNoThrow(try sut.inspect().find(InboxTile.self))
        XCTAssertNoThrow(try sut.inspect().find(text: "Release checklist"))
        XCTAssertNoThrow(try sut.inspect().find(text: "ϟ Checklist · run #4"))
        try sut.inspect().find(button: "Mark All Seen").tap()
        XCTAssertEqual(pressed, 1)
        XCTAssertEqual(try sut.inspect().find(InboxTile.self).actualView().size, IconSize.listTile)
    }

    func testAnEmptySubtitleDrawsNoLine() throws {
        let sut = InboxPaneHeader(tile: InboxTile(kind: .threads), title: "Thread brief", subtitle: "") { EmptyView() }
        XCTAssertEqual(try sut.inspect().findAll(ViewType.Text.self).count, 1)
    }

    func testArtifactHeaderShowsRunNowOnlyWhenOffered() throws {
        let content = InboxRowContent(kind: .artifact, title: "Release checklist")
        var commands: [InboxMenuCommand] = []
        func header(offersRunNow: Bool) -> InboxArtifactPaneHeader {
            let menu = InboxArtifactMenuState(
                entries: InboxArtifactMenuContent(offersRunNow: offersRunNow).entries
            ) { commands.append($0) }
            return InboxArtifactPaneHeader(content: content, subtitle: "ϟ Checklist · run #4", menu: menu) {}
        }

        let offered = header(offersRunNow: true)
        try offered.inspect().find(viewWithAccessibilityIdentifier: "inbox.paneHeader.runNow").button().tap()
        XCTAssertEqual(commands, [.runNow])
        XCTAssertNoThrow(try offered.inspect().find(viewWithAccessibilityIdentifier: "actionStrip.cheatSheetButton"))
        XCTAssertNoThrow(try offered.inspect().find(InboxArtifactMenuButton.self))

        let notOffered = header(offersRunNow: false)
        XCTAssertThrowsError(try notOffered.inspect().find(viewWithAccessibilityIdentifier: "inbox.paneHeader.runNow"))
        XCTAssertNoThrow(try notOffered.inspect().find(InboxArtifactMenuButton.self))

        let noMenu = InboxArtifactPaneHeader(content: content, subtitle: "", menu: nil, onReactionCommands: nil)
        XCTAssertThrowsError(try noMenu.inspect().find(viewWithAccessibilityIdentifier: "inbox.paneHeader.runNow"))
        XCTAssertThrowsError(try noMenu.inspect().find(viewWithAccessibilityIdentifier: "actionStrip.cheatSheetButton"))
    }
}
