import AppKit
import SwiftUI
import WatchtowerCore

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

/// A request to scroll the text so `offset` (UTF-16) sits at the top — a
/// table-of-contents jump. A new `id` asks again for the same offset.
struct DocumentScrollTarget: Equatable {
    let offset: Int
    let id = UUID()
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
    /// Scrolls once per new target, after the text is applied.
    var scrollTarget: DocumentScrollTarget?
    let onClick: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = Self.makeScrollView(horizontalInset: horizontalInset)
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.delegate = context.coordinator
        context.coordinator.apply(text, contentID: contentID, to: textView)
        context.coordinator.observeGeometry(of: scroll)
        // A rebuilt view must not replay a jump made in its predecessor.
        context.coordinator.scrolledTargetID = scrollTarget?.id
        return scroll
    }

    /// The read-only text view in its scroll view, on TextKit 1 from the
    /// start: `NSTextTable` (rendered tables) needs it, and the selection
    /// geometry reads `layoutManager` — on a TextKit 2 view that first read
    /// switches it to TextKit 1 mid-session and lays the whole text out
    /// again, so the owner's first selection could move the text (#179).
    static func makeScrollView(horizontalInset: CGFloat) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        _ = textView.layoutManager // opts this view into TextKit 1 while it is still empty
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: horizontalInset, height: 16)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? NSTextView else { return }
        Self.setInset(horizontalInset, on: textView)
        context.coordinator.apply(text, contentID: contentID, to: textView)
        context.coordinator.scroll(textView, to: scrollTarget)
    }

    /// A new inset re-wraps every line: the line the owner reads stays at
    /// the top. (A width change needs no help — NSTextView keeps its top
    /// line itself.)
    static func setInset(_ inset: CGFloat, on textView: NSTextView) {
        guard textView.textContainerInset.width != inset else { return }
        let anchor = ReadingAnchor.top(of: textView)
        textView.textContainerInset = NSSize(width: inset, height: 16)
        anchor?.restore(in: textView)
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

        /// Replaces the text only when it changed. The same characters (a
        /// highlight change, a new comment, a re-read of an unchanged file)
        /// keep the reading position; new characters start at the top. New
        /// content clears the selection — in the view and in the binding.
        func apply(_ text: NSAttributedString, contentID: String, to textView: NSTextView) {
            let sameContent = shownID == contentID
            if sameContent, let shown, shown === text || shown.isEqual(to: text) { return }
            let sameText = shown?.string == text.string
            shown = text
            shownID = contentID
            applying = true
            let selected = textView.selectedRange()
            let anchor = sameText ? ReadingAnchor.top(of: textView) : nil
            textView.textStorage?.setAttributedString(text)
            let carried = DocumentSelectionCarry.carried(selected, sameContent: sameContent, newLength: text.length)
            textView.setSelectedRange(carried)
            if let anchor { anchor.restore(in: textView) } else if !sameText { textView.scroll(.zero) }
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

        private weak var observedTextView: NSTextView?
        var scrolledTargetID: UUID?

        /// Puts the target's line at the top of the visible area, once.
        func scroll(_ textView: NSTextView, to target: DocumentScrollTarget?) {
            let length = textView.string.utf16.count
            guard let target, target.id != scrolledTargetID, length > 0,
                  let layout = textView.layoutManager, let container = textView.textContainer else { return }
            scrolledTargetID = target.id
            let char = NSRange(location: min(max(target.offset, 0), length - 1), length: 1)
            let glyphs = layout.glyphRange(forCharacterRange: char, actualCharacterRange: nil)
            let line = layout.boundingRect(forGlyphRange: glyphs, in: container)
            textView.scroll(NSPoint(x: 0, y: max(line.minY + textView.textContainerOrigin.y - 8, 0)))
        }

        /// Scrolling and resizing move the selection on screen.
        func observeGeometry(of scroll: NSScrollView) {
            guard let textView = scroll.documentView as? NSTextView else { return }
            observedTextView = textView
            scroll.contentView.postsBoundsChangedNotifications = true
            textView.postsFrameChangedNotifications = true
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(geometryDidChange),
                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
            center.addObserver(self, selector: #selector(geometryDidChange),
                               name: NSView.frameDidChangeNotification, object: textView)
        }

        @objc private func geometryDidChange() {
            if let observedTextView { reportSelectionRect(observedTextView) }
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

/// A reading position that survives re-wrapping: the character at the top
/// of the visible area and how far into its line the view was scrolled.
struct ReadingAnchor: Equatable {
    let character: Int
    let offset: CGFloat

    static func top(of textView: NSTextView) -> Self? {
        guard textView.textStorage?.length ?? 0 > 0,
              let layout = textView.layoutManager, let container = textView.textContainer else { return nil }
        let top = textView.visibleRect.minY - textView.textContainerOrigin.y
        let glyph = layout.glyphIndex(for: NSPoint(x: 0, y: max(top, 0)), in: container)
        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return Self(character: layout.characterIndexForGlyph(at: glyph), offset: top - line.minY)
    }

    func restore(in textView: NSTextView) {
        guard character < textView.textStorage?.length ?? 0,
              let layout = textView.layoutManager, let container = textView.textContainer else { return }
        layout.ensureLayout(for: container)
        let line = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: character), effectiveRange: nil)
        textView.scroll(NSPoint(x: 0, y: max(line.minY + offset + textView.textContainerOrigin.y, 0)))
    }
}
