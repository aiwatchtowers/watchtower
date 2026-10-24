import AppKit
import DesignKit
import SwiftUI
import WatchtowerCore

/// A finished chat answer's markdown (spec 2026-10-24 §5b): its prose is
/// drawn by one native text view per run instead of a selectable SwiftUI
/// `Text` per block. A streaming answer keeps `MarkdownView` — a separate
/// view, so the streaming row's body stays exactly as it was — and switches
/// when it completes. Same parse and link rules as `MarkdownView`.
struct NativeMarkdownView: View {
    let text: String
    @Environment(\.markdownCodeLinks) private var codeLinks

    var body: some View {
        MarkdownSegmentsView(blocks: MarkdownDocument.parse(codeLinks ? CodeLineLinks.linkified(text) : text))
    }
}

/// A finished answer's markdown as segments (spec 2026-10-24 §5b): each run
/// of prose is one native text view (`MarkdownTextRun`), the other blocks
/// keep their SwiftUI views. Same stack spacing as `MarkdownBlocksView`.
struct MarkdownSegmentsView: View {
    let blocks: [MarkdownBlock]
    @Environment(\.markdownCodeLinks) private var codeLinks
    @Environment(\.markdownNavScreens) private var navScreens

    var body: some View {
        let links = InlineLinkContext(codeLinks: codeLinks, navScreens: navScreens)
        let segments = MarkdownRunBuilder.segments(blocks)
        VStack(alignment: .leading, spacing: MarkdownRunBuilder.blockSpacing) {
            ForEach(segments.indices, id: \.self) { index in
                switch segments[index] {
                case let .textRun(run):
                    MarkdownTextRun(text: MarkdownRunText.attributed(run, links: links), codeLinks: codeLinks,
                                    navScreens: navScreens)
                case let .block(block):
                    MarkdownBlockView(block: block).textSelection(.enabled)
                }
            }
        }
    }
}

extension NSAttributedString.Key {
    /// A paragraph's block-quote bars, as `[x, id, x, id, …]` numbers: the
    /// bar's left edge and the quote it belongs to (`MarkdownRunTextView`
    /// draws one bar per quote over all its paragraphs).
    static let markdownQuoteBars = NSAttributedString.Key("watchtower.markdownQuoteBars")
    /// What a task marker's attachment reads as in plain text.
    static let markdownPlainText = NSAttributedString.Key("watchtower.markdownPlainText")
}

/// A `MarkdownRun` → the attributed text of its native view, styled as
/// `MarkdownBlockView` draws the same blocks: `.body` prose, bold `.title` /
/// `.title2` / `.title3` / `.headline` headings, monospaced inline code,
/// secondary list markers and quotes, the stacks' spacing. Links pass
/// `MarkdownView.inlineText`, the gate every markdown link passes.
enum MarkdownRunText {
    /// Between a list marker and its item (`MarkdownListView`).
    static let markerGap = Spacing.compact
    /// A block quote's bar (`MarkdownBlockView`'s quote).
    static let quoteBarWidth: CGFloat = 3
    /// A block quote's text from the quote's left edge: the bar and the
    /// gap, as `MarkdownBlockView`'s quote pads its stack.
    static let quoteIndent = quoteBarWidth + Spacing.regular

    private struct Key: Hashable {
        let run: MarkdownRun
        let links: InlineLinkContext
    }

    /// Cost = characters, as the inline memo.
    private static let memo = MarkdownMemo<Key, NSAttributedString>(totalCostLimit: 4 << 20)

    static func attributed(_ run: MarkdownRun, links: InlineLinkContext) -> NSAttributedString {
        memo.value(for: Key(run: run, links: links), cost: { $0.length }, build: { build(run, links: links) })
    }

