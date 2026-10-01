import Foundation
import ImageIO

/// Decodes a board target's stored image (board target #117) for the
/// Desktop: a downscaled thumbnail for the detail pane, the full image for
/// the viewer. Pure ImageIO, no AppKit, so it runs off the main actor.
package enum ProjectImageLoader {
    /// A thumbnail whose longer side is at most `maxPixel`, or nil when the
    /// file is missing or not a decodable image.
    package static func thumbnail(at url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The full image, or nil when the file is missing or not decodable.
    package static func fullImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
