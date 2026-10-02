import AppKit
import SwiftUI
import XCTest

/// Renders a SwiftUI view in a borderless window under a given appearance
/// and reads its pixels back — the layer tree composited as on screen, with
/// a top-left origin as the view's own coordinates. Shared by the render
/// tests that check which surface a spot of a tab paints.
@MainActor
struct ViewRenderProbe {
    struct RGBA: Equatable, CustomStringConvertible {
        let red: Int, green: Int, blue: Int, alpha: Int
        var description: String { "rgba(\(red), \(green), \(blue), \(alpha))" }
    }

    let size: NSSize

    func render(_ view: some View, _ appearance: NSAppearance) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        // Top-left origin, as `pixel(_:x:y:)` and the view's own coordinates.
        context.cgContext.translateBy(x: 0, y: size.height)
        context.cgContext.scaleBy(x: 1, y: -1)
        try XCTUnwrap(host.layer).render(in: context.cgContext)
        return bitmap
    }

    func pixel(_ bitmap: NSBitmapImageRep, x: Int, y: Int) throws -> RGBA {
        let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
        func byte(_ value: CGFloat) -> Int { Int((value * 255).rounded()) }
        return RGBA(red: byte(color.redComponent), green: byte(color.greenComponent),
                    blue: byte(color.blueComponent), alpha: byte(color.alphaComponent))
    }
}
