#if os(macOS)
import AppKit
import ChatWire
import WatchtowerChatText
import WatchtowerDesign
import XCTest
@testable import ChatUI

/// Spec 2026-11-24-workchat-polish §2 and 2026-11-26-chat-text-highlights: the agent's text in a highlighting feed gets
/// its refs, hashes, resolved paths, commands, dates and times and `PR #N` / `ask #N` phrases in their `SyntaxTint` —
/// the foreground only, never in a link or in inline code that is not one whole span — and only there.
@MainActor
final class AgentTextHighlightTests: XCTestCase {
    private let markdown = """
    Round 3 of #2188 is ready (67a59755a). Run `make test` or `foo bar`, see [#12](https://example.com) \
    and internal/a.go or docs/missing.md
    """

    private func runText(_ text: String) -> NSAttributedString {
        let segments = MarkdownRunBuilder.segments(MarkdownDocument.parse(text))
        guard case let .textRun(run) = segments.first else {
            XCTFail("one text run expected")
            return NSAttributedString()
        }
        return MarkdownRunText.attributed(run, links: InlineLinkContext(codeLinks: false, navScreens: []))
    }

    private func attributes(of needle: String, in text: NSAttributedString) -> [NSAttributedString.Key: Any] {
        let range = (text.string as NSString).range(of: needle)
        XCTAssertNotEqual(range.location, NSNotFound, needle)
        guard range.location != NSNotFound else { return [:] }
        var effective = NSRange()
        let attributes = text.attributes(at: range.location, effectiveRange: &effective)
        if attributes[.agentHighlight] != nil {
            XCTAssertEqual(effective, range, "the span covers exactly \(needle)")
        }
        return attributes
    }

    private func kind(of needle: String, in text: NSAttributedString) -> AgentTextHighlights.Kind? {
        (attributes(of: needle, in: text)[.agentHighlight] as? AgentTextHighlightBox)?.span.kind
    }

