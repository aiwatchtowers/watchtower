import AppKit

enum PastedImage {
    /// PNG bytes for an image-only pasteboard; nil when it carries text (text
    /// wins — a rich copy often has both) or no image. Called ONLY from the
    /// text view's `paste(_:)` — a user-initiated paste — never polled
    /// (No-TCC convention: programmatic pasteboard reads can prompt).
    static func pngData(from pasteboard: NSPasteboard) -> Data? {
        if pasteboard.string(forType: .string) != nil { return nil }
        guard pasteboard.canReadObject(forClasses: [NSImage.self], options: nil),
              let image = NSImage(pasteboard: pasteboard),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