    private static func build(_ run: MarkdownRun, links: InlineLinkContext) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (index, paragraph) in run.paragraphs.enumerated() {
            let start = out.length
            appendParagraph(paragraph, links: links, to: out)
            if index < run.paragraphs.count - 1 {
                out.append(NSAttributedString(string: "\n", attributes: [.font: font(for: paragraph.kind)]))
            }
            let range = NSRange(location: start, length: out.length - start)
            out.addAttribute(.paragraphStyle, value: paragraphStyle(paragraph), range: range)
            let bars = quoteBars(paragraph)
            if !bars.isEmpty { out.addAttribute(.markdownQuoteBars, value: bars, range: range) }
        }
        return out
    }

    private static func appendParagraph(
        _ paragraph: MarkdownRunParagraph,
        links: InlineLinkContext,
        to out: NSMutableAttributedString
    ) {
        let quoted = paragraph.levels.contains { if case .quote = $0 { true } else { false } }
        let color: NSColor = quoted ? .secondaryLabelColor : .labelColor
        for marker in markers(paragraph) {
            out.append(markerText(marker))
            out.append(NSAttributedString(string: "\t", attributes: [.font: bodyFont]))
        }
        let heading = if case .heading = paragraph.kind { true } else { false }
        let size = font(for: paragraph.kind).pointSize
        let inline = MarkdownView.inlineText(paragraph.inlines, links: links)
        for piece in inline.runs {
            let intent = piece.inlinePresentationIntent ?? []
            let text = String(inline[piece.range].characters).replacingOccurrences(of: "\n", with: "\u{2028}")
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font(size: size, bold: heading || intent.contains(.stronglyEmphasized),
                            italic: intent.contains(.emphasized), mono: intent.contains(.code)),
                .foregroundColor: color
            ]
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = piece.link { attributes[.link] = link }
            out.append(NSAttributedString(string: text, attributes: attributes))
        }
    }

    // MARK: - Fonts

    private static var bodyFont: NSFont { NSFont.preferredFont(forTextStyle: .body) }

    /// `MarkdownBlockView.headingFont` with `.bold`, or `.body`.
    private static func font(for kind: MarkdownRunParagraph.Kind) -> NSFont {
        switch kind {
        case .body: return bodyFont
        case let .heading(level):
            let style: NSFont.TextStyle = switch level {
            case 1: .title1
            case 2: .title2
            case 3: .title3
            default: .headline
            }
            return NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: style).pointSize, weight: .bold)
        }
    }

    private static func font(size: CGFloat, bold: Bool, italic: Bool, mono: Bool) -> NSFont {
        let weight: NSFont.Weight = bold ? .bold : .regular
        let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        guard italic else { return font }
        let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.italic))
        return NSFont(descriptor: descriptor, size: size) ?? font
    }

    // MARK: - Lists and quotes

    /// The markers of the list items that start on `paragraph`, outermost
    /// first, with their level.
    private static func markers(_ paragraph: MarkdownRunParagraph) -> [(level: Int, marker: MarkdownRunMarker)] {
        paragraph.levels.enumerated().compactMap { index, level in
            guard index >= paragraph.startsAt, case let .listItem(marker) = level else { return nil }
            return (index, marker)
        }
    }

    private static func markerText(_ entry: (level: Int, marker: MarkdownRunMarker)) -> NSAttributedString {
        switch entry.marker {
        case .bullet: markerString("\u{2022}")
        case let .number(value): markerString("\(value).")
        case .checked: taskMarker(checked: true)
        case .unchecked: taskMarker(checked: false)
        }
    }

    private static func markerString(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: bodyFont.pointSize, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
    }

    /// `checkmark.square` / `square` in the secondary colour, as
    /// `MarkdownListView` draws a task's marker; plain text reads ☑ / ☐.
    private static func taskMarker(checked: Bool) -> NSAttributedString {
        let attachment = NSTextAttachment()
        let image = taskImage(checked: checked)
        attachment.image = image
        let font = bodyFont
        attachment.bounds = CGRect(x: 0, y: (font.capHeight - image.size.height) / 2, width: image.size.width,
                                   height: image.size.height)
        let text = NSMutableAttributedString(attachment: attachment)
        text.addAttributes([.font: font, .markdownPlainText: checked ? "\u{2611}" : "\u{2610}"],
                           range: NSRange(location: 0, length: text.length))
        return text
    }

    /// Drawn on demand, so the secondary colour follows the appearance the
    /// text is drawn in (a symbol image tinted up front keeps its first one).
    private static func taskImage(checked: Bool) -> NSImage {
        checked ? checkedImage : uncheckedImage
    }

    private static let checkedImage = tintedSymbol("checkmark.square", description: "Done")
    private static let uncheckedImage = tintedSymbol("square", description: "Not done")

    private static func tintedSymbol(_ name: String, description: String) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: bodyFont.pointSize, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(configuration) else { return NSImage() }
        let image = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            NSColor.secondaryLabelColor.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.cacheMode = .never
        image.accessibilityDescription = description
        return image
    }

    private static func markerWidth(_ marker: MarkdownRunMarker) -> CGFloat {
        switch marker {
        case .checked: taskImage(checked: true).size.width
        case .unchecked: taskImage(checked: false).size.width
        case .bullet, .number: ceil(markerText((0, marker)).size().width)
        }
    }

    /// The left edge of each level and, last, of the paragraph's text.
    private static func edges(_ paragraph: MarkdownRunParagraph) -> [CGFloat] {
        var edges: [CGFloat] = [0]
        for level in paragraph.levels {
            let step: CGFloat = switch level {
            case .quote: quoteIndent
            case let .listItem(marker): markerWidth(marker) + markerGap
            }
            edges.append((edges.last ?? 0) + step)
        }
        return edges
    }

    private static func paragraphStyle(_ paragraph: MarkdownRunParagraph) -> NSParagraphStyle {
        let edges = edges(paragraph)
        let text = edges.last ?? 0
        let markers = markers(paragraph)
        let style = NSMutableParagraphStyle()
        style.headIndent = text
        style.firstLineHeadIndent = markers.first.map { edges[$0.level] } ?? text
        style.tabStops = (markers.dropFirst().map { edges[$0.level] } + (markers.isEmpty ? [] : [text]))
            .map { NSTextTab(textAlignment: .left, location: $0) }
        style.paragraphSpacingBefore = paragraph.spacingBefore
        style.lineBreakMode = .byWordWrapping
        return style
    }

    private static func quoteBars(_ paragraph: MarkdownRunParagraph) -> [NSNumber] {
        let edges = edges(paragraph)
        return paragraph.levels.enumerated().flatMap { index, level -> [NSNumber] in
            guard case let .quote(id) = level else { return [] }
            return [NSNumber(value: Double(edges[index])), NSNumber(value: id)]
        }
    }
}

