import AppKit
import SwiftUI
import XCTest
@testable import WatchtowerDesktop

/// Renders every `DesignShotCatalog` entry in light and dark mode (style
/// guide #719, spec §6). Each shot must draw something — more than one
/// distinct colour — and with `DESKTOP_SHOTS_DIR` set it lands as
/// `<dir>/<name>-light.png` and `<dir>/<name>-dark.png` for a by-eye
/// before/after comparison (`make desktop-shots`). Nothing asserts pixels.
@MainActor
final class DesignShotsTests: XCTestCase {
    override static func tearDown() {
        MainActor.assumeIsolated { DesignShotFixtures.cleanUp() }
        super.tearDown()
    }

    func testEveryShotRenders() throws {
        let shots = DesignShotCatalog.all
        XCTAssertFalse(shots.isEmpty, "the catalog registers no shots")
        XCTAssertEqual(Set(shots.map(\.name)).count, shots.count, "shot names are file stems and must be unique")

        let outputDir = ProcessInfo.processInfo.environment["DESKTOP_SHOTS_DIR"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        if let outputDir {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        }

        for shot in shots {
            let probe = ViewRenderProbe(size: shot.size)
            for (suffix, name) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let appearance = try XCTUnwrap(NSAppearance(named: name))
                let data = try probe.png(shot.make(), appearance)
                let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
                XCTAssertGreaterThan(Self.distinctColours(bitmap, limit: 2), 1, "\(shot.name)-\(suffix) is blank")
                if let outputDir {
                    try data.write(to: outputDir.appendingPathComponent("\(shot.name)-\(suffix).png"))
                }
            }
        }
    }

    /// Distinct raw RGBA values in `bitmap`, counting up to `limit` only.
    private static func distinctColours(_ bitmap: NSBitmapImageRep, limit: Int) -> Int {
        guard let data = bitmap.bitmapData else { return 0 }
        let bytesPerPixel = bitmap.bitsPerPixel / 8
        var seen = Set<UInt32>()
        for y in 0..<bitmap.pixelsHigh {
            let row = data + y * bitmap.bytesPerRow
            for x in 0..<bitmap.pixelsWide {
                let pixel = row + x * bytesPerPixel
                let value = UInt32(pixel[0]) << 24 | UInt32(pixel[1]) << 16 | UInt32(pixel[2]) << 8 | UInt32(pixel[3])
                seen.insert(value)
                if seen.count >= limit { return seen.count }
            }
        }
        return seen.count
    }
}
