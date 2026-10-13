import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// A QR image of a link URL, error correction M (spec §2.3: the payload
/// stays under 700 bytes, which fits level M).
enum LinkQRCode {
    static func cgImage(for text: String, scale: CGFloat = 8) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) else {
            return nil
        }
        return CIContext().createCGImage(output, from: output.extent)
    }
}