/// One run's non-editable, selectable TextKit 2 text view. Selection spans
/// the run's paragraphs; ⌘C copies plain text; leaving the view drops the
/// selection, as a selectable SwiftUI `Text`'s. Draws the block-quote bars.
final class MarkdownRunTextView: NSTextView {
    /// The last two measurements (SwiftUI may alternate two proposals).
    private var measured: [(width: CGFloat, size: CGSize)] = []
    private weak var shown: NSAttributedString?
    private var plainTextCache: String?
    /// Set while `fittingSize` lays the text out at a probe width: a frame
    /// change AppKit makes meanwhile must not move the container back.
    private var measuring = false
    /// Whether the text has a block quote, whose bar `draw` adds.
    private var hasQuoteBars = false

    static func make() -> MarkdownRunTextView {
        let view = MarkdownRunTextView(usingTextLayoutManager: true)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.importsGraphics = false
        view.allowsUndo = false
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        // The width is ours to set (`setFrameSize`, `fittingSize`).
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.heightTracksTextView = false
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.displaysLinkToolTips = false
        // Read-only text: no checking or detection pass on every layout.
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticTextCompletionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.linkTextAttributes = [.foregroundColor: NSColor.controlAccentColor, .cursor: NSCursor.pointingHand]
        return view
    }

    /// Shows `text`; the same (memoised) text is left alone.
    func show(_ text: NSAttributedString) {
        guard text !== shown, let storage = textStorage else { return }
        shown = text
        guard !storage.isEqual(to: text) else { return }
        storage.setAttributedString(text)
        measured = []
        plainTextCache = nil
        hasQuoteBars = false
        text.enumerateAttribute(.markdownQuoteBars, in: NSRange(location: 0, length: text.length)) { value, _, stop in
            if value != nil { hasQuoteBars = true; stop.pointee = true }
        }
        needsDisplay = true
    }

    /// The text's size laid out at `width`: what SwiftUI sizes the row
    /// with, so a `LazyVStack` row measures right and does not jump when it
    /// scrolls back in. Its width is the widest line. A probe at another
    /// width than the view's own puts the container back at the view's
    /// width, so the shown text never keeps a probe's wrapping.
    func fittingSize(width: CGFloat) -> CGSize {
        if let hit = measured.first(where: { $0.width == width }) { return hit.size }
        guard let layout = textLayoutManager, textContainer != nil else { return .zero }
        measuring = true
        // A zero-width container is unbounded in TextKit 2: a 0 proposal is
        // laid out at the narrowest real width instead.
        setContainerWidth(max(width, 1))
        layout.ensureLayout(for: layout.documentRange)
        let bounds = layout.usageBoundsForTextContainer
        measuring = false
        let size = CGSize(width: ceil(bounds.width), height: ceil(bounds.height))
        if frame.width > 0, frame.width != width { setContainerWidth(frame.width) }
        measured = [(width, size)] + measured.prefix(1)
        return size
    }

