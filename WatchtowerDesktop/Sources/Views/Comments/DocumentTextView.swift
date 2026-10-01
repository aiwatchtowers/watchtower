import AppKit
import SwiftUI
import WatchtowerCore

/// Rendered text → `NSAttributedString`: fonts per style run, then a
/// yellow background on every anchored thread (stronger on the active one)
/// and a blue one on every unsent draft comment.
enum DocumentAttributedString {
    static let bodyFont = NSFont.systemFont(ofSize: 14)
    static let highlight = NSColor.systemYellow.withAlphaComponent(0.25)
    static let activeHighlight = NSColor.systemYellow.withAlphaComponent(0.55)
    static let draftHighlight = NSColor.systemBlue.withAlphaComponent(0.2)

    static func make(
        _ doc: RenderedDocument,
        highlights: [Int64: NSRange],
        activeThreadID: Int64?,
        drafts: [NSRange] = []
    ) -> NSAttributedString {
        let out = NSMutableAttributedString(
            string: doc.text,
            attributes: [.font: bodyFont, .foregroundColor: NSColor.labelColor]
        )
        let length = out.length
        for run in doc.runs where run.location + run.length <= length {
            out.addAttributes(attributes(for: run.style), range: NSRange(location: run.location, length: run.length))
        }
        for (id, range) in highlights where NSMaxRange(range) <= length {
            out.addAttribute(.backgroundColor, value: id == activeThreadID ? activeHighlight : highlight, range: range)
        }
        for range in drafts where NSMaxRange(range) <= length {
            out.addAttribute(.backgroundColor, value: draftHighlight, range: range)
        }
        return out
    }

    static func attributes(for style: DocumentStyle) -> [NSAttributedString.Key: Any] {
        switch style {
        case let .heading(level):
            [.font: NSFont.systemFont(ofSize: level == 1 ? 22 : level == 2 ? 18 : 15, weight: .semibold)]
        case .strong:
            [.font: NSFont.boldSystemFont(ofSize: 14)]
        case .emphasis:
            [.font: NSFontManager.shared.convert(bodyFont, toHaveTrait: .italicFontMask)]
        case .strikethrough:
            [.strikethroughStyle: NSUnderlineStyle.single.rawValue]
        case .code, .codeBlock:
            [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
             .backgroundColor: NSColor.quaternaryLabelColor]
        case .quote:
            [.foregroundColor: NSColor.secondaryLabelColor]
        case .link:
            // Styled only: a click selects text for commenting, it never opens
            // a URL from a document the agent wrote.
            [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
        }
    }
}

/// Which selection survives a text re-apply. A selection is a numeric range,
/// so it is only meaningful on the exact text it was made on: carried across
/// a re-style of the same content (a highlight change), dropped whenever the
/// content identity changes — otherwise doc A's offsets would select, and
/// anchor a comment to, text in doc B the owner never selected.
enum DocumentSelectionCarry {
    static let none = NSRange(location: 0, length: 0)

