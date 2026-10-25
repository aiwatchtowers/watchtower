import AppKit
import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

/// A finished answer's table drawn as one native text view (spec
/// 2026-10-24 §5c, ask #541): copy as TSV, selection across cells and
/// rows, the run's link gate, a scroll view only when it is wider than the
/// column, a size that no probe width changes, today's height.
@MainActor
final class MarkdownTableTextTests: XCTestCase {
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

    private static let sample = """
        | Step | Tool | Reads |
        |---|---|---|
        | 1 | `list_messages` | [#acme](https://example.com/1) |
        | 2 | `llm` | **12** messages |
        """

    private func table(_ markdown: String = sample) throws -> MarkdownTable {
        guard case let .table(table)? = MarkdownDocument.parse(markdown).first else {
            XCTFail("no table in \(markdown)")
            throw CocoaError(.featureUnsupported)
        }
        return table
    }

    private func tableView(_ markdown: String = sample, navScreens: Set<String> = []) throws -> MarkdownTableTextView {
        let view = MarkdownTableTextView.makeTable()
        view.show(MarkdownTableText.attributed(try table(markdown), links: InlineLinkContext(codeLinks: false, navScreens: navScreens)))
        return view
    }

    private func makeWindow() -> (NSWindow, NSView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        window.contentView = root
        windows.append(window)
        return (window, root)
    }

    // MARK: - Copy and selection

