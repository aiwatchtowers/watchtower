import Foundation
import WatchtowerChatText

/// A long text paste the composer offers to attach as a file: the exact
/// inserted text and range, checked and removed through the text view.
public struct LongPaste {
    public let text: String
    /// The field still holds the pasted text at the pasted range.
    public let isIntact: () -> Bool
    public let remove: () -> Void

    /// "Attach as File": attached only while the paste is intact, and taken
    /// out of the field only once attached (the chat's landing may first
    /// write its conversation) — a refusal keeps it and the composer shows
    /// the reason; a field edited meanwhile keeps its text too.
    public func attach(using onPasteData: (Data, String) async -> Bool) async {
        guard isIntact() else { return }
        if await onPasteData(Data(text.utf8), PasteClassifier.pastedTextName), isIntact() { remove() }
    }
}
