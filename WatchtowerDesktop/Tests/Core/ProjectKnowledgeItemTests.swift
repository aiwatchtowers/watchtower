import XCTest
@testable import WatchtowerCore

/// The project page's Knowledge card (spec 2026-10-26 §7): files and pinned
/// sources in one list, files first, each in its stored order, with a kind.
final class ProjectKnowledgeItemTests: XCTestCase {
    private func file(_ id: Int64, _ name: String, _ mime: String) -> ChatAttachment {
        ChatAttachment(id: id, conversationID: nil, projectID: 1, messageID: nil, name: name, mime: mime,
                       size: 1, path: "/tmp/\(name)", sha256: "h", createdAt: 1)
    }

    private func source(_ id: Int64, _ kind: String, _ label: String) -> ChatProjectSource {
        ChatProjectSource(id: id, projectID: 1, kind: kind, ref: label, label: label)
    }

    func testFilesComeFirstThenSourcesEachInStoredOrder() {
        let items = ProjectKnowledgeItem.merged(
            files: [file(5, "report.pdf", "application/pdf"), file(2, "notes.md", "text/markdown")],
            sources: [source(9, "jira_project", "ACME"), source(3, "slack_channel", "#acme-team")]
        )
        XCTAssertEqual(items.map(\.id), [.file(5), .file(2), .source(9), .source(3)])
        XCTAssertEqual(items.map(\.title), ["report.pdf", "notes.md", "ACME", "#acme-team"])
        XCTAssertEqual(items.map(\.isFile), [true, true, false, false])
    }

    func testFileKinds() {
        let items = ProjectKnowledgeItem.merged(files: [
            file(1, "a.pdf", "application/pdf"),
            file(2, "SCAN.PDF", "application/octet-stream"),
            file(3, "b.md", "text/plain"),
            file(4, "c.markdown", "text/plain"),
            file(5, "d.png", "image/png"),
            file(6, "e.txt", "text/plain"),
            file(7, "Makefile", "text/plain"),
            file(8, "f.config", "text/plain")
        ], sources: [])
        XCTAssertEqual(items.map(\.kind), [
            .pdf, .pdf, .markdown, .markdown, .image, .file(ext: "txt"), .file(ext: ""), .file(ext: "config")
        ])
        XCTAssertEqual(items.map(\.badge), ["PDF", "PDF", "MD", "MD", "IMAGE", "TXT", "FILE", "FILE"])
    }

    func testSourceKinds() {
        let kinds = ["jira_project", "slack_channel", "confluence_space", "target", "track", "person", "linear_team"]
        let items = ProjectKnowledgeItem.merged(
            files: [], sources: kinds.enumerated().map { source(Int64($0.offset), $0.element, "x") })
        XCTAssertEqual(items.map(\.kind), [.jira, .slack, .confluence, .target, .track, .person, .otherSource])
        XCTAssertEqual(items.map(\.badge), ["JIRA", "SLACK", "CONFLUENCE", "TARGET", "TRACK", "PERSON", "SOURCE"])
    }

    func testEmpty() {
        XCTAssertTrue(ProjectKnowledgeItem.merged(files: [], sources: []).isEmpty)
    }
}
