#!/bin/bash
# mobile-icon.sh — generate WatchtowerMobile's AppIcon.appiconset (Plan 6
# Decision 8: the icon is generated, flat, scripted — TestFlight requires a
# full icon set; real art comes later, the lane must not block on it).
#
# Design: flat geometric watchtower glyph — dark navy full-bleed background
# (iOS applies its own corner mask; App Store icons must be square, no alpha),
# light tower silhouette built from a few axis-aligned rects (merlons, gallery,
# body, plinth), one amber beacon window and a dark doorway.
#
# Mechanism: the 1024 master is rendered by an embedded Swift/CoreGraphics
# snippet (repo precedent: scripts/generate-icon.swift for the desktop .icns).
# ImageMagick is not a project dependency and sips has no compositing
# operation, while `swift` is guaranteed wherever xcodebuild runs. Determinism:
# antialiasing OFF + integer-aligned rects + alpha-free bitmap → identical
# bytes on re-run; the derived sizes come from `sips -z` on the same master.
#
# Output is COMMITTED (WatchtowerMobile/Sources/Assets.xcassets/AppIcon.appiconset);
# re-run only to change the design, then commit the regenerated PNGs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
XCASSETS="$PROJECT_ROOT/WatchtowerMobile/Sources/Assets.xcassets"
ICONSET="$XCASSETS/AppIcon.appiconset"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$ICONSET"

# --- 1. Render the 1024 master (deterministic CoreGraphics rects) -----------
cat > "$TMP_DIR/render.swift" << 'SWIFT'
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
// noneSkipLast → RGB without an alpha channel in the written PNG
// (App Store rejects marketing icons that carry alpha).
guard let ctx = CGContext(data: nil, width: size, height: size,
                          bitsPerComponent: 8, bytesPerRow: 0, space: space,
                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
    fatalError("cannot create CGContext")
}
ctx.setShouldAntialias(false) // crisp integer rects — deterministic pixels

func rgb(_ r: Int, _ g: Int, _ b: Int) -> CGColor {
    CGColor(colorSpace: space,
            components: [CGFloat(r) / 255, CGFloat(g) / 255, CGFloat(b) / 255, 1])!
}
// Design coordinates measure y from the TOP edge; CG's origin is bottom-left.
func fill(x: Int, y: Int, w: Int, h: Int, _ c: CGColor) {
    ctx.setFillColor(c)
    ctx.fill(CGRect(x: x, y: size - y - h, width: w, height: h))
}

let night = rgb(16, 24, 40)     // dark navy background
let stone = rgb(232, 236, 244)  // light tower silhouette
let lamp  = rgb(245, 185, 66)   // amber beacon window

fill(x: 0, y: 0, w: 1024, h: 1024, night)          // full-bleed background
fill(x: 372, y: 240, w: 56, h: 60, stone)          // left merlon
fill(x: 484, y: 240, w: 56, h: 60, stone)          // center merlon
fill(x: 596, y: 240, w: 56, h: 60, stone)          // right merlon
fill(x: 372, y: 300, w: 280, h: 60, stone)         // gallery platform
fill(x: 432, y: 360, w: 160, h: 400, stone)        // tower body
fill(x: 332, y: 760, w: 360, h: 60, stone)         // base plinth
fill(x: 484, y: 420, w: 56, h: 110, lamp)          // beacon window
fill(x: 484, y: 650, w: 56, h: 110, night)         // doorway

let out = URL(fileURLWithPath: CommandLine.arguments[1])
guard let img = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(out as CFURL,
                                                 UTType.png.identifier as CFString, 1, nil)
else { fatalError("cannot create image destination") }
CGImageDestinationAddImage(dest, img, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("PNG write failed") }
SWIFT

echo "==> Rendering 1024x1024 master..."
swift "$TMP_DIR/render.swift" "$ICONSET/AppIcon-1024.png"

# --- 2. Derive every required pixel size with sips --------------------------
# Union of iPhone + iPad slots (TARGETED_DEVICE_FAMILY = 1,2) + App Store 1024.
SIZES=(20 29 40 58 60 76 80 87 120 152 167 180)
for s in "${SIZES[@]}"; do
    echo "==> AppIcon-$s.png"
    sips -z "$s" "$s" "$ICONSET/AppIcon-1024.png" \
        --out "$ICONSET/AppIcon-$s.png" > /dev/null
done

# --- 3. Asset-catalog manifests ----------------------------------------------
# Shared pixel sizes reference the same file (e.g. iPhone 20@2x and iPad 40@1x
# are both AppIcon-40.png) — the catalog format allows that.
cat > "$ICONSET/Contents.json" << 'JSON'
{
  "images" : [
    { "filename" : "AppIcon-40.png",   "idiom" : "iphone", "scale" : "2x", "size" : "20x20" },
    { "filename" : "AppIcon-60.png",   "idiom" : "iphone", "scale" : "3x", "size" : "20x20" },
    { "filename" : "AppIcon-58.png",   "idiom" : "iphone", "scale" : "2x", "size" : "29x29" },
    { "filename" : "AppIcon-87.png",   "idiom" : "iphone", "scale" : "3x", "size" : "29x29" },
    { "filename" : "AppIcon-80.png",   "idiom" : "iphone", "scale" : "2x", "size" : "40x40" },
    { "filename" : "AppIcon-120.png",  "idiom" : "iphone", "scale" : "3x", "size" : "40x40" },
    { "filename" : "AppIcon-120.png",  "idiom" : "iphone", "scale" : "2x", "size" : "60x60" },
    { "filename" : "AppIcon-180.png",  "idiom" : "iphone", "scale" : "3x", "size" : "60x60" },
    { "filename" : "AppIcon-20.png",   "idiom" : "ipad",   "scale" : "1x", "size" : "20x20" },
    { "filename" : "AppIcon-40.png",   "idiom" : "ipad",   "scale" : "2x", "size" : "20x20" },
    { "filename" : "AppIcon-29.png",   "idiom" : "ipad",   "scale" : "1x", "size" : "29x29" },
    { "filename" : "AppIcon-58.png",   "idiom" : "ipad",   "scale" : "2x", "size" : "29x29" },
    { "filename" : "AppIcon-40.png",   "idiom" : "ipad",   "scale" : "1x", "size" : "40x40" },
    { "filename" : "AppIcon-80.png",   "idiom" : "ipad",   "scale" : "2x", "size" : "40x40" },
    { "filename" : "AppIcon-76.png",   "idiom" : "ipad",   "scale" : "1x", "size" : "76x76" },
    { "filename" : "AppIcon-152.png",  "idiom" : "ipad",   "scale" : "2x", "size" : "76x76" },
    { "filename" : "AppIcon-167.png",  "idiom" : "ipad",   "scale" : "2x", "size" : "83.5x83.5" },
    { "filename" : "AppIcon-1024.png", "idiom" : "ios-marketing", "scale" : "1x", "size" : "1024x1024" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

cat > "$XCASSETS/Contents.json" << 'JSON'
{
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

echo ""
echo "==> Done: $ICONSET"
