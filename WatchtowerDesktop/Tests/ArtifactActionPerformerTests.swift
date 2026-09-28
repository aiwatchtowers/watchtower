import XCTest
import AppKit
import WatchtowerCore
@testable import WatchtowerDesktop

@MainActor
final class ArtifactActionPerformerTests: XCTestCase {
    private func pasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("wt-artifact-\(UUID().uuidString)"))
    }

    func testCopy() {
        let board = pasteboard()
        defer { board.releaseGlobally() }
        let outcome = ArtifactActionPerformer.perform(.copy("draft"), pasteboard: board) { _ in
            XCTFail("no open")
            return false
        }
        XCTAssertEqual(outcome, ArtifactActionOutcome(copied: true, opened: false))
        XCTAssertEqual(board.string(forType: .string), "draft")
    }

    func testCopyThenOpen() throws {
        let board = pasteboard()
        defer { board.releaseGlobally() }
        var opened: [URL] = []
        let url = try XCTUnwrap(URL(string: "slack://channel?team=T1&id=C1"))
        let outcome = ArtifactActionPerformer.perform(.copyThenOpen(text: "msg", url: url), pasteboard: board) {
            opened.append($0)
            return true
        }
        XCTAssertEqual(outcome, ArtifactActionOutcome(copied: true, opened: true))
        XCTAssertEqual(opened, [url])
        XCTAssertEqual(board.string(forType: .string), "msg")
    }

    func testDisallowedSchemeIsNeverOpened() throws {
        var opened = 0
        let outcome = ArtifactActionPerformer.perform(
            .open(try XCTUnwrap(URL(string: "file:///Applications/Calculator.app"))), pasteboard: pasteboard()
        ) { _ in
            opened += 1
            return true
        }
        XCTAssertEqual(opened, 0)
        XCTAssertFalse(outcome.opened)
    }
}
