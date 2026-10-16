import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerTestSupport

/// A CLI double answering by subcommand (`args[1]`); `hold` parks the named
/// subcommand until `release()`.
private final class TemplateRunner: CLIRunnerProtocol, @unchecked Sendable {
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

@MainActor
final class AutomationTemplateGalleryTests: XCTestCase {
    private var pool: DatabasePool!
    private var path = ""
    private var runner: TemplateRunner!

    override func setUp() async throws {
        try await super.setUp()
        (pool, path) = try TestDatabase.createPool()
        runner = TemplateRunner()
    }

    override func tearDown() async throws {
        runner.release()
        pool = nil
        TestDatabase.cleanup(path: path)
        try await super.tearDown()
    }

    private func makeViewModel() -> AutomationsViewModel {
        AutomationsViewModel(dbPool: pool, cli: AutomationsCLI(runner: runner)) { _ in }
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

    /// The shape `watchtower automations templates --json` prints (P6 part 2).
    private static let mailJSON = #"""
    [{"name":"new-mail-summary","title":"New mail summary","description":"Every morning.",
      "scope":"personal","trigger_text":"Weekdays 09:00","permissions":["reads mail"],"outputs":["inbox"],
      "files":["new-mail-summary"],"params":[],"notes":["Run it by hand until P4."]},
     {"name":"release-buttons","title":"Release buttons","description":"Buttons.","scope":"workbench",
      "trigger_text":"Button","permissions":[],"outputs":[],"files":["release","deploy-test"],"params":[],"notes":[]},
     {"name":"jira-state-report","title":"Jira state report","description":"Weekly.","scope":"personal",
      "trigger_text":"Mondays 09:00","permissions":["jira:read@<PROJECT>"],"outputs":["report"],
      "files":["jira-state-report"],"params":[{"key":"PROJECT","label":"Jira project key","example":"PAY"}],"notes":[]}]
    """#

    private static func ok(_ text: String) -> Result<Data, CLIRunnerError> { .success(Data(text.utf8)) }

    private func template(_ name: String = "new-mail-summary", scope: String = "personal") throws -> AutomationTemplate {
        let json = #"{"name":"\#(name)","title":"T","description":"D","scope":"\#(scope)","trigger_text":"x","permissions":[],"outputs":[]}"#
        return try JSONDecoder().decode(AutomationTemplate.self, from: Data(json.utf8))
    }

    func testDecodesTemplatesAndEmptyArray() async {
        runner.answer("templates", Self.ok(Self.mailJSON))
        let vm = makeViewModel()
        await vm.loadTemplates()
        XCTAssertEqual(vm.templates.map(\.name), ["new-mail-summary", "release-buttons", "jira-state-report"])
        XCTAssertEqual(vm.templates.map(\.scope), ["personal", "workbench", "personal"])
        XCTAssertEqual(vm.templates[0].permissions, ["reads mail"])
        XCTAssertEqual(vm.templates[0].notes, ["Run it by hand until P4."])
        XCTAssertEqual(vm.templates[2].params,
                       [AutomationTemplate.Param(key: "PROJECT", label: "Jira project key", example: "PAY")])
        XCTAssertEqual(AutomationTemplateGallery.paramLines(vm.templates[2]),
                       ["After installing, replace <PROJECT> (Jira project key, e.g. PAY) in the recipe."])
        XCTAssertEqual(AutomationTemplateGallery.paramLines(vm.templates[0]), [])
        XCTAssertEqual(AutomationTemplateGallery.summaryLine(vm.templates[0]), "Weekdays 09:00 · reads mail")
        XCTAssertEqual(AutomationTemplateGallery.summaryLine(vm.templates[1]), "Button")
        XCTAssertEqual(runner.invocations, [["automations", "templates", "--json"]])

        runner.answer("templates", Self.ok("[]"))
        await vm.loadTemplates()
        XCTAssertEqual(vm.templates, [])
        XCTAssertNil(vm.templatesError)
    }

    func testInstallPersonalArgs() async throws {
        runner.answer("install-template", Self.ok(#"{"automation_id":4,"path":"/x/a.md"}"#))
        let vm = makeViewModel()
        let installed = await vm.installTemplate(try template())
        XCTAssertTrue(installed)
        XCTAssertEqual(runner.invocations, [["automations", "install-template", "new-mail-summary", "--json"]])
    }

    func testInstallWorkbenchArgs() async throws {
        runner.answer("install-template", Self.ok(#"{"automation_id":4,"path":"/x/a.md"}"#))
        let vm = makeViewModel()
        await vm.installTemplate(try template("release-buttons", scope: "workbench"), workbenchID: 3)
        XCTAssertEqual(runner.invocations,
                       [["automations", "install-template", "release-buttons", "--workbench", "3", "--json"]])
    }

    func testInstallSelectsAndOpensForm() async throws {
        let id = try await pool.write { db in
            try TestDatabase.insertAutomation(db, slug: "new-mail-summary", approvalHash: "h1", confirmedHash: "")
        }
        runner.answer("install-template", Self.ok(#"{"automation_id":\#(id),"path":"/x/a.md"}"#))
        let vm = makeViewModel()
        await vm.installTemplate(try template())
        XCTAssertEqual(vm.selectedID, id)
        XCTAssertEqual(vm.pendingEditID, id)
        XCTAssertEqual(vm.items.map(\.id), [id])
        XCTAssertNil(vm.installError)
    }

    func testFailedInstallKeepsTheStderrAndOpensNothing() async throws {
        let refusal = "not installed: automation #3 already uses the slug new-mail-summary (/x/a.md); delete it first"
        runner.answer("install-template", .failure(.nonZeroExit(code: 1, stderr: refusal + "\n")))
        let vm = makeViewModel()
        let installed = await vm.installTemplate(try template())
        XCTAssertFalse(installed)
        XCTAssertEqual(vm.installError, refusal)
        XCTAssertNil(vm.pendingEditID)
        XCTAssertNil(vm.selectedID)
    }

    func testUnknownCommandShowsEmptyState() async {
        runner.answer("templates", .failure(.nonZeroExit(code: 1, stderr: "Error: unknown command \"templates\" for \"watchtower automations\"\n")))
        let vm = makeViewModel()
        await vm.loadTemplates()
        XCTAssertEqual(vm.templates, [])
        XCTAssertNil(vm.templatesError, "an unknown command is the empty gallery, not an error")
    }

    /// What a CLI older than P6 part 2 really prints: the parent command takes
    /// "templates" as an argument and refuses the flag.
    func testUnknownFlagFromAnOlderCLIShowsEmptyState() async {
        runner.answer("templates", .failure(.nonZeroExit(code: 1, stderr: "unknown flag: --json\n")))
        let vm = makeViewModel()
        await vm.loadTemplates()
        XCTAssertEqual(vm.templates, [])
        XCTAssertNil(vm.templatesError)
    }

    func testOtherTemplateFailureIsShown() async {
        runner.answer("templates", .failure(.nonZeroExit(code: 1, stderr: "database is locked\n")))
        let vm = makeViewModel()
        await vm.loadTemplates()
        XCTAssertEqual(vm.templatesError, "database is locked")
    }

    func testInstallSurvivesNavigation() async throws {
        let id = try await pool.write { db in try TestDatabase.insertAutomation(db, slug: "new-mail-summary") }
        runner.answer("install-template", Self.ok(#"{"automation_id":\#(id),"path":"/x/a.md"}"#))
        runner.hold("install-template")
        let vm = makeViewModel()
        vm.setTabVisible(true)

        let mail = try template()
        let task = Task { await vm.installTemplate(mail) }
        await waitUntil { self.runner.isHolding }
        XCTAssertEqual(vm.installingTemplate, "new-mail-summary")

        // The owner leaves the tab; the gallery sheet is gone.
        vm.setTabVisible(false)
        vm.select(nil)

        runner.release()
        _ = await task.value

        vm.setTabVisible(true)
        XCTAssertNil(vm.installingTemplate)
        XCTAssertEqual(vm.selectedID, id)
        XCTAssertEqual(vm.pendingEditID, id, "the form opens when the tab returns")
    }
}
