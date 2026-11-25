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
    /// Set on every SwiftUI update: only turning inline pastes on or off restyles.
    var onInlinePaste: ((InlinePaste) async -> String?)? {
        didSet { if (onInlinePaste == nil) != (oldValue == nil) { restyleTokens() } }
    }
    /// A token `onInlinePaste` returned that never went in (the field refused the edit or was gone by then): the
    /// owner lets go of its payload, which would otherwise wait for the token forever.
    var onInlinePasteDropped: ((String) -> Void)?
    /// The kind of each token number with a payload (the owner's model): only a token of that number and kind is
    /// deleted whole.
    var livePastes: [Int: PasteKind] = [:] {
        didSet { if livePastes != oldValue { restyleTokens() } }
    }
    /// A live token's tone: the info chip's blue (`Tone.artifact(.info)`), not the accent, which is grey for an
    /// owner on the Graphite accent and would leave the token as grey-on-grey as plain text.
    static let tokenTone = NSColor.systemBlue
    /// The live tokens' ranges as last drawn: each one a pill (`restyleTokens`).
    private(set) var tokenRanges: [NSRange] = []
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

    /// What a ⌘V here takes beyond the plain-text view's own types (#2201 §4): images, Finder files and PDF data.
    /// AppKit enables Edit ▸ Paste — hence ⌘V — only for a pasteboard holding a readable type, and a plain-text
    /// view lists no image: without these a screenshot never reached `paste(_:)`.
    static let attachableTypes: [NSPasteboard.PasteboardType] = [
        .png, .tiff, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic"),
        .fileURL, .pdf
    ]

    override public var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        let stock = super.readablePasteboardTypes
        guard onPasteData != nil else { return stock }
        return stock + Self.attachableTypes.filter { !stock.contains($0) }
    }

    /// Paste is enabled for an editable field whose `pasteboard` holds a readable type — the stock rule, read
    /// from the field's own pasteboard (a test's private one) — or, when it takes attachments, any image type
    /// `PasteClassifier.isImageType` accepts (GIF, WebP, BMP… beyond `attachableTypes`). Types only: the content
    /// is read by `paste(_:)`.
    override public func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        guard item.action == #selector(paste(_:)), onPasteData != nil || pasteboard !== NSPasteboard.general else {
            return super.validateUserInterfaceItem(item)
        }
        guard isEditable else { return false }
        if pasteboard.availableType(from: readablePasteboardTypes) != nil { return true }
        return onPasteData != nil && (pasteboard.types ?? []).contains { PasteClassifier.isImageType($0.rawValue) }
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
    /// then, when the field has not changed meanwhile, otherwise at the caret. nil → nothing is inserted. A token
    /// that cannot go in (the edit refused, the field gone) is reported through `onInlinePasteDropped`.
    private func insertToken(for item: InlinePaste, using onInlinePaste: @escaping (InlinePaste) async -> String?) {
        let target = selectedRange()
        let before = string
        let dropped = onInlinePasteDropped
        Task { @MainActor [weak self] in
            guard let label = await onInlinePaste(item) else { return }
            guard let self else {
                dropped?(label)
                return
            }
            let range = self.string == before ? target : self.selectedRange()
            guard self.shouldChangeText(in: range, replacementString: label) else {
                dropped?(label)
                return
            }
            self.textStorage?.replaceCharacters(in: range, with: label)
            self.didChangeText()
            self.undoManager?.setActionName("Paste")
            self.setSelectedRange(NSRange(location: range.location + (label as NSString).length, length: 0))
        }
    }

    // MARK: - Token pills

    /// A programmatic set (the binding, a picker edit) restyles too; typing, paste and undo come through `didChangeText`.
    override public var string: String {
        didSet { restyleTokens(textChanged: true) }
    }

    override public func didChangeText() {
        super.didChangeText()
        restyleTokens(textChanged: true)
    }

    /// Draws each live token (`PasteTokens.liveRanges`) as a pill: a `tokenTone` foreground as a layout manager's
    /// temporary attribute and a tinted rounded fill in `draw(_:)`. Display only: the text storage, hence the
    /// draft string, the binding and the undo stack, never carries either. Nothing is redone when the ranges are
    /// the ones drawn, unless the text changed around a pill (a character typed next to it must not take its tone).
    func restyleTokens(textChanged: Bool = false) {
        let ranges = inlinePastes ? PasteTokens.liveRanges(in: string, kinds: livePastes) : []
        guard ranges != tokenRanges || (textChanged && !ranges.isEmpty) else { return }
        guard let layoutManager else { return }
        tokenRanges = ranges
        let whole = NSRange(location: 0, length: (string as NSString).length)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: whole)
        for range in ranges where NSMaxRange(range) <= whole.length {
            layoutManager.addTemporaryAttribute(.foregroundColor, value: Self.tokenTone, forCharacterRange: range)
        }
        needsDisplay = true
    }

    /// The pills' rects in the view's coordinates: one per line a token spans.
    func tokenPillRects() -> [NSRect] {
        guard let layoutManager, let textContainer, !tokenRanges.isEmpty else { return [] }
        let origin = textContainerOrigin
        let length = (string as NSString).length
        var rects: [NSRect] = []
        for range in tokenRanges where NSMaxRange(range) <= length {
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layoutManager.enumerateEnclosingRects(
                forGlyphRange: glyphs,
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                in: textContainer
            ) { rect, _ in
                rects.append(rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -Spacing.tight / 2, dy: 0))
            }
        }
        return rects
    }

    override public func draw(_ dirtyRect: NSRect) {
        let rects = tokenPillRects().filter { $0.intersects(dirtyRect) }
        if !rects.isEmpty {
            let fill = Self.tokenTone.withAlphaComponent(ChipTint.fillOpacity)
            let stroke = Self.tokenTone.withAlphaComponent(ChipTint.strokeOpacity)
            for rect in rects {
                let inset = ChipTint.strokeWidth / 2
                let path = NSBezierPath(roundedRect: rect.insetBy(dx: inset, dy: inset), xRadius: Radius.mark, yRadius: Radius.mark)
                fill.setFill()
                path.fill()
                stroke.setStroke()
                path.lineWidth = ChipTint.strokeWidth
                path.stroke()
            }
        }
        super.draw(dirtyRect)
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