    private func setContainerWidth(_ width: CGFloat) {
        guard let container = textContainer, container.size.width != width else { return }
        container.size = CGSize(width: width, height: .greatestFiniteMagnitude)
    }

    /// The container always follows the view's width (a resize, or the
    /// frame SwiftUI sets after measuring).
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if newSize.width > 0, !measuring { setContainerWidth(newSize.width) }
    }

    func fittingHeight(width: CGFloat) -> CGFloat { fittingSize(width: width).height }

    /// The text as the owner reads it: a task marker as ☑ / ☐, a line break
    /// as a newline. Same length as `string`, so selection ranges apply.
    var plainText: String {
        if let plainTextCache { return plainTextCache }
        let plain = buildPlainText()
        plainTextCache = plain
        return plain
    }

    private func buildPlainText() -> String {
        guard let storage = textStorage else { return string }
        let plain = NSMutableString(string: storage.string.replacingOccurrences(of: "\u{2028}", with: "\n"))
        storage.enumerateAttribute(.markdownPlainText, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let value = value as? String, (value as NSString).length == range.length else { return }
            plain.replaceCharacters(in: range, with: value)
        }
        return plain as String
    }

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string else { return false }
        let plain = plainText as NSString
        let text = selectedRanges
            .map(\.rangeValue)
            .filter { $0.length > 0 && NSMaxRange($0) <= plain.length }
            .map { plain.substring(with: $0) }
            .joined(separator: "\n")
        return !text.isEmpty && pboard.setString(text, forType: .string)
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, selectedRange().length > 0 {
            setSelectedRange(NSRange(location: selectedRange().location, length: 0))
        }
        return resigned
    }

    /// A read-only menu: no editing items, and the link's Open Link is
    /// ours — it goes through `textView(_:clickedOnLink:at:)`, the same gate
    /// as a click, whatever AppKit's own item would do
    /// (`MarkdownTextRunTests.testContextMenuOpensLinksOnlyThroughTheGate`).
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let menu = super.menu(for: event) else { return nil }
        for item in menu.items where Self.isEditingItem(item) || item.action == Self.appKitOpenLink {
            menu.removeItem(item)
        }
        if let (url, index) = link(at: event) {
            let open = NSMenuItem(title: "Open Link", action: #selector(openLinkFromMenu(_:)), keyEquivalent: "")
            open.target = self
            open.representedObject = url
            open.tag = index
            menu.insertItem(open, at: 0)
        }
        var previousSeparator = true
        for item in menu.items {
            if item.isSeparatorItem, previousSeparator { menu.removeItem(item) }
            previousSeparator = item.isSeparatorItem
        }
        if let last = menu.items.last, last.isSeparatorItem { menu.removeItem(last) }
        return menu
    }

    @objc private func openLinkFromMenu(_ sender: NSMenuItem) {
        guard let url = sender.representedObject else { return }
        _ = delegate?.textView?(self, clickedOnLink: url, at: sender.tag)
    }

    /// The link under the event, if any, and its character index.
    private func link(at event: NSEvent) -> (Any, Int)? {
        guard let window, let storage = textStorage else { return nil }
        let screenPoint = window.convertPoint(toScreen: event.locationInWindow)
        let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        for candidate in [index, index - 1] where candidate >= 0 && candidate < storage.length {
            guard let link = storage.attribute(.link, at: candidate, effectiveRange: nil) else { continue }
            let box = firstRect(forCharacterRange: NSRange(location: candidate, length: 1), actualRange: nil)
            if box.insetBy(dx: -1, dy: -1).contains(screenPoint) { return (link, candidate) }
        }
        return nil
    }

    private static let appKitOpenLink = NSSelectorFromString("_openLinkFromMenu:")

    private static let editingActions: Set<Selector> = [
        #selector(cut(_:)), #selector(paste(_:)), #selector(pasteAsPlainText(_:)),
        NSSelectorFromString("toggleQuickLookPreviewPanel:")
    ]

    /// Cut, Paste, Quick Look and the Font / Spelling / Substitutions
    /// submenus; Speech stays.
    private static func isEditingItem(_ item: NSMenuItem) -> Bool {
        if let action = item.action, editingActions.contains(action) { return true }
        guard let submenu = item.submenu else { return false }
        return !submenu.items.contains { $0.action == #selector(startSpeaking(_:)) }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawQuoteBars(in: dirtyRect)
    }

    /// One bar per quote, from its first line's top to its last line's
    /// bottom (the gaps between its paragraphs included), over the
    /// fragments from the dirty rect's top through the first one below it.
    private func drawQuoteBars(in dirtyRect: NSRect) {
        guard hasQuoteBars, let layout = textLayoutManager else { return }
        var spans: [Int: CGRect] = [:]
        let origin = textContainerOrigin
        // From a paragraph's spacing above the dirty rect, so a rect that
        // starts in the gap between two quoted paragraphs repaints the bar.
        let top = CGPoint(x: 0, y: max(0, dirtyRect.minY - origin.y - MarkdownRunBuilder.blockSpacing - 1))
        let start = layout.textLayoutFragment(for: top)?.rangeInElement.location ?? layout.documentRange.location
        layout.enumerateTextLayoutFragments(from: start, options: []) { fragment in
            guard let paragraph = fragment.textElement as? NSTextParagraph,
                  paragraph.attributedString.length > 0,
                  let bars = paragraph.attributedString.attribute(.markdownQuoteBars, at: 0, effectiveRange: nil) as? [NSNumber]
            else { return true }
            let frame = fragment.layoutFragmentFrame
            let top = frame.minY + (fragment.textLineFragments.first?.typographicBounds.minY ?? 0)
            let bottom = frame.minY + (fragment.textLineFragments.last?.typographicBounds.maxY ?? frame.height)
            for index in stride(from: 0, to: bars.count - 1, by: 2) {
                let rect = CGRect(x: origin.x + CGFloat(bars[index].doubleValue), y: origin.y + top,
                                  width: MarkdownRunText.quoteBarWidth, height: bottom - top)
                let id = bars[index + 1].intValue
                spans[id] = spans[id].map { $0.union(rect) } ?? rect
            }
            return origin.y + frame.minY <= dirtyRect.maxY
        }
        guard !spans.isEmpty else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.4).setFill()
        spans.values.forEach { $0.fill() }
    }
}

