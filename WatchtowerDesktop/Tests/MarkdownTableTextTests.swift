import AppKit
import DesignKit
import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

/// A finished answer's table drawn as one native text view (spec
/// 2026-10-24 §5c, ask #541): copy as TSV, selection across cells and
/// rows, the run's link gate, no scroll view — a wide table fills the
/// column and wraps (ask #1197) —, a size probe that leaves the shown
/// table alone, the streaming table's height.
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
        view.show(try table(markdown), links: InlineLinkContext(codeLinks: false, navScreens: navScreens))
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
            let string = view.plainText as NSString
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

        let string = view.plainText as NSString
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
        view.show(try table(markdown), links: InlineLinkContext(codeLinks: false, navScreens: []))
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

    /// "Пункт | Что сказано": short labels and long sentences.
    private static let wide: String = {
        let sentence = "Сказано, что команда переносит запуск на следующую неделю, потому что проверка ещё не закончена"
        let rows = (1...9).map { "| Пункт \($0) | \(sentence) и пункт \($0) остаётся открытым |" }
        return "| Пункт | Что сказано |\n|---|---|\n" + rows.joined(separator: "\n")
    }()

    private static let wideSentence = "Сказано, что команда переносит запуск на следующую неделю, потому что проверка ещё не закончена и пункт"

    /// The natural table for no width, zero or a wide one; a narrower
    /// width fills it; a probe never leaves the shown table at its width.
    func testAProbeLeavesTheShownTableAlone() throws {
        let view = try tableView(Self.wide)
        let natural = view.fittingSize(width: 0)
        XCTAssertGreaterThan(natural.width, 600)
        XCTAssertEqual(view.fittingSize(width: 100_000), natural)
        XCTAssertEqual(view.fittingSize(width: .infinity), natural)

        view.setFrameSize(NSSize(width: 400, height: 300))
        let narrow = view.fittingSize(width: 400)
        XCTAssertEqual(narrow.width, 400, "a wide table fills the width")
        XCTAssertGreaterThan(narrow.height, natural.height * 2, "its long column wraps")
        let shown = view.attributedString()
        XCTAssertEqual(view.fittingSize(width: 0), natural)
        XCTAssertEqual(view.fittingSize(width: 250).width, 250)
        XCTAssertTrue(view.attributedString().isEqual(to: shown), "the frame's table is back after a probe")
        XCTAssertEqual(view.textContainer?.size.width, 100_000, "the container never wraps the table")

        let host = NSHostingView(rootView: MarkdownTableRun(table: try table(Self.wide),
                                                            links: InlineLinkContext(codeLinks: false, navScreens: [])))
        XCTAssertEqual(host.fittingSize.width, natural.width, accuracy: 1)
        XCTAssertEqual(host.fittingSize.height, natural.height, accuracy: 1)
    }

    /// A wrapping table reports exactly the width it was given, so the
    /// frame SwiftUI sets from it lays out the very columns that were
    /// measured — the rounded columns' sum may lay out others (a review
    /// counterexample: natural 100/1000/1001 at 301 vs 300).
    func testTheFrameLaysOutTheMeasuredColumns() throws {
        let markdown = "| a | \(String(repeating: "word ", count: 200)) | \(String(repeating: "term ", count: 200)) |\n|---|---|---|\n| x | y | z |"
        let view = try tableView(markdown)
        let table = try table(markdown)
        let links = InlineLinkContext(codeLinks: false, navScreens: [])
        for width: CGFloat in [180, 301, 333.5, 401, 517] {
            let size = view.fittingSize(width: width)
            XCTAssertEqual(size.width, width, "width \(width)")
            view.setFrameSize(size)
            XCTAssertTrue(view.attributedString().isEqual(to: MarkdownTableText.attributed(table, links: links, width: width)),
                          "width \(width): the frame shows the measured table")
            XCTAssertEqual(view.fittingSize(width: size.width), size)
        }
    }

    /// The streaming table sizes its columns from its own cells: a table
    /// that fits in a larger font does not wrap.
    func testTheStreamingTableMeasuresItsOwnFont() throws {
        let table = try table()
        func size(_ font: Font) -> CGSize {
            NSHostingView(rootView: MarkdownTableView(table: table).font(font).fixedSize()).fittingSize
        }
        let body = size(.body)
        let title = size(.title)
        XCTAssertGreaterThan(title.width, body.width * 1.3, "the columns grow with the font")
        XCTAssertLessThan(title.height, body.height * 2.2, "and its rows stay one line each")
    }

    /// A selection survives the table's relayout at another width.
    func testASelectionSurvivesAResize() throws {
        let view = try tableView(Self.wide)
        view.setFrameSize(NSSize(width: 700, height: 300))
        let range = (view.plainText as NSString).range(of: "Пункт 3")
        view.setSelectedRange(range)
        view.setFrameSize(NSSize(width: 380, height: 300))
        _ = view.fittingSize(width: 500)
        XCTAssertEqual(view.selectedRange(), range)
    }

    private func hosted(_ view: some View, width: CGFloat) -> NSView {
        let (_, root) = makeWindow()
        let host = NSHostingView(rootView: view.frame(width: width))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 400)
        root.addSubview(host)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        return host
    }

    private func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }

    func testNoTableHasAScrollView() throws {
        let small = hosted(NativeMarkdownTableView(table: try table()), width: 400)
        XCTAssertEqual(views(NSScrollView.self, in: small).count, 0, "a table that fits draws without a scroll view")
        XCTAssertEqual(views(NSTextView.self, in: small).count, 1, "one text view for the whole table")
        let host = hosted(NativeMarkdownTableView(table: try table(Self.wide)), width: 360)
        XCTAssertEqual(views(NSScrollView.self, in: host).count, 0, "a table wider than the column has no scroll view either")
        XCTAssertEqual(views(NSTextView.self, in: host).count, 1)
    }

    /// A wide table fits the column: the short column on one line, the
    /// long one wrapped, every cell inside the view, rows top-aligned.
    func testAWideTableWrapsItsLongColumnInsideTheColumn() throws {
        let host = hosted(NativeMarkdownTableView(table: try table(Self.wide)), width: 360)
        let view = try XCTUnwrap(views(MarkdownTableTextView.self, in: host).first)
        XCTAssertLessThanOrEqual(view.frame.width, 360 - 2 * Spacing.regular + 0.5)
        let layout = try XCTUnwrap(view.layoutManager)
        let container = try XCTUnwrap(view.textContainer)
        func box(_ needle: String) -> CGRect {
            let range = (view.plainText as NSString).range(of: needle)
            return layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil),
                                       in: container)
        }
        let label = box("Пункт 1")
        XCTAssertGreaterThan(label.height, 0)
        XCTAssertLessThan(label.height, MarkdownRunText.bodyFont.pointSize * 2, "the short column stays on one line")
        let sentence = box(Self.wideSentence + " 1")
        XCTAssertGreaterThan(sentence.height, label.height * 2, "the long column wraps")
        XCTAssertLessThanOrEqual(sentence.maxX, view.frame.width + 0.5, "no cell runs past the view")
        XCTAssertGreaterThan(sentence.minX, label.maxX, "the long column starts after the short one")
        XCTAssertEqual(box("Пункт 9").minY, box(Self.wideSentence + " 9").minY, accuracy: 0.5, "a row's cells start together")
        XCTAssertGreaterThan(box("Пункт 2").minY, sentence.maxY, "the next row starts below the tallest cell")

        // Copy keeps one line per row, tab-separated.
        let rows = view.plainText.components(separatedBy: "\n")
        XCTAssertEqual(rows.count, 10)
        XCTAssertEqual(rows[1].components(separatedBy: "\t").count, 2)
        XCTAssertTrue(rows[1].hasPrefix("Пункт 1\tСказано, что"))
    }

    /// A streamed answer that completes keeps its table's height, at a
    /// width it fits and one it has to wrap at.
    func testHeightMatchesTheStreamingTable() throws {
        let tables = [
            Self.sample,
            "| Recipe | Channel | Schedule | State | Runs |\n|:---|---|---|:---:|---:|\n" +
                "| Daily digest | #acme-general | weekdays 9:00 | on | 12 |\n" +
                "| Weekly recap with a long name | #acme-team | Fridays 17:00 | off | 3 |",
            "| one |\n|---|\n| a |\n| b |\n| c |\n| d |\n| e |\n| f |\n| g |\n| h |",
            Self.wide
        ]
        for markdown in tables {
            let table = try table(markdown)
            for width: CGFloat in [760, 320] {
                func height(_ view: some View) -> CGFloat {
                    NSHostingView(rootView: view.frame(width: width)).fittingSize.height
                }
                let streaming = height(MarkdownTableView(table: table))
                XCTAssertGreaterThan(streaming, 50)
                XCTAssertEqual(height(NativeMarkdownTableView(table: table)), streaming, accuracy: 2,
                               "width \(width): \(markdown.prefix(20))")
            }
        }
    }
}
