import ChatWire
import Foundation
@testable import WatchtowerCore
import XCTest

/// An owner line's pasted images (#2065 tokens sent as quoted paths, dropped image files) read as thumbnails: the paths
/// leave the shown text, the images come out in order.
final class WorkchatOwnerImagesTests: XCTestCase {
    private let pasted = "/Users/example/.local/share/watchtower/acme/workchat-attachments/214/20261125-111936-1.png"
    private let spaced = "/Users/example/Library/Application Support/watchtower/acme/workchat-attachments/9/20261125-1.png"
    private let dropped = "/Users/example/Desktop/screenshot.jpeg"

    private func split(_ text: String, existing: Set<String>) -> WorkchatOwnerImages {
        WorkchatOwnerImages.split(text) { existing.contains($0) }
    }

    func testInlineBarePathLeavesTheText() {
        let result = split("\(pasted) the transcriber does not work", existing: [pasted])
        XCTAssertEqual(result.text, "the transcriber does not work")
        XCTAssertEqual(result.images, [.init(path: pasted, exists: true)])
        XCTAssertEqual(result.images.first?.name, "20261125-111936-1.png")
    }

    func testInlinePathMidSentenceTidiesTheSpaces() {
        let result = split("look at \(pasted) please", existing: [pasted])
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
            let result = split(text, existing: [pasted])
            XCTAssertEqual(result.images.map(\.path), [pasted], text)
            XCTAssertEqual(result.text, shown, text)
        }
    }

    func testBracketsAroundAPathGoWithIt() {
        XCTAssertEqual(split("look (\(pasted)) here", existing: [pasted]).text, "look here")
        let partial = split("look (at \(pasted)) here", existing: [pasted])
        XCTAssertEqual(partial.images.map(\.path), [pasted])
        XCTAssertEqual(partial.text, "look (at) here")
        XCTAssertEqual(split("[\(pasted)]", existing: [pasted]).images.map(\.path), [pasted])
        XCTAssertEqual(split("{\(pasted)}", existing: [pasted]).text, "")
    }

    func testPunctuationAfterAQuotedPath() {
        let result = split("see \(WorkchatOutgoing.quoted(spaced)), ok", existing: [spaced])
        XCTAssertEqual(result.images.map(\.path), [spaced])
        XCTAssertEqual(result.text, "see, ok")
        XCTAssertEqual(split("(\(WorkchatOutgoing.quoted(spaced)))", existing: [spaced]).images.map(\.path), [spaced])
        XCTAssertEqual(split("\(WorkchatOutgoing.quoted(spaced))x", existing: [spaced]).images, [],
                       "a word glued after the quote: not a whole token")
    }

    /// Two pastes glued end to end (sent with no space between them) are two images.
    func testGluedPathsSplitInTwo() {
        let second = pasted.replacingOccurrences(of: "-1.png", with: "-2.PNG")
        let result = split("look \(pasted)\(second).", existing: [pasted, second])
        XCTAssertEqual(result.images.map(\.path), [pasted, second])
        XCTAssertEqual(result.text, "look.")
    }

    func testQuotedPathWithSpacesIsUnescaped() {
        let weird = "/Users/example/a \"b\" \\c/workchat-attachments/1/x.png"
        let text = "first \(WorkchatOutgoing.quoted(spaced)) then \(WorkchatOutgoing.quoted(weird))"
        let result = split(text, existing: [spaced])
        XCTAssertEqual(result.text, "first then")
        XCTAssertEqual(result.images, [.init(path: spaced, exists: true), .init(path: weird, exists: false)])
    }

    func testPathOnItsOwnLineDropsTheLine() {
        let result = split("see these\n\(pasted)\n\(WorkchatOutgoing.quoted(dropped))", existing: [pasted, dropped])
        XCTAssertEqual(result.text, "see these")
        XCTAssertEqual(result.images.map(\.path), [pasted, dropped])
    }

    func testOnlyAnImageLeavesNoText() {
        let result = split(pasted, existing: [pasted])
        XCTAssertEqual(result.text, "")
        XCTAssertEqual(result.images.count, 1)
    }

    func testMissingPastedFileIsStillAnImageMarkedMissing() {
        let result = split("\(pasted) why", existing: [])
        XCTAssertEqual(result.text, "why", "a swept paste never shows its raw path")
        XCTAssertEqual(result.images, [.init(path: pasted, exists: false)])
    }

    func testOtherImagePathStaysTextInlineOrWhenMissing() {
        XCTAssertEqual(split("save the chart to \(dropped) please", existing: [dropped]).images, [],
                       "an image named mid-sentence outside the pastes folder is prose")
        let missing = split("write it to\n\(dropped)", existing: [])
        XCTAssertEqual(missing.text, "write it to\n\(dropped)")
        XCTAssertEqual(missing.images, [])
    }

    func testNonImageAndRelativePathsStay() {
        let pdf = "/Users/example/.local/share/watchtower/acme/workchat-attachments/1/x.pdf"
        let text = "read \(pdf)\nand docs/shot.png and /tmp/notes.txt"
        let result = split(text, existing: [pdf, "/tmp/notes.txt"])
        XCTAssertEqual(result.text, text)
        XCTAssertEqual(result.images, [])
    }

    func testImageMarkerLineGoesOnlyWithAThumbnail() {
        let shown = split("\(pasted) look\n[image]", existing: [pasted])
        XCTAssertEqual(shown.text, "look")
        let kept = split("look\n[image]", existing: [])
        XCTAssertEqual(kept.text, "look\n[image]", "no thumbnail: the marker is all the owner sees of the image")
    }

    func testUnchangedTextIsReturnedAsIs() {
        let text = "  keep\n\n  my   spacing  "
        XCTAssertEqual(split(text, existing: []).text, text)
    }

    func testSamePathTwiceIsOneImage() {
        let result = split("\(pasted) and \(pasted)", existing: [pasted])
        XCTAssertEqual(result.text, "and")
        XCTAssertEqual(result.images.count, 1)
    }

    func testUppercaseExtensionsAndTheListedKinds() {
        for ext in ["PNG", "jpg", "gif", "webp", "tiff", "heic"] {
            let path = "/x/workchat-attachments/1/a.\(ext)"
            XCTAssertEqual(split(path, existing: []).images.map(\.path), [path], ext)
        }
    }

    func testAdapterShowsOwnerTextWithoutPathsAndKeepsOthers() {
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        let entries = [
            SessionFeedEntry(id: "o1", kind: "owner", at: at, text: "\(pasted) why"),
            SessionFeedEntry(id: "a1", kind: "agent", at: at, text: "Saved to \(pasted)")
        ]
        let messages = WorkchatFeedAdapter.messages(entries) { _ in true }
        XCTAssertEqual(messages.map(\.text), ["why", "Saved to \(pasted)"], "only the owner's lines lose their paths")
        XCTAssertEqual(WorkchatFeedAdapter.ownerImages(entries[0]) { _ in true }.map(\.path), [pasted])
        XCTAssertEqual(WorkchatFeedAdapter.ownerImages(entries[1]) { _ in true }, [])
    }

    func testEchoStillMatchesTheSentLine() {
        let sentAt = Date(timeIntervalSince1970: 1_700_000_000)
        let line = WorkchatOutgoing(id: UUID(), text: "\(pasted) why", sentAt: sentAt, state: .sent,
                                    typedText: "[Image #1] why", attachmentPaths: [pasted])
        let echo = SessionFeedEntry(id: "o1", kind: "owner", at: sentAt, text: "\(pasted) why")
        XCTAssertTrue(WorkchatOutgoing.matches(echo, line: line), "the display split leaves the feed's text alone")
    }
}
