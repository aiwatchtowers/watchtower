import XCTest
import SwiftUI
import ViewInspector
@testable import DesignKit
@testable import WatchtowerDesktop

/// Waiting for me's Older list: its note row (ref `waiting_older`, folded
/// after by the Inbox's hooks) stays, the older rows under it fold behind
/// **Show <n> older**. No other list folds, and the kit folds nothing by itself.
@MainActor
final class ArtifactListFoldTests: XCTestCase {
    private func view(
        _ rows: [ArtifactListRow],
        mode: ArtifactRenderMode = .inbox,
        hooks: ArtifactRefHooks? = nil
    ) -> some View {
        let hooks = hooks ?? InboxRefHooks.make(isShown: { _ in true }, content: { _, _ in nil })
        return ArtifactListView(list: ArtifactBlock.List(title: "Older", rows: rows), firstIndex: 0, mode: mode)
            .environment(\.artifactEnvironment, ArtifactEnvironment(refHooks: hooks))
    }

    private let olderRows = [
        ArtifactListRow(title: "25 items are older than 7 days", ref: ArtifactRef(kind: .waitingOlder, key: "older")),
        ArtifactListRow(title: "Colleague A in #acme-release", ref: ArtifactRef(kind: .inboxItem, id: 1)),
        ArtifactListRow(title: "ACME-12 assigned to you", ref: ArtifactRef(kind: .inboxItem, id: 2))
    ]

    func testOlderListFoldedByDefault() throws {
        let list = try view(olderRows).inspect()
        XCTAssertNoThrow(try list.find(text: "25 items are older than 7 days"), "the note row stays")
        XCTAssertThrowsError(try list.find(text: "Colleague A in #acme-release"))
        XCTAssertThrowsError(try list.find(text: "ACME-12 assigned to you"))
        XCTAssertNoThrow(try list.find(button: "Show 2 older"))
        XCTAssertThrowsError(try list.find(button: "Hide"))
    }

    func testOtherListsNeverFold() throws {
        let rows = Array(olderRows.dropFirst())
        let list = try view(rows).inspect()
        XCTAssertNoThrow(try list.find(text: "Colleague A in #acme-release"))
        XCTAssertNoThrow(try list.find(text: "ACME-12 assigned to you"))
        XCTAssertThrowsError(try list.find(button: "Show 2 older"))

        // The note row anywhere but first folds nothing, and the Look
        // preview shows every row.
        let later = try view([olderRows[1], olderRows[0], olderRows[2]]).inspect()
        XCTAssertNoThrow(try later.find(text: "ACME-12 assigned to you"))
        let preview = try view(olderRows, mode: .preview).inspect()
        XCTAssertNoThrow(try preview.find(text: "ACME-12 assigned to you"))
        XCTAssertThrowsError(try preview.find(button: "Show 2 older"))

        // Without the host's hook the kit folds nothing.
        let plain = try view(olderRows, hooks: ArtifactRefHooks()).inspect()
        XCTAssertNoThrow(try plain.find(text: "ACME-12 assigned to you"))
        XCTAssertThrowsError(try plain.find(button: "Show 2 older"))
    }
}
