import AppKit
import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

/// A finished answer's prose drawn by one native text view per run (spec
/// 2026-10-24 §5b): the look of `MarkdownBlockView`, the same link gate,
/// screen links through the window's `openURL`, selection quoting, height.
@MainActor
final class MarkdownTextRunTests: XCTestCase {
    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    private var windows: [NSWindow] = []
    private var detach: (() -> Void)?

    override func tearDown() {
        detach?()
        windows.forEach { $0.close() }
        (windows, detach) = ([], nil)
        super.tearDown()
    }

    private func run(_ markdown: String) throws -> MarkdownRun {
        let segments = MarkdownRunBuilder.segments(MarkdownDocument.parse(markdown))
        guard case let .textRun(run)? = segments.first else { throw XCTSkip("no run in \(markdown)") }
        return run
    }

    private func attributed(_ markdown: String, navScreens: Set<String> = []) throws -> NSAttributedString {
        MarkdownRunText.attributed(try run(markdown), links: InlineLinkContext(codeLinks: false, navScreens: navScreens))
    }

    private func attribute<T>(_ key: NSAttributedString.Key, of needle: String, in text: NSAttributedString) throws -> T? {
        let range = (text.string as NSString).range(of: needle)
        XCTAssertNotEqual(range.location, NSNotFound, "\(needle) is in the run")
        return text.attribute(key, at: range.location, effectiveRange: nil) as? T
    }

    private func traits(of needle: String, in text: NSAttributedString) throws -> NSFontDescriptor.SymbolicTraits {
        let font: NSFont = try XCTUnwrap(attribute(.font, of: needle, in: text))
        return font.fontDescriptor.symbolicTraits
    }

    // MARK: - Look

    func testHeadingAndListStylesMatchCurrent() throws {
        let text = try attributed("""
            # Title

            ### Small

            Body *slanted* **bold** `code` ~~gone~~

            - item
            1. first

            > quoted
            """)
        let title: NSFont = try XCTUnwrap(attribute(.font, of: "Title", in: text))
        XCTAssertEqual(title.pointSize, NSFont.preferredFont(forTextStyle: .title1).pointSize, "# is .title")
        XCTAssertTrue(try traits(of: "Title", in: text).contains(.bold), "headings are bold")
        let small: NSFont = try XCTUnwrap(attribute(.font, of: "Small", in: text))
        XCTAssertEqual(small.pointSize, NSFont.preferredFont(forTextStyle: .title3).pointSize, "### is .title3")
        let body: NSFont = try XCTUnwrap(attribute(.font, of: "Body", in: text))
        XCTAssertEqual(body.pointSize, NSFont.preferredFont(forTextStyle: .body).pointSize, "prose is .body")
        XCTAssertFalse(try traits(of: "Body", in: text).contains(.bold))
        XCTAssertTrue(try traits(of: "slanted", in: text).contains(.italic))
        XCTAssertTrue(try traits(of: "bold", in: text).contains(.bold))
        XCTAssertTrue(try traits(of: "code", in: text).contains(.monoSpace))
        let strike: Int = try XCTUnwrap(attribute(.strikethroughStyle, of: "gone", in: text))
        XCTAssertEqual(strike, NSUnderlineStyle.single.rawValue)
        let prose: NSColor = try XCTUnwrap(attribute(.foregroundColor, of: "Body", in: text))
        XCTAssertEqual(prose, .labelColor)

        XCTAssertTrue(text.string.contains("\u{2022}\titem"), "a bullet, then the item at its tab stop")
        XCTAssertTrue(text.string.contains("1.\tfirst"))
        let item: NSParagraphStyle = try XCTUnwrap(attribute(.paragraphStyle, of: "item", in: text))
        XCTAssertGreaterThan(item.headIndent, 0, "wrapped lines of an item hang at its text")
        XCTAssertEqual(item.tabStops.last?.location, item.headIndent)
        let marker: NSColor = try XCTUnwrap(attribute(.foregroundColor, of: "\u{2022}", in: text))
        XCTAssertEqual(marker, .secondaryLabelColor, "list markers are secondary")

        let quote: NSColor = try XCTUnwrap(attribute(.foregroundColor, of: "quoted", in: text))
        XCTAssertEqual(quote, .secondaryLabelColor, "a quote's text is secondary")
        let quoteStyle: NSParagraphStyle = try XCTUnwrap(attribute(.paragraphStyle, of: "quoted", in: text))
        XCTAssertEqual(quoteStyle.headIndent, MarkdownRunText.quoteIndent, "the bar, then the gap")
        XCTAssertNotNil(try attribute(.markdownQuoteBars, of: "quoted", in: text) as [Any]?)
    }

