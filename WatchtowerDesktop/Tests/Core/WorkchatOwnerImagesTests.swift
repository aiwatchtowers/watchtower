import ChatWire
import Foundation
import WatchtowerChatText
@testable import WatchtowerCore
import XCTest

/// An owner line's pasted images (#2065 tokens sent as quoted paths, dropped image files) read as thumbnails or chips:
/// the paths leave the shown text, the images come out in order. Only a path in the attachments folder is a paste.
final class WorkchatOwnerImagesTests: XCTestCase {
    private let root = "/Users/example/.local/share/watchtower/acme/workchat-attachments"
    private var pasted: String { root + "/214/20261125-111936-1.png" }
    private var spaced: String { root + "/9/shot 1.png" }
    private let dropped = "/Users/example/Desktop/screenshot.jpeg"

    private func split(_ text: String) -> WorkchatOwnerImages {
        WorkchatOwnerImages.split(text, attachmentsRoot: root)
    }

    private func paste(_ path: String) -> WorkchatOwnerImages.ImageFile { .init(path: path, attachmentsRoot: root) }

    func testInlineBarePathLeavesTheText() {
        let result = split("\(pasted) the transcriber does not work")
        XCTAssertEqual(result.text, "the transcriber does not work")
        XCTAssertEqual(result.images, [paste(pasted)])
        XCTAssertEqual(result.images.first?.name, "20261125-111936-1.png")
    }

    func testInlinePathMidSentenceTidiesTheSpaces() {
        let result = split("look at \(pasted) please")
        XCTAssertEqual(result.text, "look at please")
        XCTAssertEqual(result.images.map(\.path), [pasted])
    }

    /// Punctuation around a pasted path (`see [Image #1].`) is the owner's, not the path's: the path still reads as
    /// an image and the punctuation stays in the text.
    func testClosingPunctuationAfterABarePathStaysText() {
        for (text, shown) in [
            ("see \(pasted).", "see."),
            ("\(pasted), look", ", look"),
            ("why \(pasted)?", "why?"),
            ("first \(pasted); then", "first; then"),
            ("this \(pasted)!", "this!"),
            ("in \(pasted): a bug", "in: a bug")
        ] {
            let result = split(text)
            XCTAssertEqual(result.images.map(\.path), [pasted], text)
            XCTAssertEqual(result.text, shown, text)
        }
    }

    func testBracketsAroundAPathGoWithIt() {
        XCTAssertEqual(split("look (\(pasted)) here").text, "look here")
        let partial = split("look (at \(pasted)) here")
        XCTAssertEqual(partial.images.map(\.path), [pasted])
        XCTAssertEqual(partial.text, "look (at) here")
        XCTAssertEqual(split("[\(pasted)]").images.map(\.path), [pasted])
        XCTAssertEqual(split("{\(pasted)}").text, "")
    }

    /// A token pasted right after an opening bracket or quote mid-word expands with no space (`PasteTokens.expand`
    /// lets those touch a path), so the path starts after the bracket or quote: still an image, and brackets or
    /// quotes that held only it go with it.
    func testExpandedTokenAfterAnOpenerMidWord() {
        for (draft, path, shown) in [
            ("compare([Image #1])", pasted, "compare"),
            ("compare[Image #1]", pasted, "compare"),
            ("see (\"[Image #1]\")", pasted, "see"),
            ("see \"[Image #1]\" now", pasted, "see now"),
            ("see '[Image #1]', ok", pasted, "see, ok"),
            ("a{[Image #1]} b", pasted, "a b"),
            ("compare([Image #1])", spaced, "compare")
        ] {
            let sent = PasteTokens.expand(draft, payloads: [1: .image(path: path)], imagePath: WorkchatOutgoing.quoted)
            let result = split(sent)
            XCTAssertEqual(result.images.map(\.path), [path], sent)
            XCTAssertEqual(result.text, shown, sent)
        }
        XCTAssertEqual(split("compare(\(dropped))").images, [], "an image elsewhere, mid-word, is prose")
    }

