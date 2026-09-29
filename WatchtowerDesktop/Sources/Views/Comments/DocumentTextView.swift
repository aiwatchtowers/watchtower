import AppKit
import SwiftUI
import WatchtowerCore

/// Rendered text → `NSAttributedString`: fonts per style run, then a
/// yellow background on every anchored thread (stronger on the active one).
enum DocumentAttributedString {
    static let bodyFont = NSFont.systemFont(ofSize: 14)
    static let highlight = NSColor.systemYellow.withAlphaComponent(0.25)
    static let activeHighlight = NSColor.systemYellow.withAlphaComponent(0.55)

    static func make(_ doc: RenderedDocument, highlights: [Int64: NSRange], activeThreadID: Int64?) -> NSAttributedString {
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

/// A read-only, selectable `NSTextView` (SwiftUI `Text` cannot report a
/// selection range). Reports the selection, and a zero-length click's
/// location so the pane can open the thread under it.
struct DocumentTextView: NSViewRepresentable {
    let text: NSAttributedString
    @Binding var selection: NSRange
    let onClick: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 20, height: 16)
        textView.delegate = context.coordinator
        context.coordinator.apply(text, to: textView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? NSTextView else { return }
        context.coordinator.apply(text, to: textView)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: DocumentTextView
        private var shown: NSAttributedString?
        private var applying = false

        init(parent: DocumentTextView) {
            self.parent = parent
        }

        /// Replaces the text only when it changed, keeping the selection and
        /// scroll position (a highlight change re-renders the same text).
        func apply(_ text: NSAttributedString, to textView: NSTextView) {
            guard shown !== text else { return }
            shown = text
            applying = true
            let selected = textView.selectedRange()
            let visible = textView.visibleRect
            textView.textStorage?.setAttributedString(text)
            if NSMaxRange(selected) <= text.length { textView.setSelectedRange(selected) }
            textView.scrollToVisible(visible)
            applying = false
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !applying, let textView = notification.object as? NSTextView else { return }
            let range = textView.selectedRange()
            DispatchQueue.main.async { [parent] in
                parent.selection = range
                if range.length == 0 { parent.onClick(range.location) }
            }
        }
    }
}
