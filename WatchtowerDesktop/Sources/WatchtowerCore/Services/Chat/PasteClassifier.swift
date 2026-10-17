import Foundation
import UniformTypeIdentifiers

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

    package static let pdfType = "com.adobe.pdf"

    /// Any type conforming to `public.image` (PNG, TIFF, JPEG, HEIC, GIF,
    /// WebP, BMP, JPEG 2000…) — what `NSImage(pasteboard:)` can read. PDF is
    /// not an image type, so it never counts here.
    package static func isImageType(_ identifier: String) -> Bool {
        UTType(identifier)?.conforms(to: .image) == true
    }

    /// Precedence: file URLs (a Finder copy also carries the file names as
    /// text and an icon image — both ignored) > text > image > PDF. Text wins
    /// over an image because a copy from a document, Slack or a spreadsheet
    /// often carries a rendered picture of the same selection; the exception
    /// is text that is only a link or blank beside an image — a browser's
    /// "Copy Image" puts the image's URL beside it, and the owner wants the
    /// image. That exception never yields to PDF: a link copied from Preview
    /// or Pages pastes as the link.
    package static func classify(types: [String], fileURLs: [URL], text: String?) -> PasteAction {
        if !fileURLs.isEmpty { return .attachFiles(fileURLs) }
        let hasImage = types.contains(where: isImageType)
        let hasPDF = types.contains(pdfType)
        if let text, !(hasImage && isLinkOrBlank(text)) {
            return .insertText(offerAsFile: offersFile(text))
        }
        // An image and a PDF together are one selection rendered twice
        // (Preview, Keynote); the image is the smaller, model-friendlier copy.
        if hasImage { return .attachImage }
        if hasPDF { return .attachPDF }
        return .insertText(offerAsFile: false)
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
