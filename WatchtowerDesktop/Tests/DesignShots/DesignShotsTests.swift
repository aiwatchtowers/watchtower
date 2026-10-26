import AppKit
import SwiftUI
import XCTest
@testable import WatchtowerDesktop

/// Renders every `DesignShotCatalog` entry in light and dark mode (style
/// guide #719, spec §6) under `make desktop-shots`. Each shot must draw
/// something — more than one distinct colour — and lands as
/// `<dir>/<name>-light.png` and `<dir>/<name>-dark.png` in `DESKTOP_SHOTS_DIR`
/// for a by-eye before/after comparison. Nothing asserts pixels.
@MainActor
final class DesignShotsTests: XCTestCase {
    override static func tearDown() {
        MainActor.assumeIsolated { DesignShotFixtures.cleanUp() }
        super.tearDown()
    }

    func testShotNamesAreUnique() {
        let shots = DesignShotCatalog.all
        XCTAssertFalse(shots.isEmpty, "the catalog registers no shots")
        XCTAssertEqual(Set(shots.map(\.name)).count, shots.count, "shot names are file stems and must be unique")
    }

    /// Rendering every shot costs ~100 s, so it runs only under
    /// `make desktop-shots` (which sets `DESKTOP_SHOTS_DIR`), never in the
    /// unfiltered suite (style guide spec §6).
    func testEveryShotRenders() throws {
        guard let outputDir = ProcessInfo.processInfo.environment["DESKTOP_SHOTS_DIR"]
            .flatMap({ $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) })
        else {
            throw XCTSkip("DESKTOP_SHOTS_DIR is not set; run `make desktop-shots`")
        }
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let shots = DesignShotCatalog.all

        for shot in shots {
            // A zero height means "as tall as the content".
            var size = shot.size
            if size.height <= 0 {
                size.height = ViewRenderProbe.fittingHeight(shot.make(), width: size.width)
            }
            let probe = ViewRenderProbe(size: size)
            for (suffix, name) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let appearance = try XCTUnwrap(NSAppearance(named: name))
                let data = try probe.png(shot.make(), appearance)
                let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
                XCTAssertGreaterThan(Self.distinctColours(bitmap, limit: 2), 1, "\(shot.name)-\(suffix) is blank")
                try data.write(to: outputDir.appendingPathComponent("\(shot.name)-\(suffix).png"))
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