    /// A hard line break stays inside its paragraph (no paragraph spacing),
    /// and paragraphs of one run are separated by real paragraph breaks.
    func testLineBreaksStayInTheirParagraph() throws {
        let text = try attributed("one\\\ntwo\n\nthree")
        XCTAssertEqual(text.string, "one\u{2028}two\nthree")
        let three: NSParagraphStyle = try XCTUnwrap(attribute(.paragraphStyle, of: "three", in: text))
        XCTAssertEqual(three.paragraphSpacingBefore, MarkdownRunBuilder.blockSpacing)
    }

    // MARK: - Links

    func testDisallowedLinkNotClickableInRun() throws {
        let markdown = "[web](https://example.com) [share](smb://example.com/x) [inbox](watchtower-nav://inbox)"
        let plain = try attributed(markdown)
        XCTAssertNotNil(try attribute(.link, of: "web", in: plain) as URL?)
        XCTAssertNil(try attribute(.link, of: "share", in: plain) as URL?, "smb never becomes a link")
        XCTAssertNil(try attribute(.link, of: "inbox", in: plain) as URL?, "a screen link needs its screen")
        let withScreens = try attributed(markdown, navScreens: ["inbox"])
        XCTAssertNotNil(try attribute(.link, of: "inbox", in: withScreens) as URL?)
        XCTAssertNil(try attribute(.link, of: "share", in: withScreens) as URL?)
    }

    func testNavLinkRoutesToOpenNavLink() throws {
        let view = MarkdownRunTextView.make()
        let coordinator = MarkdownTextRun.Coordinator()
        coordinator.links = InlineLinkContext(codeLinks: false, navScreens: ["inbox"])
        var navigated: [URL] = []
        coordinator.openURL = AllowedURLSchemes.openURLAction { navigated.append($0) }
        let nav = try XCTUnwrap(URL(string: "watchtower-nav://inbox"))
        XCTAssertTrue(coordinator.textView(view, clickedOnLink: nav, at: 0), "AppKit never opens it itself")
        XCTAssertEqual(navigated, [nav], "the window's gate hands it to openNavLink")

        var opened: [URL] = []
        coordinator.openURL = OpenURLAction { opened.append($0); return .handled }
        for raw in ["smb://example.com/share", "watchtower-nav://settings", "file:///Applications/Calculator.app"] {
            let url = try XCTUnwrap(URL(string: raw))
            XCTAssertTrue(coordinator.textView(view, clickedOnLink: url, at: 0), "\(raw) is swallowed")
        }
        XCTAssertEqual(opened, [], "a link the gate strips never reaches openURL")
        let web = try XCTUnwrap(URL(string: "https://example.com"))
        XCTAssertTrue(coordinator.textView(view, clickedOnLink: web, at: 0))
        XCTAssertEqual(opened, [web], "an allowed link goes to the surface's openURL")

        coordinator.links = InlineLinkContext(codeLinks: true, navScreens: ["inbox"])
        let code = try XCTUnwrap(URL(string: "\(CodeLineLinks.scheme)://open?path=a.swift&line=3"))
        XCTAssertTrue(coordinator.textView(view, clickedOnLink: code, at: 0))
        XCTAssertEqual(opened.last, code, "the code popover's links keep their handler")
    }

