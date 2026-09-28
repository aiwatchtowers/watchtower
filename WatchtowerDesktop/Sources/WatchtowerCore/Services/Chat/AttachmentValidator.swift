import Foundation

package enum AttachmentKind: Equatable, Sendable {
    case image(mime: String)
    case pdf
    case text(mime: String)

    package var mime: String {
        switch self {
        case .image(let mime), .text(let mime): return mime
        case .pdf: return "application/pdf"
        }
    }

    /// Extension for the stored copy: canonical for binaries, the original
    /// (lowercased) for text so a `.go` stays recognisable.
    package func fileExtension(fallbackName: String) -> String {
        switch self {
        case .image(let mime):
            switch mime {
            case "image/jpeg": return "jpg"
            case "image/gif": return "gif"
            case "image/webp": return "webp"
            default: return "png"
            }
        case .pdf:
            return "pdf"
        case .text:
            let ext = (fallbackName as NSString).pathExtension.lowercased()
            return ext.isEmpty ? "txt" : ext
        }
    }
}

package enum AttachmentRejection: Error, Equatable, Sendable {
    case unsupportedType(fileName: String)
    case tooLarge(fileName: String, limit: Int64)
    case notUTF8(fileName: String)
    case unreadable(fileName: String)

    package var message: String {
        switch self {
        case .unsupportedType(let name):
            return "\(name): only images, PDFs and text files can be attached"
        case let .tooLarge(name, limit):
            return "\(name) is larger than \(ByteCountFormatter.string(fromByteCount: limit, countStyle: .file))"
        case .notUTF8(let name):
            return "\(name) is not a UTF-8 text file"
        case .unreadable(let name):
            return "\(name) could not be read"
        }
    }
}

/// Composer-side twin of Go `internal/chat` attachment rules
/// (`internal/chat/attachments.go`): binaries are detected from magic bytes
/// (the signatures Go's `http.DetectContentType` uses), text by extension +
/// UTF-8. Limits mirror Go `Max*Bytes`. Every text mime this validator
/// produces must satisfy Go's `isTextMime` (a `text/*` prefix, or one of a
/// small whitelist) — pinned by `AttachmentValidatorTests.testTextMimesAllPassGoIsTextMime`.
package enum AttachmentValidator {
    package static let imageLimit: Int64 = 5 * 1024 * 1024
    package static let pdfLimit: Int64 = 32 * 1024 * 1024
    package static let textLimit: Int64 = 256 * 1024

    package static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "csv", "tsv", "json", "yaml", "yml", "log", "xml", "toml", "ini",
        "go", "swift", "py", "js", "ts", "tsx", "jsx", "java", "kt", "rb", "rs", "c", "h", "cpp",
        "hpp", "m", "cs", "php", "sh", "zsh", "bash", "sql", "html", "css", "scss"
    ]

    package static func validate(url: URL) -> Result<AttachmentKind, AttachmentRejection> {
        let name = url.lastPathComponent
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize,
              let handle = try? FileHandle(forReadingFrom: url) else {
            return .failure(.unreadable(fileName: name))
        }
        let head = (try? handle.read(upToCount: 16)) ?? Data()
        try? handle.close()
        guard let classified = classify(head: head, fileName: name) else {
            return .failure(.unsupportedType(fileName: name))
        }
        let (kind, limit) = classified
        guard Int64(size) <= limit else { return .failure(.tooLarge(fileName: name, limit: limit)) }
        if case .text = kind {
            guard let data = try? Data(contentsOf: url) else { return .failure(.unreadable(fileName: name)) }
            guard String(data: data, encoding: .utf8) != nil else { return .failure(.notUTF8(fileName: name)) }
        }
        return .success(kind)
    }

    package static func validate(data: Data, fileName: String) -> Result<AttachmentKind, AttachmentRejection> {
        guard let classified = classify(head: data.prefix(16), fileName: fileName) else {
            return .failure(.unsupportedType(fileName: fileName))
        }
        let (kind, limit) = classified
        guard Int64(data.count) <= limit else { return .failure(.tooLarge(fileName: fileName, limit: limit)) }
        if case .text = kind, String(data: data, encoding: .utf8) == nil {
            return .failure(.notUTF8(fileName: fileName))
        }
        return .success(kind)
    }

    /// Signatures match Go's `net/http` sniffer (`sniffSignatures` in
    /// `net/http/sniff.go`) byte-for-byte — the exact set `http.DetectContentType`
    /// consults in `internal/chat/attachments.go`'s `classifyAttachment`. A file
    /// that satisfies only a shorter/looser prefix must be rejected here too,
    /// or the composer would accept it and Go would reject it at send time
    /// with a confusing `attachment_unsupported` (pinned by
    /// `AttachmentValidatorTests.testShortMagicPrefixesAreRejected`).
    static func classify(head: Data, fileName: String) -> (AttachmentKind, Int64)? {
        let bytes = [UInt8](head)
        func starts(_ signature: [UInt8]) -> Bool {
            bytes.count >= signature.count && Array(bytes.prefix(signature.count)) == signature
        }
        // PNG: full 8-byte signature (89 50 4E 47 0D 0A 1A 0A) — Go's exactSig, not just the 4-byte "\x89PNG" prefix.
        if starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return (.image(mime: "image/png"), imageLimit) }
        // JPEG: exact 3-byte signature — same length Go checks.
        if starts([0xFF, 0xD8, 0xFF]) { return (.image(mime: "image/jpeg"), imageLimit) }
        // GIF: exact "GIF87a"/"GIF89a" (6 bytes) — Go's two exactSigs, not the 4-byte "GIF8" prefix.
        if starts(Array("GIF87a".utf8)) || starts(Array("GIF89a".utf8)) {
            return (.image(mime: "image/gif"), imageLimit)
        }
        // WEBP: Go's maskedSig requires "RIFF" (0-3, size at 4-7 masked out) followed by "WEBPVP"
        // (8-13, the RIFF chunk id + the VP8 sub-chunk fourCC's first two bytes) — not just "WEBP".
        if starts(Array("RIFF".utf8)), bytes.count >= 14, Array(bytes[8..<14]) == Array("WEBPVP".utf8) {
            return (.image(mime: "image/webp"), imageLimit)
        }
        // PDF: exact "%PDF-" signature — same length Go checks.
        if starts(Array("%PDF-".utf8)) { return (.pdf, pdfLimit) }
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard textExtensions.contains(ext) else { return nil }
        return (.text(mime: textMime(ext)), textLimit)
    }

    /// Every value here is accepted by Go `isTextMime`: a `text/*` prefix, or
    /// one of `application/json`, `application/yaml`, `application/xml`,
    /// `application/toml` (Go's declared-mime whitelist for non-`text/*`).
    static func textMime(_ ext: String) -> String {
        switch ext {
        case "md", "markdown": return "text/markdown"
        case "csv": return "text/csv"
        case "tsv": return "text/tab-separated-values"
        case "json": return "application/json"
        case "yaml", "yml": return "application/yaml"
        case "xml": return "application/xml"
        case "toml": return "application/toml"
        case "html": return "text/html"
        default: return "text/plain"
        }
    }
}
