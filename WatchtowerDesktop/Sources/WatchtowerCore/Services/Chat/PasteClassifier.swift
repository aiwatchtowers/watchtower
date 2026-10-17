import Foundation

/// What a ⌘V in a composer that accepts attachments does (board #534). Pure:
/// it sees only the pasteboard's type identifiers, file URLs and plain
/// string, which the text view reads inside its own user-initiated
/// `paste(_:)` (No-TCC: the pasteboard is never read programmatically).
package enum PasteAction: Equatable, Sendable {
    /// Finder copy: attach through the same path as drag-and-drop.
    case attachFiles([URL])
    /// Screenshot or copied image: attach it as a PNG.
    case attachImage
    /// PDF data with no image beside it.
    case attachPDF
    /// The normal text insert, unchanged. `offerAsFile` → the text is long
    /// enough (and small enough to attach) that the composer offers to
    /// attach it as a file instead.
    case insertText(offerAsFile: Bool)
}

package enum PasteClassifier {
    /// A paste of this many characters or more gets the "Attach as file" offer.
    package static let longTextThreshold = 10_000
    /// Name of the attachment made from a long text paste.
    package static let pastedTextName = "Pasted text.txt"

    /// Pasteboard types that carry image data (UTIs as `NSPasteboard.PasteboardType` raw values).
    package static let imageTypes: Set<String> = [
        "public.png", "public.tiff", "public.jpeg", "public.heic", "com.compuserve.gif", "org.webmproject.webp"
    ]
    package static let pdfTypes: Set<String> = ["com.adobe.pdf"]

    /// Precedence: file URLs (a Finder copy also carries the file names as
    /// text and an icon image — both ignored) > text > image > PDF. Text wins
    /// over an image because a copy from a document, Slack or a spreadsheet
    /// often carries a rendered picture of the same selection; the exception
    /// is text that is only a link or blank — a browser's "Copy Image" puts
    /// the image's URL beside it, and the owner wants the image.
    package static func classify(types: [String], fileURLs: [URL], text: String?) -> PasteAction {
        if !fileURLs.isEmpty { return .attachFiles(fileURLs) }
        let hasImage = types.contains(where: imageTypes.contains)
        let hasPDF = types.contains(where: pdfTypes.contains)
        if let text, !isLinkOrBlank(text) || !(hasImage || hasPDF) {
            return .insertText(offerAsFile: offersFile(text))
        }
        // An image and a PDF together are one selection rendered twice
        // (Preview, Keynote); the image is the smaller, model-friendlier copy.
        if hasImage { return .attachImage }
        if hasPDF { return .attachPDF }
        return .insertText(offerAsFile: false)
    }

    /// The field after "Attach as file": the pasted text taken out (its last
    /// occurrence — the paste is usually the latest edit). nil when the
    /// field no longer holds it, so the offer is stale.
    package static func removingPasted(_ pasted: String, from text: String) -> String? {
        guard !pasted.isEmpty, let range = text.range(of: pasted, options: [.literal, .backwards]) else { return nil }
        var result = text
        result.removeSubrange(range)
        return result
    }

    /// Long, but still within the text attachment limit — an offer that
    /// could only fail is not made.
    private static func offersFile(_ text: String) -> Bool {
        text.count >= longTextThreshold && Int64(text.utf8.count) <= AttachmentValidator.textLimit
    }

    private static func isLinkOrBlank(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        guard !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https", "file", "data"].contains(scheme)
    }
}