    /// Right-click on a link: Open Link goes through the same gate as a
    /// click, and the read-only menu has no editing items.
    func testContextMenuOpensLinksOnlyThroughTheGate() throws {
        let (window, root) = makeWindow()
        let coordinator = MarkdownTextRun.Coordinator()
        var opened: [URL] = []
        coordinator.openURL = OpenURLAction { opened.append($0); return .handled }
        for (raw, expected) in [("https://example.com/a", 1), ("smb://example.com/share", 0)] {
            opened = []
            let view = MarkdownRunTextView.make()
            let url = try XCTUnwrap(URL(string: raw))
            view.show(NSAttributedString(string: "go there now", attributes: [.link: url, .font: NSFont.systemFont(ofSize: 13)]))
            view.frame = NSRect(x: 0, y: 0, width: 300, height: 40)
            root.addSubview(view)
            view.delegate = coordinator
            _ = view.fittingHeight(width: 300)
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: .rightMouseDown, location: view.convert(NSPoint(x: 10, y: 8), to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            let menu = try XCTUnwrap(view.menu(for: event))
            let actions = menu.items.compactMap(\.action)
            for editing in [#selector(NSText.cut(_:)), #selector(NSText.paste(_:)), #selector(NSTextView.pasteAsPlainText(_:))] {
                XCTAssertFalse(actions.contains(editing), "\(editing) has no place in read-only text")
            }
            XCTAssertFalse(menu.items.contains { $0.submenu?.items.contains { $0.action == #selector(NSTextView.checkSpelling(_:)) } == true })
            XCTAssertFalse(actions.contains(NSSelectorFromString("_openLinkFromMenu:")), "AppKit's own Open Link is replaced")
            let open = try XCTUnwrap(menu.items.first { $0.title == "Open Link" })
            _ = (open.target as AnyObject?)?.perform(try XCTUnwrap(open.action), with: open)
            XCTAssertEqual(opened.count, expected, "\(raw): Open Link reaches openURL only through the gate")
            view.removeFromSuperview()
        }
    }

    // MARK: - Selection

    private func makeWindow() -> (NSWindow, NSView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        window.contentView = root
        windows.append(window)
        return (window, root)
    }

    func testSelectionQuoteReadsRunSelection() throws {
        let (window, root) = makeWindow()
        let text = try attributed("Keep the retry budget small.\n\n- [x] Then *confirm* it")
        let view = MarkdownRunTextView.make()
        view.show(text)
        view.frame = NSRect(x: 20, y: 40, width: 400, height: view.fittingHeight(width: 400))
        root.addSubview(view)
        let tracker = ChatSelectionQuoteTracker()
        let region = NSView(frame: NSRect(x: 10, y: 30, width: 420, height: view.frame.height + 20))
        root.addSubview(region, positioned: .below, relativeTo: nil)
        tracker.addRegion(region)
        let anchor = FlippedView(frame: root.bounds)
        root.addSubview(anchor)
        var quoted: [String] = []
        tracker.quote = ChatFeedSelectionQuote { quoted.append($0) }
        tracker.attach(to: anchor)
        detach = { tracker.detach(from: anchor) }

        let string = view.string as NSString
        view.setSelectedRange(string.range(of: "retry budget"))
        XCTAssertEqual(tracker.selection?.text, "retry budget")
        XCTAssertGreaterThan(tracker.selection?.rect.width ?? 0, 0)

        let start = string.range(of: "small").location
        let end = NSMaxRange(string.range(of: "confirm"))
        view.setSelectedRange(NSRange(location: start, length: end - start))
        XCTAssertEqual(tracker.selection?.text, "small.\n\u{2611}\tThen confirm", "across paragraphs, as plain text")
        tracker.askAboutSelection()
        XCTAssertEqual(quoted, ["small.\n\u{2611}\tThen confirm"])

        let board = NSPasteboard(name: NSPasteboard.Name("watchtower-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        view.setSelectedRange(NSRange(location: start, length: end - start))
        XCTAssertEqual(view.writablePasteboardTypes, [.string], "⌘C copies plain text only")
        XCTAssertTrue(view.writeSelection(to: board, types: view.writablePasteboardTypes))
        XCTAssertEqual(board.string(forType: .string), "small.\n\u{2611}\tThen confirm")

        // Leaving the text view drops its selection, as a SwiftUI Text's.
        XCTAssertTrue(window.makeFirstResponder(view))
        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertEqual(view.selectedRange().length, 0)
        XCTAssertNil(tracker.selection)
    }

    /// VoiceOver reads a run as one text area with its words.
    func testRunIsReadAsText() throws {
        let view = MarkdownRunTextView.make()
        view.show(try attributed("Read **this** aloud.\n\n- and [this](https://example.com)"))
        XCTAssertEqual(view.accessibilityRole(), .textArea)
        let value = try XCTUnwrap(view.accessibilityValue() as? String)
        XCTAssertTrue(value.contains("Read this aloud."))
        XCTAssertTrue(value.contains("and this"))
    }

    // MARK: - Height and tables

    func testRunReportsItsHeightForTheWidth() throws {
        let text = try attributed(String(repeating: "words that wrap across lines ", count: 20) + "\n\n- item")
        let view = MarkdownRunTextView.make()
        view.show(text)
        let wide = view.fittingHeight(width: 700)
        let narrow = view.fittingHeight(width: 200)
        XCTAssertGreaterThan(wide, 0)
        XCTAssertGreaterThan(narrow, wide, "a narrower column wraps into more lines")

        let host = NSHostingView(rootView: MarkdownTextRun(text: text, codeLinks: false, navScreens: [])
            .frame(width: 200))
        XCTAssertEqual(host.fittingSize.height, ceil(narrow), accuracy: 1, "the row is as tall as its text")
    }

    /// A streamed answer that completes switches to native runs without a
    /// visible jump: the same markdown is as tall on both paths.
    func testFinishedAnswerKeepsTheStreamingHeight() {
        for width: CGFloat in [760, 320] {
            func height(native: Bool) -> CGFloat {
                let text = ChatMarkdownShotFixtures.answer
                let view = native ? AnyView(NativeMarkdownView(text: text)) : AnyView(MarkdownView(text: text))
                return NSHostingView(rootView: view.environment(\.markdownNavScreens, ["inbox"]).frame(width: width))
                    .fittingSize.height
            }
            let swiftUI = height(native: false)
            XCTAssertGreaterThan(swiftUI, 200)
            XCTAssertEqual(height(native: true), swiftUI, accuracy: 3, "width \(width)")
        }
    }

    /// Measuring at another width (an ideal-size probe, a zero width)
    /// never leaves the shown text laid out at that width.
    func testProbesKeepTheContainerAtTheViewsWidth() throws {
        let view = MarkdownRunTextView.make()
        view.show(try attributed(String(repeating: "words that wrap across lines ", count: 10)))
        view.setFrameSize(NSSize(width: 200, height: 100))
        let atWidth = view.fittingHeight(width: 200)
        let ideal = view.fittingSize(width: 100_000)
        XCTAssertGreaterThan(ideal.width, 200)
        XCTAssertEqual(view.textContainer?.size.width, 200, "the probe put the container back")
        XCTAssertGreaterThan(view.fittingHeight(width: 0), atWidth, "zero is a real width")
        XCTAssertEqual(view.textContainer?.size.width, 200)
        // The last two widths stay cached: text added behind `show`'s back
        // is not laid out on a hit.
        _ = view.fittingHeight(width: 200)
        _ = view.fittingSize(width: 100_000)
        view.textStorage?.append(NSAttributedString(string: String(repeating: "\nmore", count: 20)))
        XCTAssertEqual(view.fittingHeight(width: 200), atWidth, "a hit for the last two widths")
    }

    func testAResizeRelaysTheText() throws {
        let view = MarkdownRunTextView.make()
        view.show(try attributed(String(repeating: "words that wrap across lines ", count: 10)))
        view.setFrameSize(NSSize(width: 400, height: 100))
        let wide = view.fittingHeight(width: 400)
        view.setFrameSize(NSSize(width: 150, height: 100))
        XCTAssertEqual(view.textContainer?.size.width, 150, "the container follows the view")
        XCTAssertGreaterThan(view.fittingHeight(width: 150), wide)
    }

    private func scrollViews(in view: NSView) -> Int {
        (view is NSScrollView ? 1 : 0) + view.subviews.reduce(0) { $0 + scrollViews(in: $1) }
    }

    private func hostTable(_ markdown: String, width: CGFloat) throws -> NSView {
        guard case let .table(table)? = MarkdownDocument.parse(markdown).first else { throw XCTSkip("no table") }
        let (_, root) = makeWindow()
        let host = NSHostingView(rootView: MarkdownTableView(table: table).frame(width: width))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 200)
        root.addSubview(host)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        return host
    }

    func testTableFitsWidthHasNoScrollView() throws {
        let small = try hostTable("| a | b |\n|---|---|\n| 1 | 2 |", width: 400)
        XCTAssertEqual(scrollViews(in: small), 0, "a table that fits draws without a scroll view")
        let wideRow = (0..<12).map { "column \($0) with a long header" }
        let wide = "| " + wideRow.joined(separator: " | ") + " |\n|" + String(repeating: "---|", count: 12)
        let host = try hostTable(wide, width: 300)
        XCTAssertEqual(scrollViews(in: host), 1, "a table wider than the column keeps its horizontal scroll")
    }
}
