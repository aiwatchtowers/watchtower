import XCTest
@testable import WatchtowerCore
import WatchtowerTestSupport

/// The `show --json` `builtin` block, decoded from the Go golden
/// `internal/automations/builtin/testdata/show_morning_brief.json` (Go
/// `builtin.CardInfo` writes it; dual path pinned from both sides).
final class BuiltinAutomationDetailDecodingTests: XCTestCase {
    static func golden() throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("internal/automations/builtin/testdata/show_morning_brief.json")
        return try Data(contentsOf: url)
    }

    func testDecodesSharedGoldenBlock() throws {
        let detail = try JSONDecoder().decode(BuiltinAutomationDetail.self, from: Self.golden())
        XCTAssertEqual(detail.id, "morning-brief")
        XCTAssertEqual(detail.slot, "morning_brief")
        XCTAssertFalse(detail.overridden)
        XCTAssertEqual(detail.shippedHash.count, 64)
        XCTAssertEqual(detail.baseHash, "")
        XCTAssertFalse(detail.updateAvailable)
        XCTAssertTrue(detail.shippedText.hasPrefix("---\nname: Morning brief\n"))
        XCTAssertEqual(Set(detail.defaultPrompts.keys), ["brief", "plan"])
        XCTAssertEqual(detail.when, "Every morning at the first sync after 08:00")
        XCTAssertEqual(detail.reads.count, 5)
        XCTAssertEqual(detail.sends, ["Your day card in the Inbox"])
        XCTAssertEqual(detail.parameters.map(\.key),
                       ["briefing.hour", "day_plan.working_hours_start", "day_plan.working_hours_end"])
        XCTAssertEqual(detail.parameters.map(\.kind), [.hour, .clock, .clock])
        XCTAssertEqual(detail.parameters.map(\.label), ["Time", "Working hours from", "to"])
        XCTAssertEqual(detail.parameters.map(\.value), ["8", "09:00", "19:00"])
        XCTAssertEqual(detail.featureIDs, ["briefing", "day-plan"])
        XCTAssertTrue(detail.enabled)
        XCTAssertEqual(detail.copyError, "")
        XCTAssertEqual(detail.costs, BuiltinAutomationDetail.Costs(usd: 0, days: 7, reported: false))
    }

    func testDecodesRunNow() throws {
        XCTAssertTrue(try JSONDecoder().decode(BuiltinAutomationDetail.self, from: Self.golden()).runNow)
        let off = #"{"id":"x","run_now":false}"#
        XCTAssertFalse(try JSONDecoder().decode(BuiltinAutomationDetail.self, from: Data(off.utf8)).runNow)
    }

    func testEmptyListsDecodeAsEmpty() throws {
        let json = #"""
        {"id":"x","slot":"s","reads":[],"sends":[],"parameters":[],"feature_ids":[],"default_prompts":{},
         "costs":{"usd":0,"days":7,"reported":true}}
        """#
        let detail = try JSONDecoder().decode(BuiltinAutomationDetail.self, from: Data(json.utf8))
        XCTAssertEqual(detail.reads, [])
        XCTAssertEqual(detail.sends, [])
        XCTAssertEqual(detail.parameters, [])
        XCTAssertEqual(detail.featureIDs, [])
        XCTAssertEqual(detail.defaultPrompts, [:])
        XCTAssertTrue(detail.costs.reported)
    }

    func testShowDecodesTheOptionalBuiltinBlock() async throws {
        let block = try XCTUnwrap(String(data: Self.golden(), encoding: .utf8))
        let base = #""id":3,"slug":"morning-brief","scope":"personal","path":"builtin:morning-brief","#
            + #""name":"Morning brief","enabled":true,"runnable":true,"needs_confirmation":false"#
        let runner = FakeCLIRunner(stdout: Data("{\(base),\"builtin\":\(block)}".utf8))
        let shown = try await AutomationsCLI(runner: runner).show(3)
        XCTAssertEqual(shown.builtin?.id, "morning-brief")
        let owner = try JSONDecoder().decode(AutomationDetail.self, from: Data("{\(base)}".utf8))
        XCTAssertNil(owner.builtin)
    }

    func testResetAndUpgradeBuiltinsArgsAndResults() async throws {
        XCTAssertEqual(AutomationsCLI.args(.reset(4)), ["automations", "reset", "4", "--json"])
        XCTAssertEqual(AutomationsCLI.args(.upgradeBuiltins), ["automations", "upgrade-builtins", "--json"])
        let reset = FakeCLIRunner(stdout: Data(#"{"automation_id":4,"overridden":false,"approval_hash":"h"}"#.utf8))
        let result = try await AutomationsCLI(runner: reset).reset(4)
        XCTAssertEqual(reset.invocations, [["automations", "reset", "4", "--json"]])
        XCTAssertEqual(result.automationID, 4)
        XCTAssertFalse(result.overridden)
        XCTAssertEqual(result.approvalHash, "h")
        let upgrade = FakeCLIRunner(stdout: Data(
            #"{"results":[{"builtin_id":"morning-brief","status":"failed","error":"boom"}]}"#.utf8))
        let results = try await AutomationsCLI(runner: upgrade).upgradeBuiltins()
        XCTAssertEqual(results.map(\.builtinID), ["morning-brief"])
        XCTAssertEqual(results.map(\.status), ["failed"])
        XCTAssertEqual(results.map(\.error), ["boom"])
    }

    func testSavePassesABuiltinPathUnchanged() {
        let args = AutomationsCLI.args(.save(file: "/tmp/acme/d.md", path: "builtin:morning-brief", confirmHash: "h",
                                             expectContentHash: ""))
        XCTAssertEqual(args[5], "builtin:morning-brief")
    }
}
