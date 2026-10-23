import GRDB
import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The built-in automations (C2 Task 10): the Built in section above
/// Personal with Morning brief's card, the card of the owner's copy with
/// the "Built-in version updated" banner and Show changes open, its Reset
/// confirm row, Settings → Features with the pointer, and the Inbox notice
/// of a failed move. Every `show` answer is the shared golden block.
@MainActor
enum BuiltinShotFixtures {
    private static var poolPaths: [String] = []

    static func cleanUp() {
        poolPaths.forEach(TestDatabase.cleanup(path:))
        poolPaths = []
    }

    private static func failure(_ error: Error) -> AnyView {
        XCTFail("design shot fixture failed: \(error)")
        return AnyView(Text("fixture failed: \(String(describing: error))").foregroundStyle(.red))
    }

    private static func makePool() throws -> DatabasePool {
        let (pool, path) = try TestDatabase.createPool()
        poolPaths.append(path)
        return pool
    }

    // MARK: - show --json

    private static func golden() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DesignShots
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("internal/automations/builtin/testdata/show_morning_brief.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    /// The owner's copy: the shipped text with a sharper brief and an
    /// extra line, made from an older shipped version.
    private static func ownCopy(_ shipped: String) -> String {
        shipped.replacingOccurrences(
            of: "brief and then plans your day from it",
            with: "brief, shorter on team pulse, and then plans your day from it"
        ) + "\n<!-- keep the brief under one screen -->\n"
    }

    private static func show(id: Int64, overridden: Bool, costs: Bool = true) throws -> Data {
        var block = try golden()
        let shipped = block["shipped_text"] as? String ?? ""
        if overridden {
            block["overridden"] = true
            block["update_available"] = true
            block["base_hash"] = "older"
        }
        if costs { block["costs"] = ["usd": 0.42, "days": 7, "reported": true] as [String: Any] }
        return try JSONSerialization.data(withJSONObject: [
            "id": id, "slug": "morning-brief", "scope": "personal", "path": "builtin:morning-brief",
            "name": "Morning brief", "enabled": true, "runnable": true, "needs_confirmation": false,
            "recipe_text": overridden ? ownCopy(shipped) : shipped, "builtin": block
        ] as [String: Any])
    }

    /// Morning brief's row, as the built-in indexer writes it.
    private static func insertMorningBrief(_ db: Database, overridden: Bool) throws -> Int64 {
        let id = try TestDatabase.insertAutomation(
            db, slug: "morning-brief", name: "Morning brief", triggerKind: "sync",
            triggerSpec: #"{"sync":"morning_brief"}"#,
            permissionsJSON: #"["builtin:brief.compose","builtin:plan.compose"]"#)
        try db.execute(sql: """
            UPDATE automations SET path = 'builtin:morning-brief', origin = 'builtin', builtin_id = 'morning-brief',
                overridden = ? WHERE id = ?
            """, arguments: [overridden, id])
        return id
    }

    /// Waits (bounded) for the card's `show` to land.
    private static func loaded(_ card: BuiltinAutomationCardModel) {
        Task { await card.load() }
        let deadline = Date().addingTimeInterval(5)
        while card.detail == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertNotNil(card.detail, "the fixture's show did not land: \(card.loadError ?? "")")
    }

    private static let hooks = AutomationEditorChatHooks(
        scopes: [.personal], workspaceDir: "/acme", draftContextID: { _ in "shot" },
        makeNewChat: { _, _ in nil }, makeEditChat: { _ in nil },
        templatePanel: { _, _ in nil }, startTemplate: { _, _ in nil }
    )

    // MARK: - Shots

    /// The tab: Built in (Morning brief) above Personal, its card open.
    static func list() -> AnyView {
        do {
            let pool = try makePool()
            let id = try pool.write { db -> Int64 in
                let id = try insertMorningBrief(db, overridden: false)
                try TestDatabase.insertAutomation(
                    db, slug: "morning-mail", name: "Morning mail digest", triggerKind: "schedule",
                    triggerSpec: #"{"schedule":"0 9 * * 1-5"}"#)
                return id
            }
            let vm = AutomationsViewModel(dbPool: pool, cli: AutomationsCLI(runner: ShowRunner(
                show: try show(id: id, overridden: false))))
            vm.refresh()
            vm.select(id)
            let item = try XCTUnwrap(vm.items.first { $0.id == id })
            loaded(vm.builtinCard(item.automation))
            return AnyView(AutomationsView(vm: vm, hooks: hooks))
        } catch {
            return failure(error)
        }
    }

    // MARK: - C3 cards

    /// `show --json` of a C3 built-in over its Go golden block.
    private static func c3Show(_ golden: String, id: Int64, slug: String, name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DesignShots
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("internal/automations/builtin/testdata/show_\(golden).json")
        var block = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        block["costs"] = ["usd": 0.18, "days": 7, "reported": true] as [String: Any]
        return try JSONSerialization.data(withJSONObject: [
            "id": id, "slug": slug, "scope": "personal", "path": "builtin:\(slug)", "name": name,
            "enabled": true, "runnable": true, "needs_confirmation": false,
            "recipe_text": block["shipped_text"] as? String ?? "", "builtin": block
        ] as [String: Any])
    }

    /// The Reactions card (its emoji table under When, no Run Now) or Idea
    /// finder's (the "Every 6 hours" stepper).
    static func c3Card(reactions: Bool) -> AnyView {
        do {
            let pool = try makePool()
            let (golden, slug, name) = reactions
                ? ("reactions", "reactions", "Reactions") : ("idea_finder", "idea-finder", "Idea finder")
            let id = try pool.write { db -> Int64 in
                let id = try TestDatabase.insertAutomation(db, slug: slug, name: name, triggerKind: "sync",
                                                           triggerSpec: #"{"sync":"x"}"#)
                try db.execute(sql: """
                    UPDATE automations SET path = ?, origin = 'builtin', builtin_id = ? WHERE id = ?
                    """, arguments: ["builtin:\(slug)", slug, id])
                for (emoji, tool, enabled) in [("eyes", "create_track", true), ("bulb", "create_idea", true),
                                               ("white_check_mark", "create_target", true),
                                               ("alarm_clock", "remind_me", false)] {
                    _ = try TestDatabase.insertReactionCommandMapping(db, emoji: emoji, tool: tool, enabled: enabled)
                }
                return id
            }
            let vm = AutomationsViewModel(dbPool: pool, cli: AutomationsCLI(runner: ShowRunner(
                show: try c3Show(golden, id: id, slug: slug, name: name))))
            vm.refresh()
            let item = try XCTUnwrap(vm.items.first)
            let card = vm.builtinCard(item.automation)
            loaded(card)
            let dictionary = ReactionDictionaryViewModel(dbPool: pool)
            Task { await dictionary.refreshAsync() }
            let deadline = Date().addingTimeInterval(5)
            while dictionary.mappings.isEmpty, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            return AnyView(BuiltinAutomationCard(model: card, onEdit: {}, onNewReactionAutomation: {},
                                                 reactionDictionary: dictionary).detailBackground())
        } catch {
            return failure(error)
        }
    }

    enum CardScene { case shipped, updated, resetting }

    static func card(_ scene: CardScene) -> AnyView {
        do {
            let pool = try makePool()
            let overridden = scene != .shipped
            let id = try pool.write { db in try insertMorningBrief(db, overridden: overridden) }
            let vm = AutomationsViewModel(dbPool: pool, cli: AutomationsCLI(runner: ShowRunner(
                show: try show(id: id, overridden: overridden, costs: scene != .resetting))))
            vm.refresh()
            let item = try XCTUnwrap(vm.items.first)
            let card = vm.builtinCard(item.automation)
            loaded(card)
            if scene == .updated { card.showingChanges = true }
            if scene == .resetting { card.beginReset() }
            return AnyView(BuiltinAutomationCard(model: card) {}.detailBackground())
        } catch {
            return failure(error)
        }
    }

    // MARK: - Settings → Features

    private static let featuresJSON = """
    {"features":[
      {"id":"slack-digests","title":"Slack Digests","description":"Channel digests.","tagline":"","benefits":[],
       "icon":"","state":"enabled","core":false,"parent":"","config_key":"digest.enabled","cost":"medium",
       "feeds_into":[],"sub_toggles":[]},
      {"id":"briefing","title":"Briefing","description":"The daily brief.","tagline":"","benefits":[],
       "icon":"","state":"enabled","core":false,"parent":"","config_key":"briefing.enabled","cost":"medium",
       "feeds_into":[],"sub_toggles":[]},
      {"id":"day-plan","title":"Day Plan","description":"Plans the day.","tagline":"","benefits":[],
       "icon":"","state":"enabled","core":false,"parent":"","config_key":"day_plan.enabled","cost":"light",
       "feeds_into":[],"sub_toggles":[]},
      {"id":"ideas","title":"Ideas & Decisions","description":"Mines ideas.","tagline":"","benefits":[],
       "icon":"","state":"enabled","core":false,"parent":"","config_key":"ideas.enabled","cost":"medium",
       "feeds_into":[],"sub_toggles":[]},
      {"id":"tracks","title":"Tracks","description":"Narrative tracks.","tagline":"","benefits":[],
       "icon":"","state":"enabled","core":false,"parent":"","config_key":"tracks.enabled","cost":"medium",
       "feeds_into":[],"sub_toggles":[]},
      {"id":"reaction-commands","title":"Reaction commands","description":"React to act.","tagline":"",
       "benefits":[],"icon":"","state":"enabled","core":false,"parent":"","config_key":"reaction_commands.enabled",
       "cost":"light","feeds_into":[],"sub_toggles":[]},
      {"id":"memory","title":"Memory","description":"Remembers context.","tagline":"","benefits":[],
       "icon":"","state":"enabled","core":false,"parent":"","config_key":"memory.enabled","cost":"heavy",
       "feeds_into":[],"sub_toggles":[]}
    ]}
    """

    /// The Feature Manager without Briefing and Day Plan, and the pointer
    /// row (the whole tab's notification section needs an app bundle).
    static func featuresSettings() -> AnyView {
        let manager = FeatureManagerService(runner: FakeCLIRunner(stdout: Data(featuresJSON.utf8)))
        Task { await manager.load() }
        let deadline = Date().addingTimeInterval(5)
        while manager.features.isEmpty, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return AnyView(Form {
            FeatureManagerSection(service: manager)
            BuiltinFeaturesPointer {}
        }
        .formStyle(.grouped)
        .detailBackground())
    }
}

/// Answers `show` with the fixture; any other verb fails, as a shot never
/// presses anything.
private final class ShowRunner: CLIRunnerProtocol, Sendable {
    private let show: Data

    init(show: Data) {
        self.show = show
    }

    func run(args: [String]) async throws -> Data {
        guard args.count > 1, args[1] == "show" else {
            throw CLIRunnerError.nonZeroExit(code: 1, stderr: "no fixture for \(args)")
        }
        return show
    }
}
