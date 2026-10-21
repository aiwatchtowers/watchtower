import XCTest
@testable import WatchtowerCore

/// A CLI double answering by subcommand (`args[1]`), recording each call;
/// `hold` parks the named subcommand until `release()`.
private final class PanelRunner: CLIRunnerProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: Result<Data, CLIRunnerError>] = [:]
    private var recorded: [[String]] = []
    private var heldSubcommand: String?
    private var gate: CheckedContinuation<Void, Never>?
    private var gateOpened = false

    var invocations: [[String]] { lock.withLock { recorded } }
    var isHolding: Bool { lock.withLock { gate != nil } }

    func answer(_ subcommand: String, _ result: Result<Data, CLIRunnerError>) {
        lock.withLock { answers[subcommand] = result }
    }

    func hold(_ subcommand: String) {
        lock.withLock { heldSubcommand = subcommand }
    }

    func release() {
        let waiting: CheckedContinuation<Void, Never>? = lock.withLock {
            gateOpened = true
            defer { gate = nil }
            return gate
        }
        waiting?.resume()
    }

    func run(args: [String]) async throws -> Data {
        let sub = args.count > 1 ? args[1] : ""
        let (answer, held) = lock.withLock { () -> (Result<Data, CLIRunnerError>?, Bool) in
            recorded.append(args)
            return (answers[sub], heldSubcommand == sub)
        }
        if held {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = lock.withLock {
                    if gateOpened { return true }
                    gate = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
        return try answer?.get() ?? Data()
    }
}

/// The debounce's wait: suspends until the test fires it (or tears down).
@MainActor
private final class PanelSleeper {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var calls = 0

    func sleep(_: Duration) async {
        calls += 1
        await withCheckedContinuation { waiting.append($0) }
    }

    func fire() {
        let all = waiting
        waiting = []
        all.forEach { $0.resume() }
    }
}

@MainActor
final class AutomationTemplatePanelModelTests: XCTestCase {
    private var runner: PanelRunner!
    private var sleeper: PanelSleeper!
    private var refreshed: [Int64?] = []

    override func setUp() async throws {
        try await super.setUp()
        runner = PanelRunner()
        sleeper = PanelSleeper()
        refreshed = []
    }

    override func tearDown() async throws {
        runner.release()
        sleeper.fire()
        try await super.tearDown()
    }

    private static func template(params: Bool = true) throws -> AutomationTemplate {
        let paramJSON = params ? #"[{"key":"PROJECT","label":"Jira project key","example":"PAY"}]"# : "[]"
        let json = #"{"name":"jira-state-report","title":"Jira state report","description":"Weekly.","#
            + #""scope":"personal","trigger_text":"Mondays 09:00","permissions":[],"outputs":[],"#
            + #""params":\#(paramJSON)}"#
        return try JSONDecoder().decode(AutomationTemplate.self, from: Data(json.utf8))
    }

    /// `install-template --render --json` with one file per hash.
    private static func renderJSON(_ hashes: [String], project: String = "PAY", ok: Bool = true)
        -> Result<Data, CLIRunnerError> {
        let files = hashes.enumerated().map { i, hash in
            #"{"slug":"r\#(i)","text":"---\nname: R\#(i)\n---\n","#
                + #""validate":{"ok":\#(ok),"approval_hash":"\#(hash)","scope":"personal"}}"#
        }
        let body = #"{"name":"jira-state-report","scope":"personal","params":{"PROJECT":["\#(project)"]},"#
            + #""files":[\#(files.joined(separator: ","))]}"#
        return .success(Data(body.utf8))
    }

    /// `install-template --json` with copies 11, 12, … holding `hashes`.
    private static func installJSON(_ hashes: [String]) -> Result<Data, CLIRunnerError> {
        let copies = hashes.enumerated().map { i, hash in
            #"{"automation_id":\#(11 + i),"slug":"r\#(i)","path":"/acme/r\#(i).md","approval_hash":"\#(hash)"}"#
        }
        let body = #"{"automation_id":11,"path":"/acme/r0.md","params":{"PROJECT":["PAY"]},"#
            + #""installed":[\#(copies.joined(separator: ","))]}"#
        return .success(Data(body.utf8))
    }

    private func makeModel(params: Bool = true) throws -> AutomationTemplatePanelModel {
        let sleeper: PanelSleeper = sleeper
        return try AutomationTemplatePanelModel(
            template: Self.template(params: params),
            scope: .personal,
            cli: AutomationsCLI(runner: runner),
            refresh: { [weak self] id in self?.refreshed.append(id) },
            sleep: { await sleeper.sleep($0) }
        )
    }

    private var isRender: ([String]) -> Bool { { $0.contains("--render") } }
    private var renders: [[String]] { runner.invocations.filter(isRender) }
    /// Every call but the renders, as `subcommand [id] [--hash h]`.
    private var writes: [String] {
        runner.invocations.filter { !isRender($0) }.map { args in
            switch args[1] {
            case "install-template": "install-template"
            case "confirm": "confirm \(args[2]) --hash \(args[4])"
            default: "\(args[1]) \(args[2])"
            }
        }
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out")
                return
            }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func renderedModel(_ hashes: [String], params: Bool = true) async throws
        -> AutomationTemplatePanelModel {
        runner.answer("install-template", Self.renderJSON(hashes))
        let model = try makeModel(params: params)
        await model.appear()
        XCTAssertTrue(model.canSave)
        return model
    }

    func testRenderOnAppearAndDebouncedOnParamEdit() async throws {
        runner.answer("install-template", Self.renderJSON(["h1"]))
        let model = try makeModel()
        await model.appear()
        XCTAssertEqual(renders, [["automations", "install-template", "jira-state-report", "--render", "--json"]])
        guard case .rendered = model.state else { return XCTFail("not rendered: \(model.state)") }
        XCTAssertEqual(model.columns.count, 1)
        XCTAssertTrue(model.columns[0].isNew)

        await model.appear()
        XCTAssertEqual(renders.count, 1, "appearing again does not render again")

        model.params["PROJECT"] = "PA"
        model.paramsChanged()
        model.params["PROJECT"] = "PAY"
        model.paramsChanged()
        await waitUntil { self.sleeper.calls == 2 }
        sleeper.fire()
        await waitUntil { self.renders.count == 2 }
        XCTAssertEqual(renders.last, ["automations", "install-template", "jira-state-report",
                                      "--param", "PROJECT=PAY", "--render", "--json"])
        await waitUntil { model.canSave }
        XCTAssertEqual(renders.count, 2)
    }

    func testAuto06_TemplateConfirmsOnlyTheShownHash() async throws {
        let model = try await renderedModel(["h1"])
        runner.answer("install-template", Self.installJSON(["h2"]))
        await model.saveAndTurnOn()
        XCTAssertEqual(writes, ["install-template"], "no confirm, no enable")
        XCTAssertEqual(model.state, .stopped(AutomationTemplatePanelModel.differs, ids: [11]))
        XCTAssertEqual(refreshed, [11])
    }

    func testAuto06_LaterCopyDiffersStopsBeforeIt() async throws {
        let model = try await renderedModel(["a", "b", "c"])
        runner.answer("install-template", Self.installJSON(["a", "x", "c"]))
        await model.saveAndTurnOn()
        XCTAssertEqual(writes, ["install-template", "confirm 11 --hash a", "enable 11"])
        XCTAssertEqual(model.state, .stopped(AutomationTemplatePanelModel.differs, ids: [11, 12, 13]))
    }

    func testAuto06_NoInstalledCopiesConfirmsNothing() async throws {
        let model = try await renderedModel(["h1"])
        runner.answer("install-template", .success(Data(#"{"automation_id":11,"path":"/acme/r0.md"}"#.utf8)))
        await model.saveAndTurnOn()
        XCTAssertEqual(writes, ["install-template"])
        XCTAssertEqual(model.state, .stopped(AutomationTemplatePanelModel.differs, ids: []))
    }

    func testSaveAndTurnOnInstallsConfirmsAndEnablesEachCopy() async throws {
        let model = try await renderedModel(["a", "b", "c"])
        runner.answer("install-template", Self.installJSON(["a", "b", "c"]))
        await model.saveAndTurnOn()
        XCTAssertEqual(writes, ["install-template",
                                "confirm 11 --hash a", "enable 11",
                                "confirm 12 --hash b", "enable 12",
                                "confirm 13 --hash c", "enable 13"])
        let install = runner.invocations.first { !isRender($0) }
        XCTAssertEqual(install, ["automations", "install-template", "jira-state-report",
                                 "--param", "PROJECT=PAY", "--json"], "installs the rendered params")
        XCTAssertEqual(model.state, .done(firstID: 11))
        XCTAssertEqual(refreshed, [11])
        XCTAssertFalse(model.canAdjustInChat)
        XCTAssertNil(model.adjustText)
    }

    func testConfirmFailureAfterInstallLeavesTheCopy() async throws {
        let model = try await renderedModel(["h1"])
        runner.answer("install-template", Self.installJSON(["h1"]))
        runner.answer("confirm", .failure(.nonZeroExit(code: 1, stderr: "approval hash is stale")))
        await model.saveAndTurnOn()
        XCTAssertEqual(writes, ["install-template", "confirm 11 --hash h1"], "no delete, no enable")
        XCTAssertEqual(model.state, .stopped(AutomationTemplatePanelModel.notConfirmed("approval hash is stale"),
                                             ids: [11]))
        XCTAssertEqual(refreshed, [11])

        await model.saveAndTurnOn()
        model.paramsChanged()
        await model.render()
        XCTAssertEqual(writes, ["install-template", "confirm 11 --hash h1"], "a stopped panel installs nothing more")
        XCTAssertEqual(sleeper.calls, 0)
    }

    func testEnableFailureSaysConfirmedButNotOn() async throws {
        let model = try await renderedModel(["h1"])
        runner.answer("install-template", Self.installJSON(["h1"]))
        runner.answer("enable", .failure(.nonZeroExit(code: 1, stderr: "daemon busy")))
        await model.saveAndTurnOn()
        XCTAssertEqual(writes, ["install-template", "confirm 11 --hash h1", "enable 11"])
        XCTAssertEqual(model.state, .stopped(AutomationTemplatePanelModel.notTurnedOn("daemon busy"), ids: [11]))
    }

    func testInstallFailureIsShownAndRefreshes() async throws {
        let model = try await renderedModel(["h1"])
        runner.answer("install-template", .failure(.nonZeroExit(code: 1, stderr: "no workbench 3")))
        await model.saveAndTurnOn()
        XCTAssertEqual(model.state, .failed(AutomationTemplatePanelModel.notInstalled("no workbench 3")))
        XCTAssertFalse(model.canSave)
        XCTAssertEqual(refreshed, [nil])
    }

    func testCannotSaveWhileParamsChangedSinceRender() async throws {
        let model = try await renderedModel(["h1"])
        model.params["PROJECT"] = "OPS"
        model.paramsChanged()
        XCTAssertFalse(model.canSave, "the shown render is of other params")
        await model.saveAndTurnOn()
        XCTAssertEqual(writes, [])

        model.params["PROJECT"] = ""
        XCTAssertTrue(model.canSave, "an emptied field is the CLI's choice, as rendered")
    }

    func testCannotSaveAnInvalidRender() async throws {
        runner.answer("install-template", Self.renderJSON(["h1"], ok: false))
        let model = try makeModel()
        await model.appear()
        XCTAssertFalse(model.canSave)
        XCTAssertEqual(model.columns.first?.status, .invalid)
    }

    func testRenderFailureIsShownAndAppearRetries() async throws {
        runner.answer("install-template", .failure(.nonZeroExit(code: 1, stderr: "no active Jira project")))
        let model = try makeModel()
        await model.appear()
        XCTAssertEqual(model.state, .failed("no active Jira project"))
        runner.answer("install-template", Self.renderJSON(["h1"]))
        await model.appear()
        XCTAssertTrue(model.canSave)
    }

    func testAdjustInChatOnlyForSingleFileTemplates() async throws {
        let single = try await renderedModel(["h1"])
        XCTAssertTrue(single.canAdjustInChat)
        XCTAssertEqual(single.adjustText, "---\nname: R0\n---\n")

        let multi = try await renderedModel(["a", "b"])
        XCTAssertFalse(multi.canAdjustInChat)
        XCTAssertNil(multi.adjustText)
        XCTAssertEqual(multi.columns.count, 2)
    }

    func testInstallSurvivesNavigation() async throws {
        runner.answer("install-template", Self.renderJSON(["h1"]))
        let cli = AutomationsCLI(runner: runner)
        let panels = AutomationTemplatePanels { template, scope in
            AutomationTemplatePanelModel(template: template, scope: scope, cli: cli) { _ in }
        }
        let template = try Self.template()
        var model: AutomationTemplatePanelModel? = panels.panel(for: template, scope: .personal)
        await model?.appear()
        runner.answer("install-template", Self.installJSON(["h1"]))
        runner.hold("install-template")
        Task { [model] in await model?.saveAndTurnOn() }
        await waitUntil { self.runner.isHolding }
        model = nil // the view goes away
        runner.release()
        let kept = panels.panel(for: template, scope: .personal)
        await waitUntil { kept.state == .done(firstID: 11) }
        XCTAssertEqual(writes, ["install-template", "confirm 11 --hash h1", "enable 11"])

        let other = panels.panel(for: template, scope: .workbench(id: 3, name: "acme", folder: "/acme"))
        XCTAssertFalse(other === kept, "a panel per template and scope")
        XCTAssertEqual(AutomationTemplatePanels.key(template: "a", scope: .workbench(id: 3, name: "x", folder: "/x")),
                       "a|workbench:3")
    }
}
