import XCTest
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop

@MainActor
final class SyncStatusBannerViewTests: XCTestCase {

    /// isRunning=true → текст "Daemon running".
    func testRunningTextWhenRunning() throws {
        let view = SyncStatusBanner(syncedAt: nil, isRunning: true)
        XCTAssertNoThrow(try view.inspect().find(text: "Daemon running"))
    }

    /// isRunning=false → текст "Daemon stopped".
    func testStoppedTextWhenNotRunning() throws {
        let view = SyncStatusBanner(syncedAt: nil, isRunning: false)
        XCTAssertNoThrow(try view.inspect().find(text: "Daemon stopped"))
    }

    /// syncedAt=nil → "Never synced".
    func testNeverSyncedWhenNil() throws {
        let view = SyncStatusBanner(syncedAt: nil, isRunning: true)
        XCTAssertNoThrow(try view.inspect().find(text: "Never synced"))
    }

    /// syncedAt задан → строка начинается с "Last sync:".
    func testLastSyncShownWhenSet() throws {
        let view = SyncStatusBanner(
            syncedAt: "2026-04-29T10:00:00Z",
            isRunning: true
        )
        // Конкретное "относительное время" зависит от Now и тестировать его хрупко;
        // ограничиваемся проверкой префикса.
        let allText = try view.inspect().findAll(ViewType.Text.self)
        let strings = try allText.map { try $0.string() }
        XCTAssertTrue(strings.contains { $0.hasPrefix("Last sync:") },
                      "expected one Text starting with 'Last sync:', got \(strings)")
    }
}