    func testPunctuationAfterAQuotedPath() {
        let result = split("see \(WorkchatOutgoing.quoted(spaced)), ok")
        XCTAssertEqual(result.images.map(\.path), [spaced])
        XCTAssertEqual(result.text, "see, ok")
        XCTAssertEqual(split("(\(WorkchatOutgoing.quoted(spaced)))").images.map(\.path), [spaced])
        XCTAssertEqual(split("\(WorkchatOutgoing.quoted(spaced))x").images, [],
                       "a word glued after the quote: not a whole token")
    }

    /// Two pastes glued end to end (sent with no space between them) are two images.
    func testGluedPathsSplitInTwo() {
        let second = pasted.replacingOccurrences(of: "-1.png", with: "-2.PNG")
        let result = split("look \(pasted)\(second).")
        XCTAssertEqual(result.images.map(\.path), [pasted, second])
        XCTAssertEqual(result.text, "look.")
    }

    func testQuotedPathWithSpacesIsUnescaped() {
        let weird = root + "/1/a \"b\" \\c.png"
        let text = "first \(WorkchatOutgoing.quoted(spaced)) then \(WorkchatOutgoing.quoted(weird))"
        let result = split(text)
        XCTAssertEqual(result.text, "first then")
        XCTAssertEqual(result.images, [paste(spaced), paste(weird)])
    }

    func testPathOnItsOwnLineDropsTheLine() {
        let result = split("see these\n\(pasted)\n\(WorkchatOutgoing.quoted(dropped))")
        XCTAssertEqual(result.text, "see these")
        XCTAssertEqual(result.images, [paste(pasted), .init(path: dropped, attachmentsRoot: nil)],
                       "a dropped image elsewhere is a chip, never read")
    }

    func testOnlyAnImageLeavesNoText() {
        let result = split(pasted)
        XCTAssertEqual(result.text, "")
        XCTAssertEqual(result.images.count, 1)
    }

    /// No TCC prompt (P0): only a path in the real attachments folder is read; an image elsewhere on a line of its
    /// own is a chip, one named mid-sentence is prose — whether or not it exists, which is never looked up.
    func testOnlyTheAttachmentsFolderIsAPaste() {
        XCTAssertEqual(split("save the chart to \(dropped) please").images, [],
                       "an image named mid-sentence outside the attachments folder is prose")
        XCTAssertEqual(split("write it to\n\(dropped)").images, [.init(path: dropped, attachmentsRoot: nil)])
        XCTAssertEqual(split("write it to\n\(dropped)").text, "write it to")

        let lookalike = "/Users/example/Desktop/workchat-attachments/1/a.png"
        XCTAssertEqual(split("see \(lookalike) now").images, [], "a folder of the same name elsewhere is not it")
        XCTAssertEqual(split(lookalike).images, [.init(path: lookalike, attachmentsRoot: nil)])

        let escaping = root + "/1/../../../../Desktop/a.png"
        XCTAssertEqual(split("see \(escaping) now").images, [], "a `..` cannot lead out of the folder")
        XCTAssertEqual(split(root + "/./1/a.png").images.map(\.isAttachment), [false])
        XCTAssertEqual(split(root + "x/1/a.png").images.map(\.isAttachment), [false], "a sibling sharing the prefix")

        XCTAssertEqual(WorkchatOwnerImages.split("see \(pasted) now", attachmentsRoot: nil).images, [],
                       "no attachments folder known: nothing is a paste")
        XCTAssertEqual(WorkchatOwnerImages.split(pasted, attachmentsRoot: root + "/").images.map(\.isAttachment), [true],
                       "a root given with its closing slash")
    }

    func testNonImageAndRelativePathsStay() {
        let pdf = "/Users/example/.local/share/watchtower/acme/workchat-attachments/1/x.pdf"
        let text = "read \(pdf)\nand docs/shot.png and /tmp/notes.txt"
        let result = split(text)
        XCTAssertEqual(result.text, text)
        XCTAssertEqual(result.images, [])
    }

    func testImageMarkerLineGoesOnlyWithAThumbnail() {
        let shown = split("\(pasted) look\n[image]")
        XCTAssertEqual(shown.text, "look")
        let kept = split("look\n[image]")
        XCTAssertEqual(kept.text, "look\n[image]", "no thumbnail: the marker is all the owner sees of the image")
    }