    func testSpansGetTheirTintAndNothingElse() {
        let base = runText(markdown)
        let text = AgentTextHighlightRender.highlighted(base) { $0 == "internal/a.go" }
        XCTAssertEqual(kind(of: "#2188", in: text), .ref(2188))
        XCTAssertEqual(kind(of: "67a59755a", in: text), .hash)
        XCTAssertEqual(kind(of: "make test", in: text), .command)
        XCTAssertEqual(kind(of: "internal/a.go", in: text), .path)
        XCTAssertNil(kind(of: "foo bar", in: text), "inline code that is no command stays plain")
        XCTAssertNil(kind(of: "#12", in: text), "a link is never highlighted")
        XCTAssertNil(kind(of: "docs/missing.md", in: text), "a path that does not resolve stays plain")

        let tints: [(String, NSColor)] = [
            ("#2188", NSColor(SyntaxTint.ref)), ("67a59755a", NSColor(SyntaxTint.hash)),
            ("make test", NSColor(SyntaxTint.command)), ("internal/a.go", NSColor(SyntaxTint.path))
        ]
        for (needle, tint) in tints {
            let attributes = attributes(of: needle, in: text)
            XCTAssertEqual(attributes[.foregroundColor] as? NSColor, tint, needle)
            // D3: no weight, no background, no underline at rest; hashes and paths in the base font's monospaced
            // design (mock 04), refs and commands in the base font (a command is inline code, already monospaced).
            let baseFont = self.attributes(of: needle, in: base)[.font] as? NSFont
            let monospaced = needle == "67a59755a" || needle == "internal/a.go"
            XCTAssertEqual(attributes[.font] as? NSFont,
                           monospaced ? baseFont.map(AgentTextHighlightRender.monospaced) : baseFont, needle)
            if monospaced, let font = attributes[.font] as? NSFont {
                XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.monoSpace), needle)
                XCTAssertEqual(font.pointSize, baseFont?.pointSize, needle)
            }
            XCTAssertNil(attributes[.backgroundColor], needle)
            XCTAssertNil(attributes[.underlineStyle], needle)
        }
    }

    func testNothingToColourKeepsTheRunText() {
        let base = runText("Nothing to see here, `foo bar` and docs/missing.md.")
        XCTAssertTrue(AgentTextHighlightRender.highlighted(base) { _ in false } === base)
    }

    func testTheColouredTextIsMemoisedPerResolvedPaths() {
        let base = runText(markdown)
        let first = AgentTextHighlightRender.highlighted(base) { $0 == "internal/a.go" }
        XCTAssertTrue(AgentTextHighlightRender.highlighted(base) { $0 == "internal/a.go" } === first)
        let both = AgentTextHighlightRender.highlighted(base) { _ in true }
        XCTAssertFalse(both === first)
        XCTAssertEqual(kind(of: "docs/missing.md", in: both), .path)
    }

    private func context(role: String, highlights: Bool) -> ChatPartContext {
        ChatPartContext(message: ChatFeed.Message(id: 1, role: role, text: "#1", createdAt: .distantPast),
                        highlightsAgentText: highlights)
    }

    /// A path candidate that does not resolve leaves the ref inside it coloured; one that resolves takes it.
    func testARefInsideAnUnresolvedPathKeepsItsColour() {
        let base = runText("Round 3 of #2201/T2 is ready")
        XCTAssertEqual(kind(of: "#2201", in: AgentTextHighlightRender.highlighted(base) { _ in false }), .ref(2201))
        XCTAssertEqual(kind(of: "2201/T2", in: AgentTextHighlightRender.highlighted(base) { _ in true }), .path)
    }

    private func color(of needle: String, in text: NSAttributedString) -> NSColor? {
        attributes(of: needle, in: text)[.foregroundColor] as? NSColor
    }

    /// Spec 2026-11-26 §1: inline code that is one whole span takes that kind's tint and click.
    func testInlineCodeHashGetsItsTintAndClick() {
        let base = runText("Landed as `4d434597` today")
        let text = AgentTextHighlightRender.highlighted(base) { _ in false }
        XCTAssertNotNil(base.attribute(.markdownInlineCode, at: (base.string as NSString).range(of: "4d434597").location,
                                       effectiveRange: nil))
        XCTAssertEqual(color(of: "4d434597", in: text), NSColor(SyntaxTint.hash))
        XCTAssertEqual(kind(of: "4d434597", in: text), .hash)
    }

    /// D1: a date and an `ask #N` are coloured and carry no click; the `#990` is the phrase's, not a ref.
    func testColourOnlyKindsCarryNoClick() {
        let base = runText("since 2026-11-16, ask #990")
        let text = AgentTextHighlightRender.highlighted(base) { _ in false }
        XCTAssertEqual(color(of: "2026-11-16", in: text), NSColor(SyntaxTint.time))
        XCTAssertEqual(color(of: "ask #990", in: text), NSColor(SyntaxTint.ref))
        XCTAssertNil(attributes(of: "2026-11-16", in: text)[.agentHighlight])
        XCTAssertNil(attributes(of: "ask #990", in: text)[.agentHighlight])
        XCTAssertNil(attributes(of: "#990", in: text)[.agentHighlight])
        XCTAssertEqual(AgentTextHighlightRender.scan(base).map(\.span.kind), [.time, .ask(990)])
    }

    func testMultiTokenInlineCodeStaysPlain() {
        let base = runText("Set `marking_started: \"2026-11-16\"` first")
        let text = AgentTextHighlightRender.highlighted(base) { _ in true }
        XCTAssertTrue(text === base, "no span: the run text is unchanged")
        XCTAssertEqual(color(of: "2026-11-16", in: text), color(of: "2026-11-16", in: base))
    }

    func testADateInsideAResolvingPathTakesThePathColour() {
        let base = runText("Wrote logs/2026-11-16.txt now")
        let path = (base.string as NSString).range(of: "logs/2026-11-16.txt")
        let resolved = AgentTextHighlightRender.highlighted(base) { $0 == "logs/2026-11-16.txt" }
        var effective = NSRange()
        let pathColor = resolved.attribute(.foregroundColor, at: path.location, effectiveRange: &effective) as? NSColor
        XCTAssertEqual(pathColor, NSColor(SyntaxTint.path))
        XCTAssertEqual(effective, path, "the whole path, the date inside it too, takes the path colour")
        resolved.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: resolved.length)) { value, _, _ in
            XCTAssertNotEqual(value as? NSColor, NSColor(SyntaxTint.time))
        }

        let unresolved = AgentTextHighlightRender.highlighted(base) { _ in false }
        let date = (base.string as NSString).range(of: "2026-11-16")
        let dateColor = unresolved.attribute(.foregroundColor, at: date.location, effectiveRange: &effective) as? NSColor
        XCTAssertEqual(dateColor, NSColor(SyntaxTint.time))
        XCTAssertEqual(effective, date, "only the date is coloured")
    }

    func testOnlyACompletedPlainSingleClickFires() {
        let span = NSRange(location: 4, length: 5)
        XCTAssertTrue(HighlightClick.fires(clickCount: 1, modifiers: [], selectionLength: 0, down: span, up: span))
        XCTAssertTrue(HighlightClick.fires(clickCount: 1, modifiers: [.capsLock], selectionLength: 0, down: span, up: span))
        XCTAssertFalse(HighlightClick.fires(clickCount: 1, modifiers: [], selectionLength: 3, down: span, up: span),
                       "a drag selected text")
        XCTAssertFalse(HighlightClick.fires(clickCount: 1, modifiers: [], selectionLength: 0, down: span, up: nil),
                       "released off the span")
        XCTAssertFalse(HighlightClick.fires(clickCount: 1, modifiers: [], selectionLength: 0, down: span,
                                            up: NSRange(location: 20, length: 3)), "released on another span")
        XCTAssertFalse(HighlightClick.fires(clickCount: 2, modifiers: [], selectionLength: 0, down: span, up: span))
        XCTAssertFalse(HighlightClick.fires(clickCount: 3, modifiers: [], selectionLength: 0, down: span, up: span))
        for modifier: NSEvent.ModifierFlags in [.shift, .control, .command, .option] {
            XCTAssertFalse(HighlightClick.fires(clickCount: 1, modifiers: modifier, selectionLength: 0, down: span, up: span))
        }
    }

    private func textView(onHighlight: ((AgentTextHighlights.Span) -> Void)?) -> (MarkdownRunTextView, [DispatchWorkItem]) {
        let view = MarkdownRunTextView.make()
        view.onHighlight = onHighlight
        view.show(AgentTextHighlightRender.highlighted(runText(markdown)) { $0 == "internal/a.go" })
        return (view, [])
    }

    /// A single click runs after the double-click interval; the second click of a double click drops it.
    func testASecondClickDropsTheWaitingSingleClick() throws {
        var opened: [String] = []
        var scheduled: [DispatchWorkItem] = []
        let (view, _) = textView { opened.append($0.text) }
        view.scheduleClick = { scheduled.append($0) }
        let span = AgentTextHighlights.spans(inPlain: "#2188")[0]

        view.clickBegan(clickCount: 1)
        view.clickEnded(span)
        view.clickBegan(clickCount: 2) // the second click of a double click
        try XCTUnwrap(scheduled.first).perform()
        XCTAssertEqual(opened, [], "a double click never opens")

        view.clickBegan(clickCount: 1)
        view.clickEnded(span)
        view.clickBegan(clickCount: 1) // a new single click elsewhere leaves the first to run
        try XCTUnwrap(scheduled.last).perform()
        XCTAssertEqual(opened, ["#2188"])
    }

    /// Click A, then click B: A's action runs and leaves B's slot alone, so a double click on B still drops B
    /// (review round 3).
    func testAnEarlierClickLeavesALaterClicksSlot() throws {
        var opened: [String] = []
        var scheduled: [DispatchWorkItem] = []
        let (view, _) = textView { opened.append($0.text) }
        view.scheduleClick = { scheduled.append($0) }
        let spanA = AgentTextHighlights.spans(inPlain: "#2188")[0]
        let spanB = AgentTextHighlights.spans(inPlain: "#2189")[0]
        view.clickBegan(clickCount: 1)
        view.clickEnded(spanA)
        view.clickBegan(clickCount: 1)
        view.clickEnded(spanB)
        scheduled[0].perform()
        XCTAssertEqual(opened, ["#2188"])
        view.clickBegan(clickCount: 2) // the second click on B
        scheduled[1].perform()
        XCTAssertEqual(opened, ["#2188"], "the double click on B opens nothing")
    }

    func testWithoutAnActionTheSpansAreInert() throws {
        var scheduled: [DispatchWorkItem] = []
        let (view, _) = textView(onHighlight: nil)
        view.scheduleClick = { scheduled.append($0) }
        view.clickEnded(AgentTextHighlights.spans(inPlain: "#2188")[0])
        XCTAssertEqual(scheduled.count, 0)
        XCTAssertEqual(view.accessibilityCustomActions()?.count ?? 0, 0)
    }

    func testVoiceOverGetsAnActionPerSpan() throws {
        var opened: [String] = []
        let (view, _) = textView { opened.append($0.text) }
        let actions = try XCTUnwrap(view.accessibilityCustomActions())
        XCTAssertEqual(actions.map(\.name), ["Show #2188 on the board", "Copy 67a59755a", "Copy make test",
                                             "Open internal/a.go"])
        _ = actions[3].handler?()
        XCTAssertEqual(opened, ["internal/a.go"])
    }

    /// The hover underline is drawn, never stored: a copy of the text carries none.
    func testTheHoverUnderlineStaysOutOfTheText() throws {
        let (view, _) = textView { _ in }
        let storage = try XCTUnwrap(view.textStorage)
        let range = (storage.string as NSString).range(of: "#2188")
        view.setHoveredHighlight(range)
        XCTAssertNil(storage.attribute(.underlineStyle, at: range.location, effectiveRange: nil))
        view.setHoveredHighlight(nil)
    }

    func testOnlyTheAgentsTextInAHighlightingFeed() {
        XCTAssertNotNil(AgentTextHighlighting(context(role: "assistant", highlights: true)))
        XCTAssertNil(AgentTextHighlighting(context(role: "assistant", highlights: false)))
        XCTAssertNil(AgentTextHighlighting(context(role: "user", highlights: true)))
        XCTAssertFalse(ChatFeedContext().highlightsAgentText, "the AI chat and the phone stay plain by default")
    }

    func testAFeedPassesItsFlagToThePartContext() {
        var actions = ChatPartActions()
        var opened: [AgentTextHighlights.Span] = []
        actions.openHighlight = { span, messageID in
            XCTAssertEqual(messageID, 1)
            opened.append(span)
        }
        actions.resolvesPath = { path, messageID in path == "a/b.go" && messageID == 1 }
        let highlighting = AgentTextHighlighting(ChatPartContext(
            message: ChatFeed.Message(id: 1, role: "assistant", text: "", createdAt: .distantPast),
            actions: actions, highlightsAgentText: true))
        XCTAssertEqual(highlighting?.resolvesPath("a/b.go"), true)
        XCTAssertEqual(highlighting?.resolvesPath("c.go"), false)
        let span = AgentTextHighlights.spans(inPlain: "#7")[0]
        highlighting?.open?(span)
        XCTAssertEqual(opened, [span])
    }
}
#endif
