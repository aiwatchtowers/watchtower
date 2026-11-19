#if os(macOS)
import AppKit
import SwiftUI
import WatchtowerDesign
import WatchtowerChatText

/// Routes a user-initiated ⌘V (board #534): Finder files, images and PDF
/// data become attachments; text inserts as always, and a long one is
/// reported so the composer can offer to attach it instead. With
/// `onInlinePaste` (the Workchat, #2065 §6) an image and a long text go in as
/// the token it returns instead, and one Backspace removes a live token whole.
public final class PastingTextView: NSTextView {
    var onPasteData: ((Data, String) async -> Bool)?
    var onAttachFiles: (([URL]) -> Void)?
    var onLongTextPaste: ((LongPaste) -> Void)?
    /// Keeps a pasted image or long text and returns its token; nil → no inline tokens.
    var onInlinePaste: ((InlinePaste) async -> String?)?
    /// The kind of each token number with a payload (the owner's model): only a token of that number and kind is
    /// deleted whole.
    var livePastes: [Int: PasteKind] = [:]
    private var inlinePastes: Bool { onInlinePaste != nil }
    /// ⌥↓ goes here first (the Workchat steps list): true = handled; false or nil = the stock key.
    var onOptionArrowDown: (() -> Bool)?
    /// Always `.general` in the app; tests pass a private named pasteboard.
    var pasteboard: NSPasteboard = .general

    override public func keyDown(with event: NSEvent) {
        if let onOptionArrowDown, !hasMarkedText(), Self.isOptionArrowDown(event), onOptionArrowDown() {
            return
        }
        super.keyDown(with: event)
    }

    /// ↓ with ⌥ and no other modifier (the arrow keys carry `.numericPad` and `.function` themselves).
    static func isOptionArrowDown(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        return event.keyCode == 125 && modifiers == .option
    }

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
            if let onInlinePaste,
               ComposerPasteRoute.route(isImage: true, characterCount: 0, inlinePastes: inlinePastes) == .token {
                insertToken(for: .image(image.data, name: image.name), using: onInlinePaste)
                return
            }
            Task { _ = await onPasteData(image.data, image.name) }
            return
        case .attachPDF:
            guard let pdf = PastedContent.pdfData(from: pasteboard) else { break }
            Task { _ = await onPasteData(pdf, PastedContent.pdfName) }
            return
        case .insertText(let offerAsFile):
            if let onInlinePaste, let text = pasteboard.string(forType: .string),
               ComposerPasteRoute.route(isImage: false, characterCount: text.count, inlinePastes: inlinePastes) == .token {
                insertToken(for: .text(text), using: onInlinePaste)
                return
            }
            pasteText(sender, offerAsFile: offerAsFile)
            return
        }
        insertFromPasteboard(sender)
    }

    /// Hands the paste to the owner and puts the token it returns where the paste was made: over the selection
    /// then, when the field has not changed meanwhile, otherwise at the caret. nil → nothing is inserted.
    private func insertToken(for item: InlinePaste, using onInlinePaste: @escaping (InlinePaste) async -> String?) {
        let target = selectedRange()
        let before = string
        Task { @MainActor [weak self] in
            guard let label = await onInlinePaste(item), let self else { return }
            let range = self.string == before ? target : self.selectedRange()
            guard self.shouldChangeText(in: range, replacementString: label) else { return }
            self.textStorage?.replaceCharacters(in: range, with: label)
            self.didChangeText()
            self.undoManager?.setActionName("Paste")
            self.setSelectedRange(NSRange(location: range.location + (label as NSString).length, length: 0))
        }
    }

    /// One Backspace right after a live paste token removes the whole token (#2065 §6); anything else is the
    /// stock Backspace, a hand-typed bracket text included.
    override public func deleteBackward(_ sender: Any?) {
        let caret = selectedRange()
        if inlinePastes, caret.length == 0, !hasMarkedText(),
           let range = PasteTokens.deletionRange(backwardFrom: caret.location, in: string, kinds: livePastes),
           shouldChangeText(in: range, replacementString: "") {
            textStorage?.replaceCharacters(in: range, with: "")
            didChangeText()
            setSelectedRange(NSRange(location: range.location, length: 0))
            return
        }
        super.deleteBackward(sender)
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
