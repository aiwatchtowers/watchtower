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

    /// PNG bytes of the pasteboard's image: PNG data as is, any other image
    /// type (TIFF from a screenshot, JPEG, HEIC) converted; downscaled when
    /// over the image limit. nil when no image can be read.
    static func pngData(from pasteboard: NSPasteboard,
                        limit: Int = Int(AttachmentValidator.imageLimit)) -> Data? {
        let png: Data
        if let data = pasteboard.data(forType: .png) {
            png = data
        } else {
            guard let image = NSImage(pasteboard: pasteboard),
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let converted = rep.representation(using: .png, properties: [:]) else { return nil }
            png = converted
        }
        return downscaled(png, toFit: limit)
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