    static func carried(_ selected: NSRange, sameContent: Bool, newLength: Int) -> NSRange {
        guard sameContent, NSMaxRange(selected) <= newLength else { return none }
        return selected
    }
}

/// A read-only, selectable `NSTextView` (SwiftUI `Text` cannot report a
/// selection range). Reports the selection, and a zero-length click's
/// location so the pane can open the thread under it. With `onCommentRequest`
/// it also reports where the selection is on screen (`selectionRect`, for the
/// floating Comment button) and adds "Comment…" to the text's context menu.
struct DocumentTextView: NSViewRepresentable {
    let text: NSAttributedString
    /// Identity of the rendered content (document + render version, artifact
    /// + version). Equal ids promise identical plain text; a new id clears
    /// the selection (`DocumentSelectionCarry`).
    let contentID: String
    @Binding var selection: NSRange
    /// Left/right text inset; a caller wanting a readable line length on a
    /// wide pane passes `ReadableColumn.horizontalInset(forWidth:)`.
    var horizontalInset: CGFloat = ReadableColumn.minInset
    /// The selection's bounding box in the visible area (top-left origin);
    /// nil without a selection or when it is scrolled out of view.
    var selectionRect: Binding<CGRect?> = .constant(nil)
    /// "Comment…" in the context menu of a non-empty selection.
    var onCommentRequest: (() -> Void)?
    let onClick: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: horizontalInset, height: 16)
        textView.delegate = context.coordinator
        context.coordinator.apply(text, contentID: contentID, to: textView)
        context.coordinator.observeGeometry(of: scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? NSTextView else { return }
        if textView.textContainerInset.width != horizontalInset {
            textView.textContainerInset = NSSize(width: horizontalInset, height: 16)
        }
        context.coordinator.apply(text, contentID: contentID, to: textView)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: DocumentTextView
        private var shown: NSAttributedString?
        private var shownID: String?
        private var applying = false

        init(parent: DocumentTextView) {
            self.parent = parent
        }

        /// Replaces the text only when it changed. The same content (a
        /// highlight change) keeps the selection and scroll position; new
        /// content clears the selection — in the view and in the binding.
        func apply(_ text: NSAttributedString, contentID: String, to textView: NSTextView) {
            let sameContent = shownID == contentID
            if sameContent, let shown, shown === text || shown.isEqual(to: text) { return }
            shown = text
            shownID = contentID
            applying = true
            let selected = textView.selectedRange()
            let visible = textView.visibleRect
            textView.textStorage?.setAttributedString(text)
            let carried = DocumentSelectionCarry.carried(selected, sameContent: sameContent, newLength: text.length)
            textView.setSelectedRange(carried)
            if sameContent { textView.scrollToVisible(visible) } else { textView.scroll(.zero) }
            applying = false
            if carried != selected {
                DispatchQueue.main.async { [parent] in parent.selection = carried }
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            reportSelectionRect(textView)
            guard !applying else { return }
            let range = textView.selectedRange()
            DispatchQueue.main.async { [parent] in
                parent.selection = range
                if range.length == 0 { parent.onClick(range.location) }
            }
        }

        // MARK: - Comment affordance

        /// Scrolling and resizing move the selection on screen.
        func observeGeometry(of scroll: NSScrollView) {
            guard let textView = scroll.documentView as? NSTextView else { return }
            scroll.contentView.postsBoundsChangedNotifications = true
            textView.postsFrameChangedNotifications = true
            let center = NotificationCenter.default
            for (name, object) in [(NSView.boundsDidChangeNotification, scroll.contentView as NSView),
                                   (NSView.frameDidChangeNotification, textView as NSView)] {
                center.addObserver(self, selector: #selector(geometryDidChange(_:)), name: name, object: object)
            }
        }

        @objc private func geometryDidChange(_ notification: Notification) {
            let view = notification.object as? NSView
            let textView = (view as? NSTextView) ?? (view as? NSClipView)?.documentView as? NSTextView
            if let textView { reportSelectionRect(textView) }
        }

        private func reportSelectionRect(_ textView: NSTextView) {
            guard parent.onCommentRequest != nil else { return }
            let rect = Self.visibleSelectionRect(textView)
            guard rect != parent.selectionRect.wrappedValue else { return }
            DispatchQueue.main.async { [parent] in parent.selectionRect.wrappedValue = rect }
        }

        /// The selection's bounding box relative to the visible area, top-left
        /// origin (the clip view of a text view's scroll view is flipped).
        static func visibleSelectionRect(_ textView: NSTextView) -> CGRect? {
            let range = textView.selectedRange()
            guard range.length > 0, let layout = textView.layoutManager, let container = textView.textContainer,
                  let clip = textView.enclosingScrollView?.contentView else { return nil }
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let origin = textView.textContainerOrigin
            let box = layout.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: origin.x, dy: origin.y)
            let inClip = clip.convert(box, from: textView)
            let visible = inClip.offsetBy(dx: -clip.bounds.minX, dy: -clip.bounds.minY)
            return visible.intersects(CGRect(origin: .zero, size: clip.bounds.size)) ? visible : nil
        }

        func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
            guard parent.onCommentRequest != nil, view.selectedRange().length > 0 else { return menu }
            let item = NSMenuItem(title: "Comment…", action: #selector(requestComment), keyEquivalent: "")
            item.target = self
            menu.insertItem(item, at: 0)
            menu.insertItem(.separator(), at: 1)
            return menu
        }

        @objc private func requestComment() {
            parent.onCommentRequest?()
        }
    }
}
