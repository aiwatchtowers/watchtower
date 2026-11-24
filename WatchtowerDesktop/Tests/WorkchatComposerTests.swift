import XCTest
import AppKit
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerChatText
@testable import ChatUI

/// U2 (plan Task G7, S5): the Workchat says before Send that a line waits
/// for the turn's end, only for an agent without mid-turn input and only
/// while it works.
@MainActor
final class WorkchatComposerTests: XCTestCase {
    func testCaptionWhenNoMidturnInput() throws {
        XCTAssertEqual(
            WorkchatComposer.holdCaption(agent: nil, holdsUntilIdle: true, working: true),
            "The agent takes your message when this turn ends."
        )

        XCTAssertNil(WorkchatComposer.holdCaption(agent: .codex, holdsUntilIdle: false, working: true))
        XCTAssertNil(WorkchatComposer.holdCaption(agent: .codex, holdsUntilIdle: true, working: false))
        XCTAssertEqual(
            WorkchatComposer.holdCaption(agent: .codex, holdsUntilIdle: true, working: true),
            "Codex takes your message when this turn ends."
        )
    }

    /// C2: Esc in an empty field while the agent works stops it, once; with text in the field it does not.
    func testEscapeInEmptyFieldWhileWorkingStops() {
        var stops = 0
        WorkchatComposer.escape(working: true, draft: "") { stops += 1 }
        XCTAssertEqual(stops, 1)
        WorkchatComposer.escape(working: true, draft: "wait") { stops += 1 }
        WorkchatComposer.escape(working: false, draft: "") { stops += 1 }
        XCTAssertEqual(stops, 1)
    }

    /// Esc stops only when the round button shows Stop (#2065): a field holding only an attachment, or a paste
    /// token, shows Send, so Esc leaves the agent alone; a whitespace-only field shows Stop, so Esc stops.
    func testEscWithOnlyAttachmentDoesNotStop() {
        var stops = 0
        WorkchatComposer.escape(working: true, draft: "", hasAttachments: true) { stops += 1 }
        WorkchatComposer.escape(working: true, draft: "[Image #1]") { stops += 1 }
        XCTAssertEqual(stops, 0)
        WorkchatComposer.escape(working: true, draft: " \n\t") { stops += 1 }
        XCTAssertEqual(stops, 1)
    }

    /// #2201 §4: the paperclip's "Paste …" item is titled by what ⌘V would do; nothing usable → nil (disabled).
    func testPasteMenuTitles() {
        XCTAssertEqual(ComposerPasteMenu.title(for: .attachImage, fileCount: 0), "Paste screenshot")
        XCTAssertEqual(ComposerPasteMenu.title(for: .attachFiles([URL(fileURLWithPath: "/tmp/a")]), fileCount: 1),
                       "Paste 1 file")
        XCTAssertEqual(ComposerPasteMenu.title(for: .attachFiles([]), fileCount: 3), "Paste 3 files")
        XCTAssertEqual(ComposerPasteMenu.title(for: .insertText(offerAsFile: false), fileCount: 0), "Paste text")
        XCTAssertEqual(ComposerPasteMenu.title(for: .insertText(offerAsFile: true), fileCount: 0), "Paste text")
        XCTAssertEqual(ComposerPasteMenu.title(for: .attachPDF, fileCount: 0), "Paste PDF")
        XCTAssertNil(ComposerPasteMenu.title(for: nil, fileCount: 0))
        XCTAssertEqual(ComposerPasteMenu.unavailableTitle, "Paste from clipboard")
        XCTAssertEqual(ComposerPasteMenu.attachTitle, "Attach files…")
    }

    /// The clipboard read when the menu opens, on private pasteboards (never the owner's clipboard).
    func testPasteMenuActionFromPasteboard() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("wt-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        XCTAssertNil(ComposerPasteMenu.action(in: pasteboard), "empty: nothing usable")
        pasteboard.setString("", forType: .string)
        XCTAssertNil(ComposerPasteMenu.action(in: pasteboard), "an empty string pastes nothing")
        pasteboard.clearContents()
        pasteboard.setString("hello", forType: .string)
        XCTAssertEqual(ComposerPasteMenu.action(in: pasteboard), .insertText(offerAsFile: false))
        pasteboard.clearContents()
        pasteboard.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)
        XCTAssertEqual(ComposerPasteMenu.action(in: pasteboard), .attachImage)
        pasteboard.clearContents()
        let urls = [URL(fileURLWithPath: "/tmp/a.png"), URL(fileURLWithPath: "/tmp/b.md")]
        pasteboard.writeObjects(urls as [NSURL])
        XCTAssertEqual(ComposerPasteMenu.action(in: pasteboard), .attachFiles(urls))
    }
}
