#!/usr/bin/env swift
// Generate a monochrome template menu-bar icon from the colored app-icon glyph.
// The bright glyph becomes black-with-alpha and the dark background turns
// transparent, per the macOS template-image convention (the system tints it).
// Usage: swift generate-menubar-icon.swift <source.png> <output.png> <canvas_px>

import AppKit
import Foundation

guard CommandLine.arguments.count == 4, let canvas = Int(CommandLine.arguments[3]) else {
    fputs("Usage: swift generate-menubar-icon.swift <source.png> <output.png> <canvas_px>\n", stderr)
    exit(1)
}
let sourcePath = CommandLine.arguments[1]
let outputPath = CommandLine.arguments[2]

guard let data = FileManager.default.contents(atPath: sourcePath),
      let src = NSBitmapImageRep(data: data) else {
    fputs("ERROR: Cannot load \(sourcePath)\n", stderr)
    exit(1)
}

let w = src.pixelsWide
let h = src.pixelsHigh

guard let mask = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
), let buf = mask.bitmapData else {
    fputs("ERROR: Cannot allocate mask bitmap\n", stderr)
    exit(1)
}

// Luminance-keyed alpha: the glyph is bright on a dark background, so a soft
// ramp between the two keeps anti-aliased edges smooth instead of jagged.
var minX = w, minY = h, maxX = -1, maxY = -1
for y in 0..<h {
    for x in 0..<w {
        var alpha: CGFloat = 0
        if let c = src.colorAt(x: x, y: y) {
            let lum = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
            let lo: CGFloat = 0.25, hi: CGFloat = 0.55
            alpha = min(max((lum - lo) / (hi - lo), 0), 1) * c.alphaComponent
        }
        let off = y * mask.bytesPerRow + x * 4
        buf[off] = 0
        buf[off + 1] = 0
        buf[off + 2] = 0
        buf[off + 3] = UInt8(alpha * 255)
        if alpha > 0.1 {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
}

guard maxX >= minX, maxY >= minY else {
    fputs("ERROR: No glyph pixels found\n", stderr)
    exit(1)
}

let maskImage = NSImage(size: NSSize(width: w, height: h))
maskImage.addRepresentation(mask)

// Fit the glyph bounding box into the canvas with a 1/18 margin per side
// (1 pt at the 18 pt menu-bar size).
let bw = CGFloat(maxX - minX + 1)
let bh = CGFloat(maxY - minY + 1)
let margin = CGFloat(canvas) / 18.0
let inner = CGFloat(canvas) - margin * 2
let scale = min(inner / bw, inner / bh)
let destW = bw * scale
let destH = bh * scale
// colorAt() coordinates are top-down; NSImage.draw source rects are bottom-up.
let fromRect = NSRect(x: CGFloat(minX), y: CGFloat(h - maxY - 1), width: bw, height: bh)
let destRect = NSRect(
    x: (CGFloat(canvas) - destW) / 2,
    y: (CGFloat(canvas) - destH) / 2,
    width: destW, height: destH
)

let out = NSImage(size: NSSize(width: canvas, height: canvas))
out.lockFocus()
NSGraphicsContext.current?.imageInterpolation = .high
maskImage.draw(in: destRect, from: fromRect, operation: .sourceOver, fraction: 1.0)
out.unlockFocus()

guard let tiff = out.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fputs("ERROR: Failed to encode PNG\n", stderr)
    exit(1)
}
try png.write(to: URL(fileURLWithPath: outputPath))
print("Done! Saved \(canvas)x\(canvas) template icon to \(outputPath)")
