import AppKit
import SwiftUI
import XCTest
@testable import WatchtowerDesktop

/// The recorder's Stop reads in every state (#397): `.destructivePrimary`
/// draws a white label on a red plate whatever the theme, the window's key
/// state, the accent or the space the row leaves it — and the red
/// `.borderedProminent` buttons it replaced stay gone.
@MainActor
final class DestructivePrimaryButtonStyleTests: XCTestCase {
    private let probe = ViewRenderProbe(size: NSSize(width: 160, height: 44))

    private func stopButton() -> some View {
        Button {} label: { Label("Stop", systemImage: "stop.fill") }
            .buttonStyle(.destructivePrimary)
            .controlSize(.small)
    }

    func testLabelReadsOnTheRedPlateInEveryState() throws {
        let variants: [(String, AnyView)] = [
            ("plain", AnyView(stopButton())),
            ("inactive window", AnyView(stopButton().environment(\.controlActiveState, .inactive))),
            ("graphite-like tint", AnyView(stopButton().tint(.gray))),
            ("ancestor foreground", AnyView(stopButton().foregroundStyle(.red))),
            // A row that offers less than the label needs: the button keeps
            // its ideal width instead of truncating the label away.
            ("squeezed", AnyView(stopButton().frame(width: 20)))
        ]
        for appearance in [NSAppearance(named: .aqua), NSAppearance(named: .darkAqua)] {
            let appearance = try XCTUnwrap(appearance)
            for (name, view) in variants {
                let bitmap = try probe.render(view, appearance)
                let context = "\(name), \(appearance.name.rawValue)"
                let plate = try XCTUnwrap(redPlate(bitmap), "no red plate: \(context)")
                XCTAssertGreaterThanOrEqual(plate.width, 40, "plate squeezed: \(context)")
                XCTAssertGreaterThan(try whitePixels(bitmap, in: plate), 20, "no label on the plate: \(context)")
            }
        }
    }

    func testMetricsFollowControlSize() {
        let small = DestructivePrimaryButtonStyle.metrics(for: .small)
        let regular = DestructivePrimaryButtonStyle.metrics(for: .regular)
        XCTAssertEqual(small.fontSize, 11)
        XCTAssertLessThan(small.height, regular.height)
    }

    /// No red action is left on the system prominent style, whose label
    /// depends on window and app state: a file that tints a prominent
    /// button red within a few lines is the tell.
    func testNoRedBorderedProminentRemains() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .appendingPathComponent("Sources")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var scanned = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            scanned += 1
            // Comment lines aside: a mention in a comment draws no button.
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            for (index, line) in lines.enumerated() where line.contains(".tint(.red)") {
                let window = lines[max(0, index - 3)...min(lines.count - 1, index + 3)].joined(separator: "\n")
                XCTAssertFalse(window.contains(".borderedProminent"),
                               "\(url.lastPathComponent):\(index + 1) uses a red .borderedProminent; use .destructivePrimary")
            }
        }
        XCTAssertGreaterThan(scanned, 0, "the scan found no sources: wrong path?")
        let indicator = try String(contentsOf: sources.appendingPathComponent("Views/Calendar/RecordingIndicatorView.swift"),
                                   encoding: .utf8)
        XCTAssertEqual(indicator.components(separatedBy: ".buttonStyle(.destructivePrimary)").count - 1, 2,
                       "both Stop buttons (capsule and expanded panel) use the destructive style")
    }

    // MARK: - Pixels

    private func isRed(_ pixel: ViewRenderProbe.RGBA) -> Bool {
        pixel.alpha > 200 && pixel.red > 180 && pixel.green < 120 && pixel.blue < 120
    }

    /// The bounding box of the plate's red pixels, nil when none show.
    private func redPlate(_ bitmap: NSBitmapImageRep) throws -> CGRect? {
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where isRed(try probe.pixel(bitmap, x: x, y: y)) {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private func whitePixels(_ bitmap: NSBitmapImageRep, in rect: CGRect) throws -> Int {
        var count = 0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                let pixel = try probe.pixel(bitmap, x: x, y: y)
                if pixel.red > 220, pixel.green > 220, pixel.blue > 220 { count += 1 }
            }
        }
        return count
    }
}
