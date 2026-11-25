import ChatWire
import Foundation
import WatchtowerChatText
@testable import WatchtowerCore
import XCTest

/// An owner line's pasted images (#2065 tokens sent as quoted paths, dropped image files) read `[Image #N]` in its
/// bubble, as the paste tokens did in the field: each path is replaced where it stood, numbered in order.
final class WorkchatOwnerImagesTests: XCTestCase {
    private let root = "/Users/example/.local/share/watchtower/acme/workchat-attachments"
    private var pasted: String { root + "/214/20261125-111936-1.png" }
    private var spaced: String { root + "/9/shot 1.png" }
    private let dropped = "/Users/example/Desktop/screenshot.jpeg"

    private func shown(_ text: String) -> String { WorkchatOwnerImages.shown(text) }

    func testPastedPathReadsAsItsToken() {
        XCTAssertEqual(shown("\(pasted) the transcriber does not work"), "[Image #1] the transcriber does not work")
        XCTAssertEqual(shown("look at \(pasted) please"), "look at [Image #1] please")
        XCTAssertEqual(shown(pasted), "[Image #1]")
    }

    func testImagesAreNumberedInOrderAndARepeatKeepsItsNumber() {
        let second = root + "/214/20261125-111936-2.png"
        XCTAssertEqual(shown("\(pasted) vs \(second), again \(pasted)"), "[Image #1] vs [Image #2], again [Image #1]")
        XCTAssertEqual(shown("\(pasted)\nand\n\(second)"), "[Image #1]\nand\n[Image #2]", "numbers run across lines")
    }

    /// Punctuation around a pasted path (`see [Image #1].`) is the owner's, not the path's.
    func testPunctuationAroundAPathStays() {
        for (text, expected) in [
            ("see \(pasted).", "see [Image #1]."),
            ("\(pasted), look", "[Image #1], look"),
            ("why \(pasted)?", "why [Image #1]?"),
            ("look (\(pasted)) here", "look ([Image #1]) here"),
            ("see \(WorkchatOutgoing.quoted(spaced)), ok", "see [Image #1], ok")
        ] {
            XCTAssertEqual(shown(text), expected, text)
        }
        XCTAssertEqual(shown("\(WorkchatOutgoing.quoted(spaced))x"), "\(WorkchatOutgoing.quoted(spaced))x",
                       "a word glued after the quote: not a whole token")
    }

    /// What the field sends reads back as what the owner typed: the sender (`PasteTokens.expand` +
    /// `WorkchatOutgoing.quoted`) run over a draft, then shown.
    func testSentDraftReadsBackAsTyped() {
        for (draft, path) in [
            ("compare([Image #1])", pasted),
            ("see '[Image #1]', ok", pasted),
            ("[Image #1] the bug", spaced),
            ("compare([Image #1])", spaced)
        ] {
            let sent = PasteTokens.expand(draft, payloads: [1: .image(path: path)], imagePath: WorkchatOutgoing.quoted)
            XCTAssertEqual(shown(sent), draft, sent)
        }
        XCTAssertEqual(shown("compare(\(dropped))"), "compare(\(dropped))", "an image elsewhere, mid-word, is prose")
    }

    /// Two pastes glued end to end (an older build sent them with no space) are two images.
    func testGluedPathsReadAsTwoTokens() {
        let second = pasted.replacingOccurrences(of: "-1.png", with: "-2.PNG")
        XCTAssertEqual(shown("look \(pasted)\(second)."), "look [Image #1] [Image #2].")
    }

    func testQuotedPathWithSpacesAndEscapes() {
        let weird = root + "/1/a \"b\" \\c.png"
        let text = "first \(WorkchatOutgoing.quoted(spaced)) then \(WorkchatOutgoing.quoted(weird))"
        XCTAssertEqual(shown(text), "first [Image #1] then [Image #2]")
    }

    /// A dropped image anywhere reads as a token on its own line; one named mid-sentence outside the attachments
    /// folder is the owner's prose and stays. Nothing is looked up on disk.
    func testDroppedImageOnItsOwnLineAndProseElsewhere() {
        XCTAssertEqual(shown("see these\n\(pasted)\n\(WorkchatOutgoing.quoted(dropped))"),
                       "see these\n[Image #1]\n[Image #2]")
        XCTAssertEqual(shown("save the chart to \(dropped) please"), "save the chart to \(dropped) please")
        XCTAssertEqual(shown("сохрани в \(dropped) пожалуйста"), "сохрани в \(dropped) пожалуйста")
    }

    func testNonImageAndRelativePathsStay() {
        let text = "read \(root)/1/x.pdf\nand docs/shot.png and /tmp/notes.txt"
        XCTAssertEqual(shown(text), text)
    }

    /// The marker line Claude Code or Go adds for an image goes once the image reads as its token; a line the parser
    /// itself turned into `[Image #N]` stays.
    func testImageMarkerLineGoesOnlyWithAnImage() {
        XCTAssertEqual(shown("\(pasted) look\n[image]"), "[Image #1] look")
        XCTAssertEqual(shown("\(pasted) look\n[Image #1]\n  [image]  "), "[Image #1] look")
        XCTAssertEqual(shown("look\n[image]"), "look\n[image]", "no image: the marker is all the owner sees")
        XCTAssertEqual(shown("look\n\(pasted)"), "look\n[Image #1]")
    }

    func testCRLFLinesStandAlone() {
        XCTAssertEqual(shown("see this\r\n\(dropped)\r\nok"), "see this\n[Image #1]\nok")
    }

    func testUnchangedTextIsReturnedAsIs() {
        let text = "  keep\n\n  my   spacing  "
        XCTAssertEqual(shown(text), text)
    }

    func testUppercaseExtensionsAndTheListedKinds() {
        for ext in ["PNG", "jpg", "gif", "webp", "tiff", "heic"] {
            XCTAssertEqual(shown(root + "/1/a.\(ext)"), "[Image #1]", ext)
        }
    }

    /// In Markdown a line opening with `[Image #1]:` would be a link definition and vanish: the feed escapes it.
    func testMarkdownEscapesALabelThatCouldDefineALink() {
        XCTAssertEqual(WorkchatOwnerImages.shown("\(pasted): a bug", markdown: true), "\\[Image #1]: a bug")
        XCTAssertEqual(WorkchatOwnerImages.shown("\(pasted) a bug", markdown: true), "[Image #1] a bug")
        XCTAssertEqual(shown("\(pasted): a bug"), "[Image #1]: a bug", "plain text needs no escape")
    }

    func testAdapterShowsOwnerTokensAndKeepsOthers() {
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        let entries = [
            SessionFeedEntry(id: "o1", kind: "owner", at: at, text: "\(pasted) why"),
            SessionFeedEntry(id: "a1", kind: "agent", at: at, text: "Saved to \(pasted)")
        ]
        XCTAssertEqual(WorkchatFeedAdapter.messages(entries).map(\.text), ["[Image #1] why", "Saved to \(pasted)"],
                       "only the owner's lines change")
    }

    func testEchoStillMatchesTheSentLine() {
        let sentAt = Date(timeIntervalSince1970: 1_700_000_000)
        let line = WorkchatOutgoing(id: UUID(), text: "\(pasted) why", sentAt: sentAt, state: .sent,
                                    typedText: "[Image #1] why", attachmentPaths: [pasted])
        let echo = SessionFeedEntry(id: "o1", kind: "owner", at: sentAt, text: "\(pasted) why")
        XCTAssertTrue(WorkchatOutgoing.matches(echo, line: line), "showing the tokens leaves the feed's text alone")
    }
}
