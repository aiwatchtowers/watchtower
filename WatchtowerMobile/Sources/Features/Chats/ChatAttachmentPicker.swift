import Foundation
import ImageIO
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A file waiting in the composer (mockup 2b's pills): what it is, where its prepared bytes are, and how far its
/// upload got. The id is the upload id; a Retry after a refused upload takes a fresh one (`retried`).
struct ComposerAttachment: Identifiable, Equatable {
    enum State: Equatable {
        case ready
        case uploading
        case uploaded(Int64)
        case failed(String)
    }

    var id: String
    let name: String
    let mime: String
    let size: Int64
    let file: URL
    var state: State = .ready

    var isImage: Bool { mime.hasPrefix("image/") }

    /// The same file under a fresh upload id (a refused upload is a finished record on the hub).
    func retried() -> Self {
        var copy = self
        copy.id = UUID().uuidString
        copy.state = .ready
        return copy
    }
}

/// What the phone may attach, the Mac's rules exactly (`AttachmentValidator`, Go `internal/chatstore`), pinned by
/// the shared `attachment_limit_cases.json`: images png/jpeg/gif/webp ≤ 5 MB by their magic bytes, PDF ≤ 32 MB,
/// text by extension ≤ 256 KB and UTF-8; one message carries at most 30 MB encoded (images and PDFs base64).
enum ChatAttachmentLimits {
    enum Kind: Equatable {
        case image(mime: String)
        case pdf
        case text(mime: String)

        var mime: String {
            switch self {
            case let .image(mime), let .text(mime): mime
            case .pdf: "application/pdf"
            }
        }

        /// The canonical extension for a binary, the lowercased original for text.
        func fileExtension(fallbackName: String) -> String {
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

    enum Rejection: Error, Equatable {
        case unsupportedType(String)
        case tooLarge(String, limit: Int64)
        case notUTF8(String)
        case overMessage

        var reason: String {
            switch self {
            case .unsupportedType: "unsupported_type"
            case .tooLarge: "too_large"
            case .notUTF8: "not_utf8"
            case .overMessage: "over_message"
            }
        }

        var message: String {
            switch self {
            case let .unsupportedType(name): "\(name): only images, PDFs and text files can be attached"
            case let .tooLarge(name, limit): "\(name) is larger than \(ByteCountFormatter.string(fromByteCount: limit, countStyle: .file))"
            case let .notUTF8(name): "\(name) is not a UTF-8 text file"
            case .overMessage: "One message carries at most 30 MB of files."
            }
        }
    }

    static let imageLimit: Int64 = 5 * 1_024 * 1_024
    static let pdfLimit: Int64 = 32 * 1_024 * 1_024
    static let textLimit: Int64 = 256 * 1_024
    /// Go's `MaxTurnAttachmentEncodedBytes`.
    static let messageLimit: Int64 = 30 << 20

    static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "csv", "tsv", "json", "yaml", "yml", "log", "xml", "toml", "ini",
        "go", "swift", "py", "js", "ts", "tsx", "jsx", "java", "kt", "rb", "rs", "c", "h", "cpp",
        "hpp", "m", "cs", "php", "sh", "zsh", "bash", "sql", "html", "css", "scss"
    ]

    static func validate(data: Data, fileName: String) -> Result<Kind, Rejection> {
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
    static func encodedSize(mime: String, size: Int64) -> Int64 {
        guard mime.hasPrefix("image/") || mime == "application/pdf" else { return size }
        return (size + 2) / 3 * 4
    }

    static func fitsMessage(_ attachments: [(mime: String, size: Int64)]) -> Bool {
        attachments.reduce(Int64(0)) { $0 + encodedSize(mime: $1.mime, size: $1.size) } <= messageLimit
    }

    /// Go's sniffer signatures, byte for byte (the Mac's `AttachmentValidator.classify`).
    static func classify(head: Data, fileName: String) -> (Kind, Int64)? {
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

    static func textMime(_ ext: String) -> String {
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

/// Turns what the owner picked into an upload the hub takes, as `PastedContent` does on the Mac: a HEIC/HEIF photo
/// becomes a JPEG, an image over 5 MB is downsized until it fits, then the shared limits decide.
enum ChatAttachmentPrep {
    struct Prepared: Equatable {
        let data: Data
        let name: String
        let mime: String
    }

    static let jpegQuality = 0.85

    static func prepare(data: Data, fileName: String) -> Result<Prepared, ChatAttachmentLimits.Rejection> {
        var data = data
        var name = fileName
        if isHEIF(data), let jpeg = jpeg(from: data, maxPixel: nil) {
            data = jpeg
            name = renamed(name, ext: "jpg")
        }
        if isImage(data), Int64(data.count) > ChatAttachmentLimits.imageLimit {
            data = downsized(data, toFit: Int(ChatAttachmentLimits.imageLimit))
            name = renamed(name, ext: "jpg")
        }
        return ChatAttachmentLimits.validate(data: data, fileName: name).map { kind in
            Prepared(data: data, name: renamed(name, ext: kind.fileExtension(fallbackName: name)), mime: kind.mime)
        }
    }

    static func isHEIF(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(source) as String?,
              let utType = UTType(type) else { return false }
        return utType.conforms(to: .heic) || utType.conforms(to: .heif)
    }

    private static func isImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(source) as String? else {
            return false
        }
        return UTType(type)?.conforms(to: .image) ?? false
    }

    /// A JPEG of the image, its longer side at most `maxPixel` (nil keeps the size), the orientation applied.
    static func jpeg(from data: Data, maxPixel: Int?) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let image: CGImage?
        if let maxPixel {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel
            ]
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        } else {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixelSize(source)
            ]
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        guard let image else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }

    /// Shrinks an image (a few passes, each sized from the overshoot) until its JPEG fits `limit`.
    static func downsized(_ data: Data, toFit limit: Int) -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return data }
        var side = Double(pixelSize(source))
        var current = data
        for _ in 0..<5 where current.count > limit {
            side *= (Double(limit) / Double(current.count)).squareRoot() * 0.9
            guard let smaller = jpeg(from: data, maxPixel: max(Int(side), 64)) else { break }
            current = smaller
        }
        return current
    }

    private static func pixelSize(_ source: CGImageSource) -> Int {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        return max(width, height, 1)
    }

    static func renamed(_ name: String, ext: String) -> String {
        let base = (name as NSString).deletingPathExtension
        let current = (name as NSString).pathExtension.lowercased()
        guard current != ext else { return name }
        return (base.isEmpty ? "file" : base) + "." + ext
    }

    /// Writes the prepared bytes to a file of their own under the temporary folder (deleted with the app's temp).
    static func stage(_ prepared: Prepared) throws -> ComposerAttachment {
        let id = UUID().uuidString
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("chat-attachments", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(prepared.name)
        try prepared.data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return ComposerAttachment(id: id, name: prepared.name, mime: prepared.mime, size: Int64(prepared.data.count), file: file)
    }
}

/// The + menu (mockup 3a): Take photo, Photo library, Files. Dictation is the keyboard's own mic (no app code).
struct ChatAttachmentMenu: View {
    static let title = "Attach"
    static let camera = "Take photo"
    static let library = "Photo library"
    static let files = "Files"
    static let filesNote = "PDF, text, code — up to 30 MB per message"

    let pick: (Source) -> Void

    enum Source: Equatable {
        case camera, library, files
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            option(Self.camera, symbol: "camera", source: .camera)
                .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
            Divider()
            option(Self.library, symbol: "photo.on.rectangle", source: .library)
            Divider()
            option(Self.files, symbol: "doc", note: Self.filesNote, source: .files)
        }
        .padding(.horizontal, Spacing.large)
        .padding(.top, Spacing.large)
        .presentationDetents([.height(PhoneMetrics.attachMenuHeight)])
        .presentationDragIndicator(.visible)
    }

    private func option(_ title: String, symbol: String, note: String? = nil, source: Source) -> some View {
        Button { pick(source) } label: {
            HStack(spacing: Spacing.regular) {
                Image(systemName: symbol).frame(width: PhoneMetrics.iconColumn).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    Text(title).font(TypeScale.rowTitle)
                    if let note { Text(note).font(TypeScale.meta).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: PhoneMetrics.minTouch)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The file types the Files picker offers: what the limits can take.
    static let fileTypes: [UTType] = [.image, .pdf, .plainText, .text, .sourceCode, .json, .xml, .commaSeparatedText, .html, .data]
}

/// The camera, through UIKit's picker: one photo as JPEG.
struct ChatCameraPicker: UIViewControllerRepresentable {
    let done: (Data?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let done: (Data?) -> Void

        init(done: @escaping (Data?) -> Void) {
            self.done = done
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = info[.originalImage] as? UIImage
            done(image?.jpegData(compressionQuality: ChatAttachmentPrep.jpegQuality))
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            done(nil)
        }
    }
}
