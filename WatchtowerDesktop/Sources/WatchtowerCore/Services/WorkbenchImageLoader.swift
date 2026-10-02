import Foundation
import ImageIO

/// What decoding a stored target image gave: the image, no file at all, or
/// a file that is there but cannot be shown — three states, so the viewer
/// never calls an undecodable file "missing".
package enum WorkbenchImageLoad: Sendable {
    case image(CGImage)
    case missing
    case undecodable

    package var image: CGImage? {
        if case .image(let image) = self { return image }
        return nil
    }
}

/// Decodes a board target's stored image (board target #117) for the
/// Desktop: a downscaled thumbnail for the detail pane, a bounded-size image
/// for the viewer. Pure ImageIO, no AppKit, so it runs off the main actor.
package enum WorkbenchImageLoader {
    /// The viewer's cap on the longer side: a 5 MB PNG that compresses well
    /// can be tens of thousands of pixels wide, and decoding that in full
    /// would take gigabytes.
    package static let viewerMaxPixel = 4096

    /// The image scaled so its longer side is at most `maxPixel` (never
    /// enlarged).
    package static func load(at url: URL, maxPixel: Int) -> WorkbenchImageLoad {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return .undecodable }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return .undecodable
        }
        return .image(image)
    }
}
