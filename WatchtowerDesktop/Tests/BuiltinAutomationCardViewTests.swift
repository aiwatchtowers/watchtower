import XCTest
import GRDB
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

    // MARK: - C3 cards

    /// `show --json` of a C3 built-in, its block the Go golden `show_<golden>.json`.
    private static func c3Show(_ golden: String, slug: String, name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("internal/automations/builtin/testdata/show_\(golden).json")
        let block = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return try JSONSerialization.data(withJSONObject: [
            "id": 5, "slug": slug, "scope": "personal", "path": "builtin:\(slug)", "name": name,
            "enabled": true, "runnable": true, "needs_confirmation": false, "recipe_text": "---\nname: \(name)\n---\n",
            "builtin": block
        ] as [String: Any])
    }

    private func c3Card(_ golden: String, slug: String, name: String) async throws -> BuiltinAutomationCardModel {
        let automation = Automation(
            id: 5, slug: slug, path: "builtin:\(slug)", name: name, triggerKind: "sync",
            triggerSpecJSON: #"{"sync":"x"}"#, enabled: true, origin: .builtin, builtinID: slug)
        let runner = FakeCLIRunner(stdout: try Self.c3Show(golden, slug: slug, name: name))
        let model = BuiltinAutomationCardModel(automation: automation, cli: AutomationsCLI(runner: runner))
        await model.load()
        XCTAssertNotNil(model.detail, model.loadError ?? "")
        return model
    }

    /// Idea finder's "Every 6 hours" stepper writes `ideas.mine_interval_hours`
    /// through the config writer, outside the recipe.
    func testIntervalParameterSavesThroughConfig() async throws {
        let model = try await c3Card("idea_finder", slug: "idea-finder", name: "Idea finder")
        let configPath = NSTemporaryDirectory() + "BuiltinCard-\(UUID().uuidString).yaml"
        defer { try? FileManager.default.removeItem(atPath: configPath) }
        try "ideas:\n  enabled: true\n  mine_interval_hours: 6\n".write(toFile: configPath, atomically: true, encoding: .utf8)
        var saved: [[String: String]] = []
        var actions = BuiltinCardActions()
        actions.saveParameters = { values in
            saved.append(values)
            do {
                try ConfigService(configPath: configPath).saveBuiltinParameters(values)
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        func view() -> BuiltinAutomationCard { BuiltinAutomationCard(model: model, actions: actions) {} }

        XCTAssertNoThrow(try view().inspect().find(text: "Every"))
        XCTAssertNoThrow(try view().inspect().find(text: "6 hours"))
        try view().inspect().find(ViewType.Stepper.self).increment()
        XCTAssertEqual(model.parameterEdits, [BuiltinAutomationCardModel.ideasIntervalKey: "7"])
        XCTAssertNoThrow(try view().inspect().find(text: "7 hours"))
        XCTAssertNil(model.invalidParameter)

        await model.saveParameters(actions.saveParameters)

        XCTAssertEqual(saved, [["ideas.mine_interval_hours": "7"]])
        XCTAssertNil(model.actionError)
        let config = ConfigService(configPath: configPath)
        XCTAssertEqual(config.ideasMineIntervalHours, 7)
        XCTAssertThrowsError(try ConfigService(configPath: configPath)
            .saveBuiltinParameters(["ideas.mine_interval_hours": "0"]), "an interval is 1 hour or more")
    }

    /// The Reactions card: no Run Now (its golden's `run_now: false`), the
    /// emoji table under When with its rows' tool pickers and **+**.
    func testReactionsCardEmbedsDictionaryAndHasNoRunNow() async throws {
        let model = try await c3Card("reactions", slug: "reactions", name: "Reactions")
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        try await pool.write { db in
            _ = try TestDatabase.insertReactionCommandMapping(db, emoji: "eyes", tool: "create_track")
        }
        let dictionary = ReactionDictionaryViewModel(dbPool: pool)
        await dictionary.refreshAsync()
        let sut = BuiltinAutomationCard(model: model, onEdit: {}, onNewReactionAutomation: {},
                                        reactionDictionary: dictionary)

        XCTAssertThrowsError(try sut.inspect().find(button: "Run Now"))
        XCTAssertNoThrow(try sut.inspect().find(text: "When you react to a Slack message"))
        let editor = try sut.inspect().find(ReactionDictionaryEditor.self)
        XCTAssertNoThrow(try editor.find(text: "Reactions"))
        XCTAssertNoThrow(try editor.find(text: SlackEmoji.label(forShortcode: "eyes")))
        XCTAssertNoThrow(try editor.find(ViewType.Picker.self), "a row's tool is edited in place")
        XCTAssertNoThrow(try editor.find(button: "Remove"))
        XCTAssertNoThrow(try editor.find(viewWithAccessibilityLabel: "Add a reaction"))
        XCTAssertThrowsError(try sut.inspect().find(ViewType.TextField.self), "the add row opens only on +")
    }

    /// **New reaction automation** is on the Reactions card only, and opens
    /// the `on-reaction` template's panel in Personal.
    func testNewReactionAutomationOpensTemplate() async throws {
        let reactions = try await c3Card("reactions", slug: "reactions", name: "Reactions")
        var pressed = 0
        try BuiltinAutomationCard(model: reactions, onEdit: {}, onNewReactionAutomation: { pressed += 1 })
            .inspect().find(button: BuiltinAutomationCard.newReactionAutomation).tap()
        XCTAssertEqual(pressed, 1)
        let ideas = try await c3Card("idea_finder", slug: "idea-finder", name: "Idea finder")
        XCTAssertThrowsError(try BuiltinAutomationCard(model: ideas, onEdit: {}, onNewReactionAutomation: {})
            .inspect().find(button: BuiltinAutomationCard.newReactionAutomation))

        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let templates = Data(#"[{"name":"on-reaction","title":"When I react with an emoji"}]"#.utf8)
        let runner = FakeCLIRunner(stdout: templates)
        let cli = AutomationsCLI(runner: runner)
        let vm = AutomationsViewModel(dbPool: pool, cli: cli)
        var started: [String] = []
        let hooks = AutomationEditorChatHooks(
            scopes: [.personal], workspaceDir: "/acme", draftContextID: { _ in "draft" },
            makeNewChat: { _, _ in nil }, makeEditChat: { _ in nil },
            templatePanel: { _, _ in nil },
            startTemplate: { name, scope in
                guard let template = vm.templates.first(where: { $0.name == name }) else { return nil }
                started.append(name)
                return AutomationTemplatePanelModel(template: template, scope: scope, cli: cli) { _ in }
            })

        await AutomationsView.openReactionTemplate(vm: vm, hooks: hooks)

        XCTAssertEqual(runner.invocations.first, ["automations", "templates", "--json"])
        XCTAssertEqual(started, ["on-reaction"])
        XCTAssertEqual(vm.panel, .template(name: "on-reaction", scope: .personal))
        XCTAssertNil(vm.lastError)
    }
}
