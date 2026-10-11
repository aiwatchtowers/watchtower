import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// The QR sheet of Settings → Mobile: the `watchtower://link` code, its
/// countdown and New code (mobile POC spec §2.3). `onDone` dismisses the
/// sheet; the presenter's dismissal closes the link.
struct MobileLinkSheet: View {
    let model: MobileLinkSheetViewModel
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Use Watchtower on iPhone")
                .font(.title2.weight(.semibold))
            content
                .frame(minHeight: 280)
            HStack {
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 380)
        .task { await model.start() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .issuing:
            ProgressView("Making a code…")
        case .showing:
            VStack(spacing: 12) {
                if let image = model.qrImage {
                    Image(decorative: image, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 220, height: 220)
                        .accessibilityLabel("Link code")
                }
                Text("Scan it with the iPhone camera or the Watchtower app.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text("Expires in \(model.countdownText)")
                    .monospacedDigit()
                Button("New code") { Task { await model.newCode() } }
            }
        case .expired:
            VStack(spacing: 12) {
                Text("This code expired.")
                Button("Show a new code") { Task { await model.newCode() } }
            }
        case .linked(let name):
            Label("Linked \(name)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            VStack(spacing: 12) {
                Text(message)
                    .multilineTextAlignment(.center)
                Button("Try again") { Task { await model.newCode() } }
            }
        }
    }
}

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