    func testCopiesAsTabSeparatedRows() throws {
        let view = try tableView()
        XCTAssertEqual(view.plainText, "Step\tTool\tReads\n1\tlist_messages\t#acme\n2\tllm\t12 messages")
        let board = NSPasteboard(name: NSPasteboard.Name("watchtower-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        view.setSelectedRange(NSRange(location: 0, length: (view.string as NSString).length))
        XCTAssertEqual(view.writablePasteboardTypes, [.string], "⌘C copies plain text only")
        XCTAssertTrue(view.writeSelection(to: board, types: view.writablePasteboardTypes))
        XCTAssertEqual(board.string(forType: .string), "Step\tTool\tReads\n1\tlist_messages\t#acme\n2\tllm\t12 messages")
    }

    /// A short last row keeps its columns: its missing cells are empty.
    func testAShortRowKeepsItsColumns() throws {
        let view = try tableView("| a | b | c |\n|---|---|---|\n| 1 |")
        XCTAssertEqual(view.plainText, "a\tb\tc\n1\t\t")
    }

    /// A tab the cell's text keeps is a space: the row keeps its columns.
    func testATabInsideACellIsASpace() throws {
        let (_, root) = makeWindow()
        func cPosition(_ markdown: String) throws -> (String, CGFloat) {
            let view = try tableView(markdown)
            let size = view.fittingSize(width: 600)
            view.frame = NSRect(origin: .zero, size: size)
            root.addSubview(view)
            let string = view.string as NSString
            let box = view.firstRect(forCharacterRange: string.range(of: "c", options: .backwards), actualRange: nil)
            return (view.plainText, box.minX)
        }
        let (tabbed, tabbedX) = try cPosition("| a\tb | c |\n|---|---|\n| x | y |")
        XCTAssertEqual(tabbed, "a b\tc\nx\ty")
        let (_, spacedX) = try cPosition("| a b | c |\n|---|---|\n| x | y |")
        XCTAssertEqual(tabbedX, spacedX, accuracy: 0.5, "the second cell stays at its column")
    }

    func testSelectionAcrossCellsAndRowsQuotes() throws {
        let (_, root) = makeWindow()
        let view = try tableView()
        let size = view.fittingSize(width: 600)
        view.frame = NSRect(x: 20, y: 40, width: size.width, height: size.height)
        root.addSubview(view)
        let tracker = ChatSelectionQuoteTracker()
        let region = NSView(frame: NSRect(x: 10, y: 30, width: size.width + 20, height: size.height + 20))
        root.addSubview(region, positioned: .below, relativeTo: nil)
        tracker.addRegion(region)
        let anchor = FlippedView(frame: root.bounds)
        root.addSubview(anchor)
        var quoted: [String] = []
        tracker.quote = ChatFeedSelectionQuote { quoted.append($0) }
        tracker.attach(to: anchor)
        detach = { tracker.detach(from: anchor) }

        let string = view.string as NSString
        view.setSelectedRange(string.range(of: "list_messages"))
        XCTAssertEqual(tracker.selection?.text, "list_messages", "inside one cell")

        let start = string.range(of: "messages\t#acme").location
        let end = NSMaxRange(string.range(of: "llm"))
        view.setSelectedRange(NSRange(location: start, length: end - start))
        XCTAssertEqual(tracker.selection?.text, "messages\t#acme\n2\tllm", "across cells and rows, tab-separated")
        XCTAssertGreaterThan(tracker.selection?.rect.height ?? 0, size.height / 4, "the box covers both rows")
        tracker.askAboutSelection()
        XCTAssertEqual(quoted, ["messages\t#acme\n2\tllm"])
    }

    // MARK: - Look

    func testHeaderIsSemiboldAndColumnsAlign() throws {
        let markdown = "| Name | Mid | Count |\n|:---|:---:|---:|\n| a | b | 1 |\n| a much longer cell | wide middle | 12345 |"
        let text = MarkdownTableText.attributed(try table(markdown), links: InlineLinkContext(codeLinks: false, navScreens: []))
        let name = text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(name.map { NSFontManager.shared.weight(of: $0) }, NSFontManager.shared.weight(of:
            NSFont.systemFont(ofSize: 13, weight: .semibold)), "the header row is semibold")
        let cell = (text.string as NSString).range(of: "a much")
        let body = text.attribute(.font, at: cell.location, effectiveRange: nil) as? NSFont
        XCTAssertFalse(body?.fontDescriptor.symbolicTraits.contains(.bold) ?? true)

        let (_, root) = makeWindow()
        let view = MarkdownTableTextView.makeTable()
        view.show(text)
        let size = view.fittingSize(width: 600)
        view.frame = NSRect(origin: .zero, size: size)
        root.addSubview(view)
        func box(_ needle: String, after: String = "") -> CGRect {
            let string = view.string as NSString
            let from = after.isEmpty ? 0 : NSMaxRange(string.range(of: after))
            let range = string.range(of: needle, range: NSRange(location: from, length: string.length - from))
            return view.firstRect(forCharacterRange: range, actualRange: nil)
        }
        // Leading columns start together, trailing ones end together,
        // centred ones share a centre.
        XCTAssertEqual(box("a", after: "Count").minX, box("a much").minX, accuracy: 0.5)
        XCTAssertEqual(box("1", after: "b").maxX, box("12345").maxX, accuracy: 1)
        XCTAssertEqual(box("Count").maxX, box("12345").maxX, accuracy: 1)
        XCTAssertEqual(box("b", after: "Count").midX, box("wide middle").midX, accuracy: 1)
        XCTAssertGreaterThanOrEqual(box("Mid").minX - box("a much longer cell").maxX, 14, "a column gap as the grid's")
    }

    /// VoiceOver reads the table row by row, its cells in order.
    func testTableIsReadRowByRow() throws {
        let view = try tableView()
        XCTAssertEqual(view.accessibilityRole(), .textArea)
        XCTAssertEqual(view.accessibilityRoleDescription(), "table")
        let value = try XCTUnwrap(view.accessibilityValue() as? String)
        XCTAssertEqual(value, "Step\tTool\tReads\n1\tlist_messages\t#acme\n2\tllm\t12 messages")
    }

    // MARK: - Links

    func testLinksInCellsPassTheGate() throws {
        let markdown = "| a | b | c |\n|---|---|---|\n| [web](https://example.com) | [share](smb://example.com/x) | [inbox](watchtower-nav://inbox) |"
        func link(_ needle: String, _ screens: Set<String>) throws -> Any? {
            let text = MarkdownTableText.attributed(try table(markdown), links: InlineLinkContext(codeLinks: false, navScreens: screens))
            return text.attribute(.link, at: (text.string as NSString).range(of: needle).location, effectiveRange: nil)
        }
        XCTAssertNotNil(try link("web", []))
        XCTAssertNil(try link("share", []), "smb never becomes a link")
        XCTAssertNil(try link("inbox", []), "a screen link needs its screen")
        XCTAssertNotNil(try link("inbox", ["inbox"]))

        let (window, root) = makeWindow()
        let view = try tableView(markdown, navScreens: ["inbox"])
        let coordinator = MarkdownTextRun.Coordinator()
        coordinator.links = InlineLinkContext(codeLinks: false, navScreens: ["inbox"])
        var opened: [URL] = []
        coordinator.openURL = OpenURLAction { opened.append($0); return .handled }
        view.delegate = coordinator
        for raw in ["smb://example.com/x", "file:///Applications/Calculator.app", "watchtower-nav://settings"] {
            XCTAssertTrue(coordinator.textView(view, clickedOnLink: try XCTUnwrap(URL(string: raw)), at: 0), "\(raw) is swallowed")
        }
        XCTAssertEqual(opened, [], "a link the gate strips never reaches openURL")

        // The right-click menu's Open Link is the gated one.
        let size = view.fittingSize(width: 600)
        view.frame = NSRect(origin: NSPoint(x: 0, y: 0), size: size)
        root.addSubview(view)
        let string = view.string as NSString
        let point = view.firstRect(forCharacterRange: NSRange(location: string.range(of: "web").location + 1, length: 1),
                                   actualRange: nil)
        let inWindow = window.convertPoint(fromScreen: NSPoint(x: point.midX, y: point.midY))
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: inWindow, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try XCTUnwrap(view.menu(for: event))
        XCTAssertFalse(menu.items.compactMap(\.action).contains(#selector(NSText.paste(_:))))
        let open = try XCTUnwrap(menu.items.first { $0.title == "Open Link" })
        _ = (open.target as AnyObject?)?.perform(try XCTUnwrap(open.action), with: open)
        XCTAssertEqual(opened.map(\.absoluteString), ["https://example.com"])
    }

    // MARK: - Width and height

    /// The size is the table's own: no proposal (a probe, zero, the
    /// column) changes it or leaves the text laid out at another width.
    func testAProbeWidthNeverChangesTheTable() throws {
        let view = try tableView()
        let natural = view.fittingSize(width: 600)
        XCTAssertGreaterThan(natural.width, 100)
        XCTAssertGreaterThan(natural.height, 40)
        let container = view.textContainer?.size.width
        for width: CGFloat in [0, 40, 100_000, 300] {
            XCTAssertEqual(view.fittingSize(width: width), natural, "width \(width)")
            XCTAssertEqual(view.textContainer?.size.width, container, "the probe left the container alone")
        }
        view.setFrameSize(NSSize(width: 60, height: natural.height))
        XCTAssertEqual(view.textContainer?.size.width, container, "a narrow frame never wraps a row")
        XCTAssertEqual(view.fittingSize(width: 60), natural)

        let host = NSHostingView(rootView: MarkdownTableRun(text: view.attributedString(), codeLinks: false, navScreens: []))
        XCTAssertEqual(host.fittingSize.width, natural.width, accuracy: 1)
        XCTAssertEqual(host.fittingSize.height, natural.height, accuracy: 1)
    }

    private func hosted(_ view: some View, width: CGFloat) -> NSView {
        let (_, root) = makeWindow()
        let host = NSHostingView(rootView: view.frame(width: width))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 300)
        root.addSubview(host)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        return host
    }

    private func count<T: NSView>(_ type: T.Type, in view: NSView) -> Int {
        (view is T ? 1 : 0) + view.subviews.reduce(0) { $0 + count(type, in: $1) }
    }

    func testAFittingTableHasNoScrollViewAndAWideOneHasOne() throws {
        let small = hosted(NativeMarkdownTableView(table: try table()), width: 400)
        XCTAssertEqual(count(NSScrollView.self, in: small), 0, "a table that fits draws without a scroll view")
        XCTAssertEqual(count(NSTextView.self, in: small), 1, "one text view for the whole table")
        let wideRow = (0..<12).map { "column \($0) with a long header" }
        let wide = "| " + wideRow.joined(separator: " | ") + " |\n|" + String(repeating: "---|", count: 12)
        let host = hosted(NativeMarkdownTableView(table: try table(wide)), width: 300)
        XCTAssertEqual(count(NSScrollView.self, in: host), 1, "a table wider than the column keeps one horizontal scroll")
        XCTAssertEqual(count(NSTextView.self, in: host), 1)
    }

    /// A streamed answer that completes keeps its table's height.
    func testHeightMatchesTodaysTable() throws {
        let tables = [
            Self.sample,
            "| Recipe | Channel | Schedule | State | Runs |\n|:---|---|---|:---:|---:|\n" +
                "| Daily digest | #acme-general | weekdays 9:00 | on | 12 |\n" +
                "| Weekly recap with a long name | #acme-team | Fridays 17:00 | off | 3 |",
            "| one |\n|---|\n| a |\n| b |\n| c |\n| d |\n| e |\n| f |\n| g |\n| h |"
        ]
        for markdown in tables {
            let table = try table(markdown)
            for width: CGFloat in [760, 320] {
                func height(_ view: some View) -> CGFloat {
                    NSHostingView(rootView: view.frame(width: width)).fittingSize.height
                }
                let today = height(MarkdownTableView(table: table))
                XCTAssertGreaterThan(today, 50)
                XCTAssertEqual(height(NativeMarkdownTableView(table: table)), today, accuracy: 1,
                               "width \(width): \(markdown.prefix(20))")
            }
        }
    }
}
