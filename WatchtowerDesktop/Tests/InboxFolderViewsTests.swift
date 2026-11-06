import AppKit
import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

/// Inbox builder B Task 1: the folder views drawn — every Needs approval
/// note state, and the menu at the edges (no rows, one deep row, 100 rows).
/// Their values' rules are `InboxFolderContentTests` (Tests/Core).
@MainActor
final class InboxFolderViewsTests: XCTestCase {
    func testEveryNoteStateRenders() throws {
        let states: [NeedsApprovalNoteContent] = [
            .init(state: .off), .init(state: .stopped), .init(state: .lastRunFailed),
            .init(state: .off, failure: "Feature changes are being applied in Settings — try again"),
            .init(state: .stopped, failure: "watchtower exited with error: database is locked")
        ]
        for content in states {
            try assertRenders(NeedsApprovalNote(content: content), width: 640)
        }
    }

    // MARK: - The folder menu

    func testMenuRendersWithNoRowsOneDeepRowAndAHundredRows() throws {
        try assertRenders(InboxFolderMenu(content: InboxFolderMenuContent(rows: [])), width: 220)
        let deep = InboxFolderRow(id: 9, kind: .owner, title: "A folder three levels down with a long title",
                                  icon: "bolt", depth: 3, count: 12)
        try assertRenders(InboxFolderMenu(content: InboxFolderMenuContent(rows: tree + [deep], selection: 9)),
                          width: 220)
        let many = (0..<100).map { index in
            InboxFolderRow(id: Int64(100 + index), kind: .owner, title: "Folder \(index)", icon: "",
                           depth: 1 + index % 3, count: index)
        }
        let hundred = InboxFolderMenu(content: InboxFolderMenuContent(rows: [tree[0], tree[1]] + many))
        try assertRenders(hundred, width: 220)
        // The tree scrolls: a hundred folders do not make the column a
        // hundred rows tall, so New Folder and the note stay on screen.
        let height = ViewRenderProbe.fittingHeight(hundred, width: 220)
        XCTAssertTrue(height.isFinite)
        XCTAssertLessThan(height, 100 * ListLayout.rowMinHeight, "the rows must scroll, not grow the column")
    }

    // MARK: - Helpers

    private let tree = [
        InboxFolderRow(id: 1, kind: .root, title: "Inbox", icon: "", depth: 0, count: 9),
        InboxFolderRow(id: 2, kind: .approvals, title: "Needs approval", icon: "", depth: 1, count: 3),
        InboxFolderRow(id: 3, kind: .owner, title: "Release", icon: "flag", depth: 1, count: 2),
        InboxFolderRow(id: 4, kind: .owner, title: "Blockers", icon: "shippingbox", depth: 2, count: 1)
    ]

    /// Lays the view out at `width` and its own height and draws it: not
    /// blank, not zero-sized.
    private func assertRenders(
        _ view: some View, width: CGFloat, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let height = ViewRenderProbe.fittingHeight(view, width: width)
        XCTAssertGreaterThan(height, 0, file: file, line: line)
        let bitmap = try ViewRenderProbe(size: NSSize(width: width, height: max(height, 1)))
            .render(view, try XCTUnwrap(NSAppearance(named: .aqua)))
        XCTAssertGreaterThan(bitmap.pixelsWide, 0, file: file, line: line)
        XCTAssertGreaterThan(bitmap.pixelsHigh, 0, file: file, line: line)
        XCTAssertGreaterThan(Self.distinctColours(bitmap, limit: 2), 1, "the view drew nothing", file: file,
                             line: line)
    }

    /// Distinct raw RGBA values in `bitmap`, counting up to `limit` only
    /// (`DesignShotsTests`' blank check).
    private static func distinctColours(_ bitmap: NSBitmapImageRep, limit: Int) -> Int {
        guard let data = bitmap.bitmapData else { return 0 }
        let bytesPerPixel = bitmap.bitsPerPixel / 8
        var seen = Set<UInt32>()
        for y in 0..<bitmap.pixelsHigh {
            let row = data + y * bitmap.bytesPerRow
            for x in 0..<bitmap.pixelsWide {
                let pixel = row + x * bytesPerPixel
                seen.insert(UInt32(pixel[0]) << 24 | UInt32(pixel[1]) << 16 | UInt32(pixel[2]) << 8 | UInt32(pixel[3]))
                if seen.count >= limit { return seen.count }
            }
        }
        return seen.count
    }
}
