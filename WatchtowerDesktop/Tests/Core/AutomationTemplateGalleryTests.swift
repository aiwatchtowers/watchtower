import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerTestSupport

/// A CLI double answering by subcommand (`args[1]`), recording each call.
private final class TemplateRunner: CLIRunnerProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: Result<Data, CLIRunnerError>] = [:]
    private var recorded: [[String]] = []

    var invocations: [[String]] { lock.withLock { recorded } }

    func answer(_ subcommand: String, _ result: Result<Data, CLIRunnerError>) {
        lock.withLock { answers[subcommand] = result }
    }

    /// The texts that ride stdin (`--text-file -`, `validate -`, #604 S6)
    /// change nothing here.
    func run(args: [String], stdin _: Data) async throws -> Data {
        try await run(args: args)
    }

    func run(args: [String]) async throws -> Data {
        let sub = args.count > 1 ? args[1] : ""
        let answer = lock.withLock { () -> Result<Data, CLIRunnerError>? in
            recorded.append(args)
            return answers[sub]
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
        pool = nil
        TestDatabase.cleanup(path: path)
        try await super.tearDown()
    }

    private func makeViewModel() -> AutomationsViewModel {
        AutomationsViewModel(dbPool: pool, cli: AutomationsCLI(runner: runner)) { _ in }
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
        XCTAssertEqual(AutomationTemplateGallery.summaryLine(vm.templates[0]), "Weekdays 09:00 · reads mail")
        XCTAssertEqual(AutomationTemplateGallery.summaryLine(vm.templates[1]), "Button")
        XCTAssertEqual(runner.invocations, [["automations", "templates", "--json"]])

        runner.answer("templates", Self.ok("[]"))
        await vm.loadTemplates()
        XCTAssertEqual(vm.templates, [])
        XCTAssertNil(vm.templatesError)
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
}
