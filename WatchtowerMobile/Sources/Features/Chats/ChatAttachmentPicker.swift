import ChatWire
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

    /// Writes the prepared bytes to a folder of their own under `directory` (the hub's staging folder, removed with
    /// the link); `discard` deletes it once the upload is applied or the file leaves the draft.
    static func stage(_ prepared: Prepared, in directory: URL) throws -> ComposerAttachment {
        let id = UUID().uuidString
        let folder = directory.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(prepared.name)
        try prepared.data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return ComposerAttachment(id: id, name: prepared.name, mime: prepared.mime, size: Int64(prepared.data.count), file: file)
    }

    /// Deletes a staged file's plaintext (its own folder).
    static func discard(_ file: URL) {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    /// Where a hub's chat files wait in plaintext before their upload.
    static func stagingDirectory(hubID: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("chat-attachments", isDirectory: true)
            .appendingPathComponent(hubID, isDirectory: true)
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
