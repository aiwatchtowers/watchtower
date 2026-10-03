import XCTest

/// Spec 2026-10-03 Part 8 "Removed": owner asks replaced the workbench
/// Documents pane. No source names its views, view models, grouping, pane
/// case or header toggle again (the CHAT-05 scan pattern). The comment
/// rendering it shared with the chat (`DocumentRendering`,
/// `CommentableDocumentText`, `DocumentTextView`, `CommentAnchor`) stays
/// for the ask review body, so only the removed names are listed.
final class WorkbenchDocumentsRemovedScanTests: XCTestCase {
    private let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Core
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // WatchtowerDesktop
        .appendingPathComponent("Sources")

    private func swiftFiles(under dir: URL) throws -> [URL] {
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil))
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    private func relative(_ url: URL) -> String {
        String(url.path.dropFirst(sources.path.count + 1))
    }

    func testNoSourceNamesARemovedDocumentType() throws {
        let removed = [
            "WorkbenchDocumentsView", "WorkbenchDocumentsList", "WorkbenchDocumentThreadsPanel",
            "AddWorkbenchDocumentSheet", "WorkbenchDocumentViewModel", "WorkbenchDocumentGrouping",
            "WorkbenchCommentsSendBar"
        ]
        // The document models and the attach envelope, as whole words (the
        // names above all start with `WorkbenchDocument`).
        let models = try NSRegularExpression(pattern: #"\bWorkbenchDocument(ListItem|Attached)?\b"#)
        let files = try swiftFiles(under: sources)
        XCTAssertFalse(files.isEmpty, "the scan must find the sources")
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for name in removed {
                XCTAssertFalse(text.contains(name), "\(relative(file)) still names \(name)")
            }
            XCTAssertNil(models.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                         "\(relative(file)) still names a removed document model")
        }
    }

    /// The pane case, the subject case and the header toggle: no workbench
    /// source shows or routes to a Documents pane.
    func testNoWorkbenchSourceHasADocumentsPaneOrSubject() throws {
        let workbench = try swiftFiles(under: sources).filter { file in
            let path = relative(file)
            let name = file.lastPathComponent
            return path.hasPrefix("Views/Workbench/") || name.hasPrefix("Workbench") || name.hasPrefix("Workspace")
        }
        XCTAssertTrue(workbench.contains { $0.lastPathComponent == "WorkspaceLayout.swift" })
        XCTAssertTrue(workbench.contains { $0.lastPathComponent == "Workbench.swift" })
        let pane = try NSRegularExpression(pattern: #"\.documents\b|case documents\b|case document\("#)
        for file in workbench {
            let text = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            XCTAssertNil(pane.firstMatch(in: text, range: range), "\(relative(file)) still has the Documents pane or subject")
            XCTAssertFalse(text.contains(#"Button("Documents")"#), "\(relative(file)) still offers the Documents toggle")
        }
    }
}