    func testImageMarkerLinesOfBothSpellingsGo() {
        XCTAssertEqual(split("\(pasted) look\n[Image #1]\n  [image]  ").text, "look")
        XCTAssertEqual(split("\(pasted) look\n[Image #1] and more").text, "look\n[Image #1] and more",
                       "a marker inside the owner's words stays")
    }

    /// CRLF line ends: a path on its own line still stands alone.
    func testCRLFLinesStandAlone() {
        let result = split("see this\r\n\(dropped)\r\n\(pasted)\r\nok")
        XCTAssertEqual(result.images, [.init(path: dropped, attachmentsRoot: nil), paste(pasted)])
        XCTAssertEqual(result.text, "see this\nok")
    }

    func testCyrillicTextAroundAPath() {
        let result = split("вот скрин \(pasted), глянь\nи ещё:\n\(dropped)")
        XCTAssertEqual(result.images.map(\.path), [pasted, dropped])
        XCTAssertEqual(result.text, "вот скрин, глянь\nи ещё:")
        XCTAssertEqual(split("сохрани в \(dropped) пожалуйста").images, [], "an outside path mid-sentence is prose")
    }

    func testUnchangedTextIsReturnedAsIs() {
        let text = "  keep\n\n  my   spacing  "
        XCTAssertEqual(split(text).text, text)
    }

    func testSamePathTwiceIsOneImage() {
        let result = split("\(pasted) and \(pasted)")
        XCTAssertEqual(result.text, "and")
        XCTAssertEqual(result.images.count, 1)
    }

    func testUppercaseExtensionsAndTheListedKinds() {
        for ext in ["PNG", "jpg", "gif", "webp", "tiff", "heic"] {
            let path = root + "/1/a.\(ext)"
            XCTAssertEqual(split(path).images.map(\.path), [path], ext)
        }
    }

    func testAdapterShowsOwnerTextWithoutPathsAndKeepsOthers() {
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        let entries = [
            SessionFeedEntry(id: "o1", kind: "owner", at: at, text: "\(pasted) why"),
            SessionFeedEntry(id: "a1", kind: "agent", at: at, text: "Saved to \(pasted)")
        ]
        let messages = WorkchatFeedAdapter.messages(entries, attachmentsRoot: root)
        XCTAssertEqual(messages.map(\.text), ["why", "Saved to \(pasted)"], "only the owner's lines lose their paths")
    }

    /// The shown text and the bubble's images come from one split per entry text, kept across renders.
    @MainActor
    func testPaneSplitsAnOwnerLineOnce() {
        let cache = SessionFeedMarkdownCache()
        let entries = [SessionFeedEntry(id: "o1", kind: "owner", text: "\(pasted) why"),
                       SessionFeedEntry(id: "a1", kind: "agent", text: "ok")]
        let root = root
        let split: (SessionFeedEntry) -> WorkchatOwnerImages = {
            cache.ownerImages(id: $0.id, text: $0.text, attachmentsRoot: root)
        }
        XCTAssertEqual(WorkchatFeedAdapter.messages(entries, ownerSplit: split).map(\.text), ["why", "ok"])
        XCTAssertEqual(split(entries[0]).images, [paste(pasted)])
        _ = WorkchatFeedAdapter.messages(entries, ownerSplit: split)
        XCTAssertEqual(cache.splitCount, 1, "agent lines are not split; the owner's once")
        _ = cache.ownerImages(id: "o1", text: "\(pasted) why not", attachmentsRoot: root)
        XCTAssertEqual(cache.splitCount, 2, "a changed text splits again")
    }

    func testEchoStillMatchesTheSentLine() {
        let sentAt = Date(timeIntervalSince1970: 1_700_000_000)
        let line = WorkchatOutgoing(id: UUID(), text: "\(pasted) why", sentAt: sentAt, state: .sent,
                                    typedText: "[Image #1] why", attachmentPaths: [pasted])
        let echo = SessionFeedEntry(id: "o1", kind: "owner", at: sentAt, text: "\(pasted) why")
        XCTAssertTrue(WorkchatOutgoing.matches(echo, line: line), "the display split leaves the feed's text alone")
    }
}
