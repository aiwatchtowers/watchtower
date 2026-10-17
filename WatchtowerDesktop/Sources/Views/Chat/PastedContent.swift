import AppKit
import WatchtowerCore

/// Reads the pasteboard for a ⌘V in a composer that accepts attachments
/// (board #534). Called ONLY from the text view's `paste(_:)` — a
/// user-initiated paste — never polled (No-TCC convention: programmatic
/// pasteboard reads can prompt). The decision itself is `PasteClassifier`.
enum PastedContent {
    static let imageName = "Pasted image.png"
    static let pdfName = "Pasted document.pdf"

    static func action(from pasteboard: NSPasteboard) -> PasteAction {
        let types = pasteboard.types?.map(\.rawValue) ?? []
        let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                          options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return PasteClassifier.classify(types: types, fileURLs: urls, text: pasteboard.string(forType: .string))
    }

    /// Image types the validator accepts byte-for-byte, with their stored
    /// extension, in the order they are tried.
    private static let nativeTypes: [(NSPasteboard.PasteboardType, String)] = [
        (.png, "png"),
        (NSPasteboard.PasteboardType("public.jpeg"), "jpg"),
        (NSPasteboard.PasteboardType("com.compuserve.gif"), "gif"),
        (NSPasteboard.PasteboardType("org.webmproject.webp"), "webp")
    ]

    /// The pasteboard's image as an attachment: PNG/JPEG/GIF/WebP bytes the
    /// validator accepts and that fit the limit go as is; anything else
    /// (TIFF from a screenshot, HEIC, BMP, an oversized image) becomes a PNG,
    /// downscaled when over the limit. nil when no image can be read.
    static func imageAttachment(from pasteboard: NSPasteboard,
                                limit: Int = Int(AttachmentValidator.imageLimit)) -> (data: Data, name: String)? {
        for (type, ext) in nativeTypes {
            guard let data = pasteboard.data(forType: type), data.count <= limit else { continue }
            let name = "Pasted image.\(ext)"
            if case .success(.image) = AttachmentValidator.validate(data: data, fileName: name) { return (data, name) }
        }
        guard let png = pngData(from: pasteboard) else { return nil }
        return (downscaled(png, toFit: limit), imageName)
    }

    private static func pngData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }
        guard let image = NSImage(pasteboard: pasteboard),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    static func pdfData(from pasteboard: NSPasteboard) -> Data? {
        pasteboard.data(forType: .pdf)
    }

    /// A screenshot of a large Retina screen can be over the 5 MB image
    /// limit as PNG: shrink it (a few passes, each sized from the overshoot)
    /// rather than refuse it. Still over after that → returned as is, and
    /// the validator refuses it with the size message.
    static func downscaled(_ png: Data, toFit limit: Int) -> Data {
        var data = png
        for _ in 0..<4 where data.count > limit {
            guard let rep = NSBitmapImageRep(data: data) else { break }
            let scale = (Double(limit) / Double(data.count)).squareRoot() * 0.9
            let width = max(1, Int(Double(rep.pixelsWide) * scale))
            let height = max(1, Int(Double(rep.pixelsHigh) * scale))
            guard let out = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0
            ) else { break }
            NSGraphicsContext.saveGraphicsState()
            let context = NSGraphicsContext(bitmapImageRep: out)
            context?.imageInterpolation = .high
            NSGraphicsContext.current = context
            rep.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
            NSGraphicsContext.restoreGraphicsState()
            guard let next = out.representation(using: .png, properties: [:]) else { break }
            data = next
        }
        return data
    }
}
