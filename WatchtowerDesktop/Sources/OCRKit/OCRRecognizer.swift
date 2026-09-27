import CoreGraphics
import Foundation
import ImageIO
import Vision

/// One recognized page of the helper's output: `index` is the 0-based PDF
/// page (0 for an image).
public struct OCRPage: Codable, Equatable, Sendable {
    public let index: Int
    public let text: String

    public init(index: Int, text: String) {
        self.index = index
        self.text = text
    }
}

/// Errors that make the helper exit 2 (the file cannot be read as a PDF or
/// an image).
public enum OCRError: Error, CustomStringConvertible, Equatable {
    case unreadable(String)
    case renderFailed(Int)

    public var description: String {
        switch self {
        case .unreadable(let path): "cannot read \(path) as a PDF or an image"
        case .renderFailed(let page): "cannot render PDF page \(page)"
        }
    }
}

/// On-device text recognition for the Go attachment extractor
/// (`internal/extract`'s OCR). Vision, CoreGraphics and ImageIO only: it reads
/// the one file it is handed and never touches the camera, screen,
/// microphone, Photos or any protected folder, so it cannot raise a TCC
/// prompt.
public enum OCRRecognizer {
    /// Recognition languages (global constraints: ru-RU, uk-UA, en-US).
    public static let languages = ["ru-RU", "uk-UA", "en-US"]
    /// At most this many PDF pages per attachment (mirrors extract.MaxOCRPages).
    public static let maxPages = 50
    /// Longest side of a rendered page or decoded image, in pixels. PDF pages
    /// render at 2x their media box, scaled down to this bound, so a crafted
    /// giant media box cannot allocate a multi-gigabyte bitmap.
    public static let maxRenderPixels = 4096

    /// The recognition request (global constraints: accurate, the three
    /// languages, language correction on). A factory so the settings are
    /// pinned by a test.
    static func makeRequest() -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = true
        return request
    }

    /// Vision rejects images this small or smaller in either dimension.
    static let minVisionPixels = 2

    /// The text Vision recognizes in `image`, lines joined by newlines. An
    /// image too small for Vision holds no text: "" rather than an error, so
    /// the attachment is not retried as if OCR had failed.
    public static func recognize(image: CGImage) throws -> String {
        guard image.width > minVisionPixels, image.height > minVisionPixels else { return "" }
        let request = makeRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }

    /// Recognizes the given 0-based pages of the PDF at `pdfURL` (all pages
    /// when nil), capped by `cappedPages`. Out-of-range pages are skipped.
    public static func recognize(pdfURL: URL, pages: [Int]?) throws -> [Int: String] {
        guard let doc = CGPDFDocument(pdfURL as CFURL), doc.numberOfPages > 0 else {
            throw OCRError.unreadable(pdfURL.path)
        }
        var out: [Int: String] = [:]
        for index in cappedPages(pages, pageCount: doc.numberOfPages) {
            // CGPDFDocument pages are 1-based.
            guard let page = doc.page(at: index + 1) else { continue }
            // Each page's bitmap and Vision buffers are released before the
            // next page is rendered: up to 50 pages must not pile up.
            out[index] = try autoreleasepool {
                guard let image = render(page) else { throw OCRError.renderFailed(index) }
                return try recognize(image: image)
            }
        }
        return out
    }

    /// The pages to recognize: the requested ones (every page when nil) that
    /// exist, first occurrence only, in request order, at most `maxPages`.
    public static func cappedPages(_ pages: [Int]?, pageCount: Int) -> [Int] {
        let requested = pages ?? Array(0..<max(pageCount, 0))
        var seen = Set<Int>()
        var out: [Int] = []
        for page in requested where page >= 0 && page < pageCount && !seen.contains(page) {
            seen.insert(page)
            out.append(page)
            if out.count == maxPages { break }
        }
        return out
    }

    /// 2x the media box, reduced so the longest side fits maxRenderPixels.
    public static func renderScale(for size: CGSize) -> CGFloat {
        let longest = max(size.width, size.height)
        guard longest > 0 else { return 2 }
        return min(2, CGFloat(maxRenderPixels) / longest)
    }

    /// Renders one PDF page onto a white bitmap the way a viewer shows it:
    /// its crop box only, turned by its /Rotate, so a scan stored sideways
    /// with a /Rotate reaches Vision upright.
    static func render(_ page: CGPDFPage) -> CGImage? {
        let crop = page.getBoxRect(.cropBox)
        let rotation = ((Int(page.rotationAngle) % 360) + 360) % 360
        let shown = rotation.isMultiple(of: 180) ? crop.size : CGSize(width: crop.height, height: crop.width)
        let scale = renderScale(for: shown)
        let width = Int((shown.width * scale).rounded()), height = Int((shown.height * scale).rounded())
        guard width > 0, height > 0, let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: scale, y: scale)
        ctx.concatenate(displayTransform(crop: crop, rotation: rotation))
        ctx.clip(to: crop)
        ctx.drawPDFPage(page)
        return ctx.makeImage()
    }

    /// Maps page space to display space (origin at 0,0): the crop box turned
    /// clockwise by `rotation` (0, 90, 180 or 270 degrees, PDF /Rotate).
    static func displayTransform(crop: CGRect, rotation: Int) -> CGAffineTransform {
        let x0 = crop.minX, y0 = crop.minY, w = crop.width, h = crop.height
        switch rotation {
        case 90: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: -y0, ty: w + x0)
        case 180: return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: x0 + w, ty: y0 + h)
        case 270: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: y0 + h, ty: -x0)
        default: return CGAffineTransform(translationX: -x0, y: -y0)
        }
    }

    /// The helper's work on one file: a PDF (sniffed from its header, not its
    /// name) yields the requested pages; anything else is decoded as an image
    /// (first frame, index 0) and `pages` is ignored.
    public static func run(path: String, pages: [Int]?) throws -> [OCRPage] {
        let url = URL(fileURLWithPath: path)
        if try isPDF(url) {
            return try recognize(pdfURL: url, pages: pages)
                .sorted { $0.key < $1.key }
                .map { OCRPage(index: $0.key, text: $0.value) }
        }
        return [OCRPage(index: 0, text: try recognize(image: try decodeImage(url)))]
    }

    /// PDF files start with "%PDF-" within their first 1024 bytes.
    static func isPDF(_ url: URL) throws -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw OCRError.unreadable(url.path)
        }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 1024)) ?? Data()
        return head.contains(Data("%PDF-".utf8))
    }

    /// Decodes the image's first frame, bounded to maxRenderPixels.
    static func decodeImage(_ url: URL) throws -> CGImage {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxRenderPixels,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw OCRError.unreadable(url.path)
        }
        return image
    }

    /// The helper's stdout: `{"pages":[{"index":0,"text":"…"}]}`.
    public static func encode(_ pages: [OCRPage]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Output(pages: pages))
    }

    private struct Output: Encodable {
        let pages: [OCRPage]
    }
}
