#if os(macOS)
import AppKit
import SwiftUI
import WatchtowerDesign
import WatchtowerChatText

/// Routes a user-initiated ⌘V (board #534): Finder files, images and PDF
/// data become attachments; text inserts as always, and a long one is
/// reported so the composer can offer to attach it instead.
public final class PastingTextView: NSTextView {
    var onPasteData: ((Data, String) async -> Bool)?
    var onAttachFiles: (([URL]) -> Void)?
    var onLongTextPaste: ((LongPaste) -> Void)?
    /// Always `.general` in the app; tests pass a private named pasteboard.
    var pasteboard: NSPasteboard = .general

    override public func paste(_ sender: Any?) {
        guard let onPasteData else {
            insertFromPasteboard(sender)
            return
        }
        switch PastedContent.action(from: pasteboard) {
        case .attachFiles(let urls):
            guard let onAttachFiles else { break }
            onAttachFiles(urls)
            return
        case .attachImage:
            guard let image = PastedContent.imageAttachment(from: pasteboard) else { break }
            Task { _ = await onPasteData(image.data, image.name) }
            return
        case .attachPDF:
            guard let pdf = PastedContent.pdfData(from: pasteboard) else { break }
            Task { _ = await onPasteData(pdf, PastedContent.pdfName) }
            return
        case .insertText(let offerAsFile):
            pasteText(sender, offerAsFile: offerAsFile)
            return
        }
        insertFromPasteboard(sender)
    }

    /// The stock text paste. In the app this is literally `super.paste`;
    /// a test's private pasteboard goes through `readSelection(from:)`, the
    /// call `paste(_:)` makes on the general pasteboard.
    private func insertFromPasteboard(_ sender: Any?) {
        if pasteboard === NSPasteboard.general {
            super.paste(sender)
        } else {
            readSelection(from: pasteboard)
        }
    }

    /// The normal paste; a long one reports the exact range it inserted.
    private func pasteText(_ sender: Any?, offerAsFile: Bool) {
        let start = selectedRange().location
        insertFromPasteboard(sender)
        let end = selectedRange().location
        guard offerAsFile, let onLongTextPaste, end > start else { return }
        let range = NSRange(location: start, length: end - start)
        let inserted = (string as NSString).substring(with: range)
        onLongTextPaste(LongPaste(
            text: inserted,
            isIntact: { [weak self] in self?.holds(inserted, at: range) == true },
            remove: { [weak self] in self?.removeUndoably(inserted, at: range) }
        ))
    }

    func holds(_ text: String, at range: NSRange) -> Bool {
        let current = string as NSString
        return NSMaxRange(range) <= current.length && current.substring(with: range) == text
    }

    /// Takes the pasted range out as a normal edit, so ⌘Z puts it back and
    /// the undo stack never points at text the field no longer holds.
    func removeUndoably(_ text: String, at range: NSRange) {
        guard holds(text, at: range), shouldChangeText(in: range, replacementString: "") else { return }
        textStorage?.replaceCharacters(in: range, with: "")
        didChangeText()
        undoManager?.setActionName("Attach as File")
        setSelectedRange(NSRange(location: range.location, length: 0))
    }
}

#endif
