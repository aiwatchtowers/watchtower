import Foundation

/// What a chat client may attach, the Mac's rules exactly (`AttachmentValidator`, Go `internal/chatstore`), pinned by
/// the shared `attachment_limit_cases.json`: images png/jpeg/gif/webp ≤ 5 MB by their magic bytes, PDF ≤ 32 MB, text
/// by extension ≤ 256 KB and UTF-8; one message carries at most 30 MB encoded (images and PDFs base64). The client
/// only pre-checks for a fast error; the engine decides.
public enum ChatAttachmentLimits {
    public enum Kind: Equatable, Sendable {
        case image(mime: String)
        case pdf
        case text(mime: String)

        public var mime: String {
            switch self {
            case let .image(mime), let .text(mime): mime
            case .pdf: "application/pdf"
            }
        }

        /// The canonical extension for a binary, the lowercased original for text.
        public func fileExtension(fallbackName: String) -> String {
            switch self {
            case let .image(mime):
                switch mime {
                case "image/jpeg": "jpg"
                case "image/gif": "gif"
                case "image/webp": "webp"
                default: "png"
                }
            case .pdf:
                "pdf"
            case .text:
                (fallbackName as NSString).pathExtension.lowercased().isEmpty ? "txt" : (fallbackName as NSString).pathExtension.lowercased()
            }
        }
    }

    public enum Rejection: Error, Equatable, Sendable {
        case unsupportedType(String)
        case tooLarge(String, limit: Int64)
        case notUTF8(String)
        case overMessage

        public var reason: String {
            switch self {
            case .unsupportedType: "unsupported_type"
            case .tooLarge: "too_large"
            case .notUTF8: "not_utf8"
            case .overMessage: "over_message"
            }
        }

        public var message: String {
            switch self {
            case let .unsupportedType(name): "\(name): only images, PDFs and text files can be attached"
            case let .tooLarge(name, limit): "\(name) is larger than \(ByteCountFormatter.string(fromByteCount: limit, countStyle: .file))"
            case let .notUTF8(name): "\(name) is not a UTF-8 text file"
            case .overMessage: "One message carries at most 30 MB of files."
            }
        }
    }

    public static let imageLimit: Int64 = 5 * 1_024 * 1_024
    public static let pdfLimit: Int64 = 32 * 1_024 * 1_024
    public static let textLimit: Int64 = 256 * 1_024
    /// Go's `MaxTurnAttachmentEncodedBytes`.
    public static let messageLimit: Int64 = 30 << 20

    public static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "csv", "tsv", "json", "yaml", "yml", "log", "xml", "toml", "ini",
        "go", "swift", "py", "js", "ts", "tsx", "jsx", "java", "kt", "rb", "rs", "c", "h", "cpp",
        "hpp", "m", "cs", "php", "sh", "zsh", "bash", "sql", "html", "css", "scss"
    ]

    public static func validate(data: Data, fileName: String) -> Result<Kind, Rejection> {
        guard let (kind, limit) = classify(head: data.prefix(16), fileName: fileName) else {
            return .failure(.unsupportedType(fileName))
        }
        guard Int64(data.count) <= limit else { return .failure(.tooLarge(fileName, limit: limit)) }
        if case .text = kind, String(data: data, encoding: .utf8) == nil {
            return .failure(.notUTF8(fileName))
        }
        return .success(kind)
    }

    /// The bytes a file adds to the message: base64 for images and PDFs, the text as is.
    public static func encodedSize(mime: String, size: Int64) -> Int64 {
        guard mime.hasPrefix("image/") || mime == "application/pdf" else { return size }
        return (size + 2) / 3 * 4
    }

    public static func fitsMessage(_ attachments: [(mime: String, size: Int64)]) -> Bool {
        attachments.reduce(Int64(0)) { $0 + encodedSize(mime: $1.mime, size: $1.size) } <= messageLimit
    }

    /// Go's sniffer signatures, byte for byte (the Mac's `AttachmentValidator.classify`).
    public static func classify(head: Data, fileName: String) -> (Kind, Int64)? {
        let bytes = [UInt8](head)
        func starts(_ signature: [UInt8]) -> Bool {
            bytes.count >= signature.count && Array(bytes.prefix(signature.count)) == signature
        }
        if starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return (.image(mime: "image/png"), imageLimit) }
        if starts([0xFF, 0xD8, 0xFF]) { return (.image(mime: "image/jpeg"), imageLimit) }
        if starts(Array("GIF87a".utf8)) || starts(Array("GIF89a".utf8)) { return (.image(mime: "image/gif"), imageLimit) }
        if starts(Array("RIFF".utf8)), bytes.count >= 14, Array(bytes[8..<14]) == Array("WEBPVP".utf8) {
            return (.image(mime: "image/webp"), imageLimit)
        }
        if starts(Array("%PDF-".utf8)) { return (.pdf, pdfLimit) }
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard textExtensions.contains(ext) else { return nil }
        return (.text(mime: textMime(ext)), textLimit)
    }

    public static func textMime(_ ext: String) -> String {
        switch ext {
        case "md", "markdown": "text/markdown"
        case "csv": "text/csv"
        case "tsv": "text/tab-separated-values"
        case "json": "application/json"
        case "yaml", "yml": "application/yaml"
        case "xml": "application/xml"
        case "toml": "application/toml"
        case "html": "text/html"
        default: "text/plain"
        }
    }
}