/// One run of a finished answer's prose in its native text view. Links go
/// through the surface's `openURL` (the main window's gate opens
/// `watchtower-nav://` screens with `AppState.openNavLink`; the code
/// question popover opens its `path:line` links) and only when
/// `AllowedURLSchemes.keepsLink` keeps them — AppKit never opens a link.
struct MarkdownTextRun: NSViewRepresentable {
    let text: NSAttributedString
    let codeLinks: Bool
    let navScreens: Set<String>

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var openURL: OpenURLAction?
        var links = InlineLinkContext(codeLinks: false, navScreens: [])

        /// Always handled: a link the gate keeps goes to the surface's
        /// `openURL`, any other does nothing.
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            guard let url, let openURL,
                  AllowedURLSchemes.keepsLink(url, renderOnly: links.renderOnly, navScreens: links.navScreens) else { return true }
            openURL(url)
            return true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MarkdownRunTextView {
        let view = MarkdownRunTextView.make()
        view.delegate = context.coordinator
        view.show(text)
        return view
    }

    func updateNSView(_ view: MarkdownRunTextView, context: Context) {
        context.coordinator.openURL = context.environment.openURL
        context.coordinator.links = InlineLinkContext(codeLinks: codeLinks, navScreens: navScreens)
        view.show(text)
    }

    /// The proposed width (the column), or the widest line when none is
    /// proposed; the height of the text at that width.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MarkdownRunTextView, context: Context) -> CGSize? {
        if let width = proposal.width, width.isFinite {
            return CGSize(width: width, height: nsView.fittingHeight(width: width))
        }
        // Unwrapped, each paragraph is as many lines as at its widest line.
        return nsView.fittingSize(width: Self.unwrappedWidth)
    }

    private static let unwrappedWidth: CGFloat = 100_000
}
