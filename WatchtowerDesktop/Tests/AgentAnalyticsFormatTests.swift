import XCTest
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop
@testable import WatchtowerCore

/// The history loading line (#849): shown above the overview until the
/// import is done.
@MainActor
final class AgentAnalyticsFormatTests: XCTestCase {
    private static func fixture() -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Core/Fixtures/agent-report-overview.json")
        return (try? Data(contentsOf: url)) ?? Data()
    }

    /// The fixture overview with `import` replaced by `state`/`files`, or removed for nil.
    private static func overview(state: String?, files: Int = 0) throws -> AgentReportOverview {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture()) as? [String: Any])
        json["import"] = state.map { ["state": $0, "files_stored": files, "updated_at": "2026-10-18T17:00:00Z"] }
        return try JSONDecoder().decode(AgentReportOverview.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func texts(_ overview: AgentReportOverview) throws -> [String] {
        let view = AgentAnalyticsOverviewView(
            state: .overview(overview, staleError: nil),
            period: .constant(.week),
            actions: AgentAnalyticsActions(turnOn: {}, openSession: { _ in }, openTarget: { _ in })
        )
        return try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
    }

    func testImportLine() {
        XCTAssertNil(AgentAnalyticsFormat.importLine(AgentImportState(state: "done", filesStored: 2125, updatedAt: nil)))
        XCTAssertEqual(AgentAnalyticsFormat.importLine(AgentImportState(state: "loading", filesStored: 2125, updatedAt: nil)),
                       "Loading history — 2,125 files so far")
        XCTAssertEqual(AgentAnalyticsFormat.importLine(AgentImportState(state: "not_started", filesStored: 0, updatedAt: nil)),
                       "Loading history — 0 files so far")
    }

    func testOverviewShowsTheLoadingLineUntilDone() throws {
        XCTAssertTrue(try texts(Self.overview(state: "loading", files: 2125)).contains("Loading history — 2,125 files so far"))
        XCTAssertTrue(try texts(Self.overview(state: "not_started")).contains("Loading history — 0 files so far"))
        for state in ["done", nil] as [String?] {
            let all = try texts(Self.overview(state: state, files: 2125))
            XCTAssertFalse(all.contains { $0.hasPrefix("Loading history") }, "\(String(describing: state)): \(all)")
        }
    }
}
