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
        XCTAssertEqual(ComposerPasteMenu.title(for: .attachFiles([]), fileCount: 0), "Paste files")
        XCTAssertEqual(ComposerPasteMenu.title(for: .insertText(offerAsFile: false), fileCount: 0), "Paste text")
        XCTAssertEqual(ComposerPasteMenu.title(for: .insertText(offerAsFile: true), fileCount: 0), "Paste text")
        XCTAssertEqual(ComposerPasteMenu.title(for: .attachPDF, fileCount: 0), "Paste PDF")
        XCTAssertNil(ComposerPasteMenu.title(for: nil, fileCount: 0))
        XCTAssertEqual(ComposerPasteMenu.unavailableTitle, "Paste from clipboard")
        XCTAssertEqual(ComposerPasteMenu.attachTitle, "Attach files…")
    }

    /// The clipboard as the menu sees it: types and the file-item count, each access counted.
    private final class AdvertSpy: PasteboardAdvert {
        let types: [String]
        let files: Int
        private(set) var reads = 0

        init(_ types: [String], files: Int = 0) {
            self.types = types
            self.files = files
        }

        var advertisedTypes: [String] {
            reads += 1
            return types
        }

        var fileItemCount: Int {
            reads += 1
            return files
        }
    }

    /// The paste item's title comes from the advertised types only (`PasteboardAdvert` has no content accessor).
    func testPasteMenuActionFromAdvertisedTypes() {
        XCTAssertNil(ComposerPasteMenu.action(advertised: AdvertSpy([])), "empty: nothing usable")
        XCTAssertEqual(ComposerPasteMenu.action(advertised: AdvertSpy(["public.utf8-plain-text"])),
                       .insertText(offerAsFile: false))
        XCTAssertEqual(ComposerPasteMenu.action(advertised: AdvertSpy(["public.png"])), .attachImage)
        XCTAssertEqual(ComposerPasteMenu.action(advertised: AdvertSpy(["com.compuserve.gif"])), .attachImage)
        XCTAssertEqual(ComposerPasteMenu.action(advertised: AdvertSpy(["com.adobe.pdf"])), .attachPDF)
        XCTAssertEqual(ComposerPasteMenu.action(advertised: AdvertSpy(["public.utf8-plain-text", "public.png"])),
                       .insertText(offerAsFile: false), "text beside an image: the text")
        XCTAssertEqual(
            ComposerPasteMenu.action(advertised: AdvertSpy(["public.utf8-plain-text", "public.url", "public.png"])),
            .attachImage, "a link beside an image (Copy Image): the image"
        )
        let files = AdvertSpy(["public.file-url", "public.utf8-plain-text"], files: 2)
        XCTAssertEqual(ComposerPasteMenu.action(advertised: files), .attachFiles([]))
        let uncounted = AdvertSpy(["public.file-url", "public.utf8-plain-text"], files: 0)
        XCTAssertEqual(ComposerPasteMenu.action(advertised: uncounted), .attachFiles([]), "items not countable")
        XCTAssertEqual(ComposerPasteMenu.action(advertised: AdvertSpy(["NSFilenamesPboardType"])), .attachFiles([]))
        let control = ComposerAttachMenu(advertised: uncounted, paste: {}, attach: {})
        XCTAssertEqual(control.menu.items.first?.title, "Paste files")
        XCTAssertNil(ComposerPasteMenu.action(advertised: AdvertSpy(["com.example.private"])))
    }

    func testAttachMenuItemsAndActions() {
        var pastes = 0
        var attaches = 0
        let spy = AdvertSpy(["public.file-url", "public.utf8-plain-text"], files: 2)
        let control = ComposerAttachMenu(advertised: spy, paste: { pastes += 1 }, attach: { attaches += 1 })
        XCTAssertGreaterThan(spy.reads, 0)
        XCTAssertEqual(control.menu.items.map(\.title), ["Paste 2 files", "Attach files…"])
        XCTAssertEqual(control.menu.items.map(\.isEnabled), [true, true])
        XCTAssertEqual(control.menu.items.first?.keyEquivalent, "v")

        control.menu.performActionForItem(at: 0)
        XCTAssertEqual(pastes, 1)
        control.menu.performActionForItem(at: 1)
        XCTAssertEqual(attaches, 1)

        let empty = ComposerAttachMenu(advertised: AdvertSpy([]), paste: { pastes += 1 }, attach: {})
        XCTAssertEqual(empty.menu.items.first?.title, "Paste from clipboard")
        XCTAssertEqual(empty.menu.items.first?.isEnabled, false)
    }

    /// The real pasteboard's advert, on a private pasteboard (never the owner's clipboard).
    func testPasteboardAdvertCountsFileItems() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("wt-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        XCTAssertEqual(pasteboard.fileItemCount, 0)
        pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/a.png"), URL(fileURLWithPath: "/tmp/b.md")] as [NSURL])
        XCTAssertEqual(pasteboard.fileItemCount, 2)
        XCTAssertTrue(pasteboard.advertisedTypes.contains("public.file-url"))
    }
}
