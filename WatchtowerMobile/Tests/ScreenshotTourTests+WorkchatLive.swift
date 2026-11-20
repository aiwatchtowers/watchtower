import SwiftUI
import XCTest
@testable import WatchtowerMobile

/// The #2112 phone live-line frames (spec 2026-11-20 "Phone Workchat: the live line"): the mockups L1–L10.
extension ScreenshotTourTests {
    /// `SHOTS_ONLY=workchat-live` runs `testTheWorkchatLiveShots` alone.
    static let onlyWorkchatLive = ProcessInfo.processInfo.environment["WATCHTOWER_SHOTS_ONLY"] == "workchat-live"

    /// #2112: static mockups of the live line, the steps slot and the live agents sheet
    /// (`make mobile-shots SHOTS_ONLY=workchat-live`).
    func testTheWorkchatLiveShots() async throws {
        guard let path = ProcessInfo.processInfo.environment["WATCHTOWER_SHOTS_DIR"], Self.onlyWorkchatLive else {
            throw XCTSkip("Only with make mobile-shots SHOTS_ONLY=workchat-live")
        }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let (root, _) = try makeDemoRoot()
        let host = ScreenshotHost(directory: dir, env: root.env, linking: root.linking)
        for (name, view) in WorkchatLiveMockups.frames {
            try await host.capture(name, view, settle: .milliseconds(1_500))
        }
        let written = try FileManager.default.contentsOfDirectory(atPath: path).filter { $0.hasPrefix("workchat-live-") }
        XCTAssertEqual(written.count, 2 * WorkchatLiveMockups.frames.count)
    }
}
