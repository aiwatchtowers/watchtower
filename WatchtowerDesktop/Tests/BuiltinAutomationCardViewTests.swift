import XCTest
import SwiftUI
import ViewInspector
import WatchtowerCore
import WatchtowerTestSupport
@testable import WatchtowerDesktop

/// The built-in card (C2 Task 10) over `show --json`'s golden `builtin`
/// block (`internal/automations/builtin/testdata/show_morning_brief.json`).
@MainActor
final class BuiltinAutomationCardViewTests: XCTestCase {
    private static func golden() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("internal/automations/builtin/testdata/show_morning_brief.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private static func show(needsConfirmation: Bool = false, _ overrides: [String: Any] = [:]) throws -> Data {
        var block = try golden()
        block.merge(overrides) { _, new in new }
        return try JSONSerialization.data(withJSONObject: [
            "id": 3, "slug": "morning-brief", "scope": "personal", "path": "builtin:morning-brief",
            "name": "Morning brief", "enabled": true, "runnable": !needsConfirmation,
            "needs_confirmation": needsConfirmation, "recipe_text": "---\nname: Morning brief\n---\nMine.\n",
            "builtin": block
        ] as [String: Any])
    }

    private func card(_ show: Data, overridden: Bool = false) async -> BuiltinAutomationCardModel {
        let automation = Automation(
            id: 3, slug: "morning-brief", path: "builtin:morning-brief", name: "Morning brief",
            triggerKind: "sync", triggerSpecJSON: #"{"sync":"morning_brief"}"#, enabled: true,
            origin: .builtin, builtinID: "morning-brief", overridden: overridden)
        let model = BuiltinAutomationCardModel(automation: automation, cli: AutomationsCLI(runner: FakeCLIRunner(stdout: show)))
        await model.load()
        return model
    }

    private func view(_ model: BuiltinAutomationCardModel) -> BuiltinAutomationCard {
        BuiltinAutomationCard(model: model) {}
    }

    func testRunNowHiddenWhenRunNowFalse() async throws {
        let hidden = await card(try Self.show(["run_now": false]))
        XCTAssertThrowsError(try view(hidden).inspect().find(button: "Run Now"))
        XCTAssertNoThrow(try view(hidden).inspect().find(button: "Edit in Chat"))
        XCTAssertNoThrow(try view(hidden).inspect().find(button: "Turn Off"))

        let shown = await card(try Self.show())
        XCTAssertNoThrow(try view(shown).inspect().find(button: "Run Now"))
    }

    func testOffCardOffersTurnOnAndDisablesRunNow() async throws {
        let model = await card(try Self.show(["enabled": false]))
        XCTAssertNoThrow(try view(model).inspect().find(button: "Turn On"))
        XCTAssertTrue(try view(model).inspect().find(button: "Run Now").isDisabled())
    }

    func testSectionsShowWhenReadsSendsAndCosts() async throws {
        let model = await card(try Self.show())
        let sut = view(model)
        for label in ["When", "Reads", "Sends", "Costs"] {
            XCTAssertNoThrow(try sut.inspect().find(text: label), label)
        }
        XCTAssertNoThrow(try sut.inspect().find(text: "Every morning at the first sync after 08:00"))
        XCTAssertNoThrow(try sut.inspect().find(text: "Your day card in the Inbox"))
        XCTAssertNoThrow(try sut.inspect().find(text: "Cost not reported"))
        XCTAssertThrowsError(try sut.inspect().find(button: "Save"), "Save appears only once a field changed")
        XCTAssertThrowsError(try sut.inspect().find(button: "Delete…"), "a built-in is turned off, never deleted")
    }

    func testOwnCopyShowsBannerResetAndUnconfirmedLine() async throws {
        let model = await card(try Self.show(needsConfirmation: true, ["overridden": true, "update_available": true]),
                               overridden: true)
        XCTAssertNoThrow(try view(model).inspect().find(text: "Built-in version updated"))
        XCTAssertNoThrow(try view(model).inspect().find(button: "Show changes"))
        XCTAssertNoThrow(try view(model).inspect().find(text: BuiltinAutomationCard.unconfirmedLine))

        try view(model).inspect().find(button: "Reset to built-in").tap()
        XCTAssertTrue(model.resetConfirming)
        XCTAssertNoThrow(try view(model).inspect().find(text: "Reset — your changes are lost"))
        XCTAssertNoThrow(try view(model).inspect().find(button: "Reset"))
        try view(model).inspect().find(button: "Cancel").tap()
        XCTAssertFalse(model.resetConfirming)
    }

    func testShippedCardHasNoResetOrBanner() async throws {
        let model = await card(try Self.show())
        XCTAssertThrowsError(try view(model).inspect().find(text: "Built-in version updated"))
        XCTAssertThrowsError(try view(model).inspect().find(button: "Reset to built-in"))
        XCTAssertThrowsError(try view(model).inspect().find(text: BuiltinAutomationCard.unconfirmedLine))
    }

    func testWhenFieldValidation() throws {
        let parameters = try JSONDecoder().decode(BuiltinAutomationDetail.self,
                                                  from: try Self.show(), path: "builtin").parameters
        XCTAssertFalse(BuiltinAutomationCard.changed(parameters, edits: [:]))
        XCTAssertFalse(BuiltinAutomationCard.changed(parameters, edits: ["briefing.hour": "8"]), "the value it had")
        XCTAssertTrue(BuiltinAutomationCard.changed(parameters, edits: ["briefing.hour": "9"]))
        XCTAssertNil(BuiltinAutomationCard.invalidField(parameters, edits: ["day_plan.working_hours_start": "08:30"]))
        XCTAssertEqual(BuiltinAutomationCard.invalidField(parameters, edits: ["day_plan.working_hours_end": "7pm"]),
                       "to: use HH:MM, for example 09:00")
        for bad in ["9:00", "24:00", "09:60", "0900", ""] { XCTAssertFalse(BuiltinAutomationCard.isClock(bad), bad) }
        XCTAssertTrue(BuiltinAutomationCard.isClock("23:59"))
    }
}

private extension JSONDecoder {
    /// Decodes the object under `key` of a JSON object.
    func decode<T: Decodable>(_ type: T.Type, from data: Data, path key: String) throws -> T {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try decode(type, from: JSONSerialization.data(withJSONObject: try XCTUnwrap(object[key])))
    }
}
