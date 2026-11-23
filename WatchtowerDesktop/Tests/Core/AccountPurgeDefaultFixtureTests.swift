import Foundation
import XCTest
@testable import WatchtowerCore

/// PURGE-01 (#1769, P7): the Privacy switch shows the same value as Go's
/// `purge.Enabled` over one shared fixture, `internal/purge/testdata/default_cases.json`
/// (Go: `TestPurge01_DefaultSharedFixture`). With nothing known yet — the
/// CLI has not answered, or failed — it shows off, the default (owner
/// decision 2026-11-23).
final class AccountPurgeDefaultFixtureTests: XCTestCase {
    private struct Case: Decodable {
        let name: String
        let policy: Bool? // swiftlint:disable:this discouraged_optional_boolean
        let setting: Bool? // swiftlint:disable:this discouraged_optional_boolean
        let build: String
        let statusEnabled: Bool? // swiftlint:disable:this discouraged_optional_boolean
        let statusEnabledBy: String
        let shown: Bool

        enum CodingKeys: String, CodingKey {
            case name, policy, setting, build, shown
            case statusEnabled = "status_enabled"
            case statusEnabledBy = "status_enabled_by"
        }
    }

    private func cases() throws -> [Case] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("internal/purge/testdata/default_cases.json")
        return try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
    }

    func testSharedCases() throws {
        let all = try cases()
        // A build default is Go-only: the Desktop learns it from the CLI status.
        let desktop = all.filter { $0.build.isEmpty }
        XCTAssertGreaterThanOrEqual(desktop.count, 8)
        for c in desktop {
            let status = c.statusEnabled.map { AccountPurgeStatus(enabled: $0, enabledBy: c.statusEnabledBy) }
            XCTAssertEqual(
                AccountPurgeStatus.shownValue(policy: c.policy, setting: c.setting, status: status), c.shown, c.name)
        }
    }

    func testUnknownStatusShowsOff() {
        XCTAssertFalse(AccountPurgeStatus.buildDefault)
        XCTAssertFalse(AccountPurgeStatus.shownValue(policy: nil, setting: nil, status: nil))
    }
}
