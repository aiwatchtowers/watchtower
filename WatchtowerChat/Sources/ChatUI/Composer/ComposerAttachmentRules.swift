import Foundation

/// What a provider's capabilities (U1) let the composer attach: a provider with no binary attachments takes text
/// files only, an images-only one refuses PDFs. A refused drop, paste or pick is not added and the reason shows.
public enum ComposerAttachmentRules {
    public enum BinaryKind: Equatable, Sendable { case image, pdf }

    /// An image or a PDF, by the file's type; nil for anything else.
    public static func kind(_ url: URL) -> BinaryKind? {
        ComposerPlatform.binaryKind(ofExtension: url.pathExtension)
    }

    /// An image or a PDF, by the file's type.
    public static func isBinary(_ url: URL) -> Bool { kind(url) != nil }

    /// Pasted bytes as an image or a PDF: by the name's type, the PDF signature, or the platform's image decoder.
    static func kind(of data: Data, name: String, isImage: (Data) -> Bool) -> BinaryKind? {
        let byName = kind(URL(fileURLWithPath: name))
        if byName == .pdf || data.starts(with: [0x25, 0x50, 0x44, 0x46]) { return .pdf }
        if byName == .image || isImage(data) { return .image }
        return nil
    }

    /// Why an attachment of `kind` is refused: a provider with no binary attachments refuses both kinds (U1), an
    /// images-only one refuses PDFs; nil when it is taken.
    public static func refusal(of kind: BinaryKind?, attach: String?, pdf: String?) -> String? {
        switch kind {
        case .image: attach
        case .pdf: attach ?? pdf
        case nil: nil
        }
    }

    /// The paperclip's help: what the picker takes, and why not more.
    public static func attachHelp(attach: String?, pdf: String?) -> String {
        if let attach { return "Attach text files. " + attach }
        if let pdf { return "Attach images or text files. " + pdf }
        return "Attach images, PDFs or text files"
    }

    /// A chip's icon by the file's type.
    public static func icon(forMime mime: String) -> String {
        if mime.hasPrefix("image/") { return "photo" }
        if mime == "application/pdf" { return "doc.richtext" }
        return "doc.text"
    }
}
