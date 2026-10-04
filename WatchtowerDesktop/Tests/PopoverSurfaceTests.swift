import XCTest

/// Popovers share one look (#363): the system material behind every
/// popover's content, and a main action whose label reads in every state.
/// Source scans: the look itself (material, a disabled prominent button's
/// pale label) depends on the app being active and the accent the Mac
/// uses, which a test process cannot reproduce.
final class PopoverSurfaceTests: XCTestCase {
    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // WatchtowerDesktop
        .appendingPathComponent("Sources")

    /// Every SwiftUI popover's content wears `popoverSurface()`: a file with
    /// N `.popover(` calls applies it at least N times, comment lines aside
    /// (a mention in a comment neither presents nor surfaces one). A count
    /// per file, so a tripwire: it cannot pair each call with its content.
    func testEveryPopoverAppliesTheSharedSurface() throws {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil))
        var popovers = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
                .components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            let presented = text.components(separatedBy: ".popover(").count - 1
            let surfaced = text.components(separatedBy: ".popoverSurface()").count - 1
            popovers += presented
            XCTAssertGreaterThanOrEqual(surfaced, presented, url.lastPathComponent)
        }
        XCTAssertGreaterThan(popovers, 0, "the scan found no popovers: wrong sources path?")
    }

    /// The `NSPopover`-hosted Ask AI root wears it too.
    func testHostedCodeQuestionPopoverAppliesTheSharedSurface() throws {
        let text = try source("Views/Workbench/CodeNav/CodeQuestionPopover.swift")
        XCTAssertTrue(text.contains(".popoverSurface()"))
    }

    /// The popover forms' main actions use `.popoverPrimary`, never a bare
    /// `.borderedProminent` that goes blank while disabled.
    func testPopoverFormsMainActionsUsePopoverPrimary() throws {
        let paths = [
            "Views/Comments/CommentableDocumentText.swift",
            "Views/Workbench/CodeNav/CodeQuestionPopover.swift",
            "Views/Inbox/ReactionCheatSheetView.swift",
            "Views/Targets/TargetDetailView.swift"
        ]
        for path in paths {
            let text = try source(path)
            XCTAssertFalse(text.contains(".borderedProminent"), path)
            XCTAssertTrue(text.contains(".buttonStyle(.popoverPrimary)"), path)
        }
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.sources.appendingPathComponent(path), encoding: .utf8)
    }
}
