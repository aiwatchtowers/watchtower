import GRDB
import XCTest
@testable import WatchtowerCore
import WatchtowerTestSupport

/// A CLI double answering by subcommand (`args[1]`), recording each call and
/// what its `--file` held when it ran, optionally held at a gate.
private final class EditorRunner: CLIRunnerProtocol, @unchecked Sendable {
    typealias Handler = @Sendable ([String]) throws -> Data

    private let lock = NSLock()
    private var handlers: [String: Handler] = [:]
    private var recorded: [[String]] = []
    private var files: [String: String] = [:]
    private var heldSubcommand: String?
    private var gate: CheckedContinuation<Void, Never>?
    private var gateOpened = false

    var invocations: [[String]] { lock.withLock { recorded } }
    /// Subcommand → the `--file` (validate: the positional file) text at call time.
    var fileTexts: [String: String] { lock.withLock { files } }
    var isHolding: Bool { lock.withLock { gate != nil } }

    func on(_ subcommand: String, _ handler: @escaping Handler) {
        lock.withLock { handlers[subcommand] = handler }
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
        var path: String?
        if sub == "validate", args.count > 2 { path = args[2] }
        if let flag = args.firstIndex(of: "--file"), args.indices.contains(flag + 1) { path = args[flag + 1] }
        let text = path.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        let (handler, held) = lock.withLock {
            recorded.append(args)
            if let text { files[sub] = text }
            return (handlers[sub], heldSubcommand == sub)
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
        return try handler?(args) ?? Data()
    }
}

/// The debounce's wait: suspends until the test fires it (or tears down).
@MainActor
private final class TestSleeper {
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
final class AutomationEditorCenterTests: XCTestCase {
    private typealias Fixtures = AutomationEditFixtures

    private var runner: EditorRunner!
    private var tempDir: URL!
    private var grants: [AutomationToolGrant] = []
    private var refreshed: [Int64] = []
    private var sleeper: TestSleeper!

    override func setUp() async throws {
        try await super.setUp()
        sleeper = TestSleeper()
        runner = EditorRunner()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("editor-center-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        grants = []
        refreshed = []
        runner.on("show") { _ in try Fixtures.showJSON() }
    }

    override func tearDown() async throws {
        runner.release()
        sleeper.fire()
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    private func makeCenter(draftCache: (any DatabaseWriter)? = nil) -> AutomationEditorCenter {
        let sleeper: TestSleeper = sleeper
        let sleep: (Duration) async -> Void = { await sleeper.sleep($0) }
        return AutomationEditorCenter(
            cli: AutomationsCLI(runner: runner),
            grants: { [weak self] _ in self?.grants ?? [] },
            refresh: { [weak self] id in self?.refreshed.append(id) },
            draftCache: draftCache,
            tempDirectory: tempDir,
            sleep: sleep
        )
    }

    private var subcommands: [String] { runner.invocations.map { $0[1] } }

    /// The plan `check` put up, or a failure.
    private func checkedPlan(
        _ center: AutomationEditorCenter,
        _ key: Int64,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> AutomationSavePlan {
        await center.check(key)
        guard case let .review(plan) = center.saving[key] else {
            XCTFail("expected a checked plan, got \(String(describing: center.saving[key]))", file: file, line: line)
            throw CancellationError()
        }
        return plan
    }

    nonisolated private static func saveJSON(approval: String) -> Data {
        Data(#"{"automation_id":7,"path":"/acme/automations/digest.md","approval_hash":"\#(approval)","confirmed":true}"#.utf8)
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

    private func tempEntries() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
    }

    // MARK: - Save

    /// Review Focus 1: the save confirms exactly the hash `validate` returned
    /// for the bytes it then writes, and names the loaded file's content hash.
    func testSaveConfirmsTheValidatedHashOnly() async throws {
        runner.on("validate") { _ in try Fixtures.validateJSON(approval: "hv") }
        runner.on("save") { _ in Self.saveJSON(approval: "hv") }
        let center = makeCenter()
        await center.beginEdit(7, chatNewestText: nil)
        let form = try XCTUnwrap(center.drafts[7])
        form.fields.trigger = .schedule("0 16 * * 1-5")
        let text = form.renderedText()

        await center.check(7)
        guard case let .review(plan) = center.saving[7] else {
            return XCTFail("a changed hash is shown for review, got \(String(describing: center.saving[7]))")
        }
        XCTAssertFalse(runner.invocations.contains { $0[1] == "save" }, "nothing is written before the owner's press")
        await center.commit(7, plan: plan, turnOn: false)

        let save = try XCTUnwrap(runner.invocations.first { $0[1] == "save" })
        let confirmFlag = try XCTUnwrap(save.firstIndex(of: "--confirm-hash"))
        XCTAssertEqual(Array(save[confirmFlag...].prefix(4)), ["--confirm-hash", "hv", "--expect-content-hash", "c1"])
        let pathFlag = try XCTUnwrap(save.firstIndex(of: "--path"))
        XCTAssertEqual(save[pathFlag + 1], "/acme/automations/digest.md")
        XCTAssertEqual(runner.invocations.first { $0[1] == "validate" }?.suffix(3), ["--against", "7", "--json"])
        XCTAssertEqual(runner.fileTexts["validate"], text)
        XCTAssertEqual(runner.fileTexts["save"], text, "the saved bytes are the validated bytes")
        XCTAssertEqual(center.saving[7], .done)
        XCTAssertNil(center.drafts[7])
        XCTAssertEqual(refreshed, [7])
        XCTAssertEqual(try tempEntries(), [])
        XCTAssertEqual(center.savedIDs[7], 7)
    }

    /// A built-in's Save (C2): its on/off is its feature keys, so the save
    /// never runs `enable`/`disable`, whichever way the press asked.
    func testBuiltinSaveNeverTogglesEnabled() async throws {
        runner.on("validate") { _ in try Fixtures.validateJSON(approval: "hv") }
        runner.on("save") { _ in Self.saveJSON(approval: "hv") }
        let center = makeCenter()
        for turnOn in [false, true] {
            await center.beginEdit(7, chatNewestText: nil)
            let form = try XCTUnwrap(center.drafts[7])
            form.fields.trigger = .schedule(turnOn ? "0 16 * * 1-5" : "0 17 * * 1-5")
            let plan = try await checkedPlan(center, 7)
            await center.commit(7, plan: plan, turnOn: turnOn, setsEnabled: false)
            XCTAssertEqual(center.saving[7], .done, "turnOn \(turnOn)")
            center.discard(7)
        }
        XCTAssertEqual(subcommands.filter { $0 == "save" }.count, 2)
        XCTAssertFalse(subcommands.contains("enable") || subcommands.contains("disable"), "\(subcommands)")
    }

    /// A new personal draft: validated with no `--against`, saved at a slug
    /// made from its name into the automations directory, only where no file
    /// exists yet, confirmed by the owner's press.
    func testNewRecipeSavesAtItsSlugWithAnEmptyExpectedHash() async throws {
        runner.on("validate") { _ in try Fixtures.validateJSON(approval: "hn", name: "Morning Mail digest!") }
        runner.on("save") { _ in Self.saveJSON(approval: "hn") }
        let center = makeCenter()
        let key = AutomationEditorCenter.newDraftKey(conversationID: 5)
        center.beginNew(key: key, scope: .personal, recipeDir: "/acme/automations", startText: nil)
        let form = try XCTUnwrap(center.drafts[key])
        XCTAssertTrue(AutomationEditorCenter.isNewDraft(key))
        form.fields.name = "Morning Mail digest!"

        let plan = try await checkedPlan(center, key)
        await center.commit(key, plan: plan, turnOn: false)

        XCTAssertEqual(runner.invocations.first { $0[1] == "validate" }?.suffix(1), ["--json"])
        XCTAssertFalse(runner.invocations.first { $0[1] == "validate" }?.contains("--against") ?? true)
        XCTAssertFalse(runner.invocations.first { $0[1] == "validate" }?.contains("--workbench") ?? true)
        let save = try XCTUnwrap(runner.invocations.first { $0[1] == "save" })
        let pathFlag = try XCTUnwrap(save.firstIndex(of: "--path"))
        XCTAssertEqual(save[pathFlag + 1], "/acme/automations/morning-mail-digest.md")
        let hashFlag = try XCTUnwrap(save.firstIndex(of: "--expect-content-hash"))
        XCTAssertEqual(save[hashFlag + 1], "")
        let confirmFlag = try XCTUnwrap(save.firstIndex(of: "--confirm-hash"))
        XCTAssertEqual(save[confirmFlag + 1], "hn")
        XCTAssertEqual(center.saving[key], .done)
        XCTAssertEqual(refreshed, [7])
        XCTAssertFalse(runner.invocations.contains { $0[1] == "show" }, "a new recipe has nothing to load")
        XCTAssertFalse(runner.invocations.contains { $0[1] == "enable" }, "saved turned off")
    }

    func testNewRecipeNameClashSaysSo() async throws {
        runner.on("validate") { _ in try Fixtures.validateJSON(approval: "hn") }
        runner.on("save") { _ in
            throw CLIRunnerError.nonZeroExit(code: 1, stderr: "the recipe changed on disk since you opened it")
        }
        let center = makeCenter()
        let key = AutomationEditorCenter.newDraftKey(conversationID: 5)
        center.beginNew(key: key, scope: .personal, recipeDir: "/acme/automations", startText: nil)
        center.drafts[key]?.fields.name = "Digest"
        let plan = try await checkedPlan(center, key)
        await center.commit(key, plan: plan, turnOn: true)
        XCTAssertEqual(center.saving[key], .failed("A recipe named digest.md already exists — pick another name."))
        XCTAssertFalse(runner.invocations.contains { $0[1] == "enable" })
    }

    func testSlugForName() {
        XCTAssertEqual(AutomationEditorCenter.slug(forName: "Morning Mail digest!"), "morning-mail-digest")
        XCTAssertEqual(AutomationEditorCenter.slug(forName: "  --Q4 plan--  "), "q4-plan")
        XCTAssertEqual(AutomationEditorCenter.slug(forName: "Почта"), "automation")
        XCTAssertEqual(AutomationEditorCenter.slug(forName: String(repeating: "a", count: 80)).count, 64)
    }

    func testNameOnlyEditSavesOnPress() async throws {
        runner.on("validate") { _ in try Fixtures.validateJSON(approval: "h1") }
        runner.on("save") { _ in Self.saveJSON(approval: "h1") }
        let center = makeCenter()
        await center.beginEdit(7, chatNewestText: nil)
        center.drafts[7]?.fields.name = "Weekly digest"
        let plan = try await checkedPlan(center, 7)
        XCTAssertEqual(subcommands, ["show", "validate"], "nothing is saved before the press")
        await center.commit(7, plan: plan, turnOn: true)
        XCTAssertEqual(center.saving[7], .done)
        XCTAssertEqual(subcommands, ["show", "validate", "save", "enable"], "a turned-on save always enables")
    }

    /// Review Focus 4: no `auto … on` unless the owner checked a box, then one
    /// per checked box with the NEW hash.
    func testNoAutoOnWithoutACheckedBox() async throws {
        grants = [Fixtures.grant("create_jira_issue", hash: "h1"), Fixtures.grant("add_comment", hash: "h1")]
        runner.on("validate") { _ in try Fixtures.validateJSON(approval: "h2") }
        runner.on("save") { _ in Self.saveJSON(approval: "h2") }
        let center = makeCenter()

        await center.beginEdit(7, chatNewestText: nil)
        center.drafts[7]?.fields.budgetTokens = 120_000
        await center.check(7)
        guard case let .review(plan) = center.saving[7] else { return XCTFail("no plan") }
        XCTAssertEqual(plan.pausedGrants, ["add_comment", "create_jira_issue"])
        await center.commit(7, plan: plan, turnOn: false)
        XCTAssertFalse(runner.invocations.contains { $0[1] == "auto" })

        await center.beginEdit(7, chatNewestText: nil)
        center.drafts[7]?.fields.budgetTokens = 120_000
        await center.check(7)
        guard case var .review(second) = center.saving[7] else { return XCTFail("no plan") }
        second.keepAuto = ["create_jira_issue"]
        await center.commit(7, plan: second, turnOn: false)
        XCTAssertEqual(runner.invocations.filter { $0[1] == "auto" },
                       [["automations", "auto", "7", "create_jira_issue", "on", "--hash", "h2", "--json"]])
    }

    /// Review Focus 7: the save finishes in the center after the form is gone.
    func testSaveSurvivesNavigation() async throws {
        runner.on("validate") { _ in try Fixtures.validateJSON(approval: "h1") }
        runner.on("save") { _ in Self.saveJSON(approval: "h1") }
        runner.hold("save")
        let center = makeCenter()
        await center.beginEdit(7, chatNewestText: nil)
        center.drafts[7]?.fields.name = "Weekly digest"
        let plan = try await checkedPlan(center, 7)

        let task = Task { await center.commit(7, plan: plan, turnOn: true) }
        await waitUntil { self.runner.isHolding }
        XCTAssertEqual(center.saving[7], .saving)
        // The form view is gone: nothing holds the draft but the center.
        // Closing it (Discard on the way out) and reopening it mid-flight
        // drop neither the draft nor the save state.
        center.discard(7)
        XCTAssertNotNil(center.drafts[7], "a save in flight keeps its draft")
        XCTAssertEqual(center.saving[7], .saving)
        await center.beginEdit(7, chatNewestText: nil)
        XCTAssertEqual(center.saving[7], .saving, "reopening the form does not disturb a save in flight")
        runner.release()
        await task.value
        XCTAssertEqual(center.saving[7], .done)
        XCTAssertEqual(refreshed, [7])
    }

    /// Review Focus 1: the page's debounced last keystroke is pulled in before
    /// validate, so the validated and saved bytes are the ones on screen.
    func testSaveFlushesThePendingMonacoEdit() async throws {
        runner.on("validate") { _ in try Fixtures.validateJSON(approval: "h1") }
        runner.on("save") { _ in Self.saveJSON(approval: "h1") }
        let center = makeCenter()
        await center.beginEdit(7, chatNewestText: nil)
        let form = try XCTUnwrap(center.drafts[7])
        form.fields.name = "Weekly digest"
        let typed = form.renderedText().replacingOccurrences(of: "const a = 1;", with: "const a = 2;")
        form.buffer.flushPending = { [weak form] in
            guard let form else { return }
            form.buffer.pageSent(text: typed, base: form.buffer.revision)
        }
        let plan = try await checkedPlan(center, 7)
        await center.commit(7, plan: plan, turnOn: true)
        XCTAssertEqual(runner.fileTexts["validate"], typed)
        XCTAssertEqual(runner.fileTexts["save"], typed)
        XCTAssertEqual(center.saving[7], .done)
    }

    /// A save whose kept auto grant failed drops the draft but shows the
    /// failure (never an endless spinner) until the form is closed.
    func testAutoKeepFailureIsShownAfterTheDraftIsGone() async throws {
        grants = [Fixtures.grant("create_jira_issue", hash: "h1")]
        runner.on("validate") { _ in try Fixtures.validateJSON(approval: "h2") }
        runner.on("save") { _ in Self.saveJSON(approval: "h2") }
        runner.on("auto") { _ in throw CLIRunnerError.nonZeroExit(code: 1, stderr: "Error: not admitted\n") }
        let center = makeCenter()
        await center.beginEdit(7, chatNewestText: nil)
        center.drafts[7]?.fields.budgetTokens = 120_000
        var plan = try await checkedPlan(center, 7)
        plan.keepAuto = ["create_jira_issue"]
        await center.commit(7, plan: plan, turnOn: true)

        XCTAssertNil(center.drafts[7], "the recipe was saved")
        XCTAssertEqual(center.saving[7],
                       .failed("Saved, but auto could not be kept for create_jira_issue: Error: not admitted"),
                       "the panel shows the outcome")
        XCTAssertEqual(center.savedIDs[7], 7)
        center.discard(7)
        XCTAssertNil(center.saving[7], "closed")
    }

    func testTempFileRemovedOnFailure() async throws {
        runner.on("validate") { _ in throw CLIRunnerError.nonZeroExit(code: 1, stderr: "Error: boom\n") }
        let center = makeCenter()
        await center.beginEdit(7, chatNewestText: nil)
        await center.check(7)
        XCTAssertEqual(center.saving[7], .failed("Error: boom"))
        XCTAssertNotNil(runner.fileTexts["validate"], "the file existed while validate ran")
        XCTAssertEqual(try tempEntries(), [])

        runner.on("validate") { _ in try Fixtures.validateJSON(approval: "h1") }
        runner.on("save") { _ in throw CLIRunnerError.nonZeroExit(code: 1, stderr: "Error: disk full\n") }
        let plan = try await checkedPlan(center, 7)
        await center.commit(7, plan: plan, turnOn: true)
        XCTAssertEqual(center.saving[7], .failed("Error: disk full"))
        XCTAssertEqual(try tempEntries(), [])
    }

    func testInvalidRecipeIsNotSaved() async throws {
        runner.on("validate") { _ in try Fixtures.validateJSON(approval: "", ok: false, errors: ["line 3: bad cron"]) }
        let center = makeCenter()
        await center.beginEdit(7, chatNewestText: nil)
        await center.check(7)
        XCTAssertEqual(center.saving[7], .failed("The recipe has errors:\nline 3: bad cron"))
        XCTAssertFalse(center.canSave(7))
        XCTAssertFalse(runner.invocations.contains { $0[1] == "save" })
    }

    func testCheckKeepsItsResultForTheColumn() async throws {
        runner.on("validate") { _ in try Fixtures.validateJSON(approval: "", ok: false, errors: ["line 3: bad cron"]) }
        let center = makeCenter()
        await center.beginEdit(7, chatNewestText: nil)
        await center.check(7)
        // The column shows the errors of these bytes, not "Checking…".
        XCTAssertEqual(center.lastChecked[7]?.ok, false)
        XCTAssertEqual(center.lastChecked[7]?.errors, ["line 3: bad cron"])
        center.discard(7)
        XCTAssertNil(center.lastChecked[7])
    }

    func testChangedOnDiskSurfacesMessage() async throws {
        runner.on("validate") { _ in try Fixtures.validateJSON(approval: "h1") }
        runner.on("save") { _ in
            throw CLIRunnerError.nonZeroExit(code: 1, stderr: "Error: not saved: the recipe changed on disk since you "
                + "opened it (/acme/automations/digest.md) — reload it and review again\n")
        }
        let center = makeCenter()
        await center.beginEdit(7, chatNewestText: nil)
        center.drafts[7]?.fields.name = "Weekly digest"
        let plan = try await checkedPlan(center, 7)
        await center.commit(7, plan: plan, turnOn: true)
        guard case let .failed(message) = center.saving[7] else { return XCTFail("not failed") }
        XCTAssertTrue(message.hasPrefix("The recipe changed on disk since you opened it"), message)
        XCTAssertTrue(center.drafts[7]?.renderedText().contains("Weekly digest") ?? false, "the draft is kept")
    }

    /// J7: after "changed on disk", Reload brings in the file as it is now
    /// and keeps the owner's text aside — a retry is no longer refused forever.
    func testReloadAfterChangedOnDiskKeepsTheOwnersTextAside() async throws {
        runner.on("validate") { _ in try Fixtures.validateJSON(approval: "h1") }
        runner.on("save") { _ in
            throw CLIRunnerError.nonZeroExit(code: 1, stderr: "Error: not saved: the recipe changed on disk since you "
                + "opened it (/acme/automations/digest.md) — reload it and review again\n")
        }
        let center = makeCenter()
        await center.beginEdit(7, chatNewestText: nil)
        center.drafts[7]?.fields.name = "Weekly digest"
        let plan = try await checkedPlan(center, 7)
        await center.commit(7, plan: plan, turnOn: true)
        XCTAssertEqual(center.saving[7], .failed(AutomationEditorCenter.changedOnDisk))
        let typed = try XCTUnwrap(center.drafts[7]?.renderedText())

        runner.on("show") { _ in try Fixtures.showJSON(contentHash: "c9") }
        await center.reloadFromDisk(7)
        XCTAssertNil(center.saving[7])
        XCTAssertEqual(center.keptAside[7], typed, "the owner's text is kept aside")
        XCTAssertEqual(center.drafts[7]?.buffer.baseContentHash, "c9", "the file as it is now")
        XCTAssertFalse(center.drafts[7]?.buffer.isDirty ?? true)

        center.discard(7)
        XCTAssertNil(center.keptAside[7])
    }

    /// J10: `save --confirm-hash` refuses when the saved bytes no longer hash
    /// to the validated hash; the form shows it and keeps the draft.
    func testSaveHashMismatchIsRefusedAndKeepsTheDraft() async throws {
        runner.on("validate") { _ in try Fixtures.validateJSON(approval: "h1") }
        runner.on("save") { _ in
            throw CLIRunnerError.nonZeroExit(code: 1, stderr: "Error: not saved: the recipe's approval hash is h9, not "
                + "h1 — review it again: approval hash does not match\n")
        }
        let center = makeCenter()
        await center.beginEdit(7, chatNewestText: nil)
        center.drafts[7]?.fields.name = "Weekly digest"
        let plan = try await checkedPlan(center, 7)
        await center.commit(7, plan: plan, turnOn: true)
        guard case let .failed(message) = center.saving[7] else {
            return XCTFail("got \(String(describing: center.saving[7]))")
        }
        XCTAssertTrue(message.contains("approval hash does not match"), message)
        XCTAssertNotNil(center.drafts[7], "the draft is kept")
        XCTAssertFalse(runner.invocations.contains { $0[1] == "confirm" || $0[1] == "auto" })
    }

    /// J10, made stronger: text typed after the check is never saved under
    /// the hash validated for the earlier text — the press checks it again
    /// and saves nothing.
    func testTextTypedWhileTheSheetIsUpIsNotSavedUnderTheValidatedHash() async throws {
        runner.on("validate") { _ in try Fixtures.validateJSON(approval: "hv") }
        runner.on("save") { _ in Self.saveJSON(approval: "hv") }
        let center = makeCenter()
        await center.beginEdit(7, chatNewestText: nil)
        let form = try XCTUnwrap(center.drafts[7])
        form.fields.trigger = .schedule("0 16 * * 1-5")
        let validated = form.renderedText()
        let plan = try await checkedPlan(center, 7)

        form.fields.name = "Typed after the check"
        XCTAssertNotEqual(form.renderedText(), validated)
        XCTAssertFalse(center.canSave(7))
        await center.commit(7, plan: plan, turnOn: false)

        XCTAssertFalse(runner.invocations.contains { $0[1] == "save" }, "the old bytes' hash never saves the new text")
        XCTAssertEqual(runner.fileTexts["validate"], form.renderedText(), "the new text is checked again")
        switch center.saving[7] {
        case .validating: break
        case let .review(again): XCTAssertEqual(again.validated.approvalHash, "hv")
        default: XCTFail("expected a re-check, got \(String(describing: center.saving[7]))")
        }
        XCTAssertNotNil(center.drafts[7], "the draft is kept")
    }

    func testBeginEditKeepsAnUnsavedDraft() async throws {
        let center = makeCenter()
        await center.beginEdit(7, chatNewestText: nil)
        center.drafts[7]?.fields.name = "Unsaved"
        runner.on("show") { _ in try Fixtures.showJSON(contentHash: "c9") }
        await center.beginEdit(7, chatNewestText: nil)
        XCTAssertTrue(center.drafts[7]?.renderedText().contains("Unsaved") ?? false)
        XCTAssertEqual(runner.invocations.filter { $0[1] == "show" }.count, 1, "the file is not read over the edits")

        center.discard(7)
        await center.beginEdit(7, chatNewestText: nil)
        XCTAssertEqual(center.drafts[7]?.buffer.baseContentHash, "c9")
    }

    func testAutoToggleUsesTheLoadedHash() async {
        let center = makeCenter()
        await center.beginEdit(7, chatNewestText: nil)
        center.drafts[7]?.fields.name = "Unsaved"
        await center.setAuto(7, tool: "create_jira_issue", on: true)
        await center.setAuto(7, tool: "create_jira_issue", on: false)
        XCTAssertEqual(runner.invocations.filter { $0[1] == "auto" }, [
            ["automations", "auto", "7", "create_jira_issue", "on", "--hash", "h1", "--json"],
            ["automations", "auto", "7", "create_jira_issue", "off", "--json"]
        ])
        XCTAssertEqual(refreshed, [7, 7])

        runner.on("auto") { _ in throw CLIRunnerError.nonZeroExit(code: 1, stderr: "Error: always asks\n") }
        await center.setAuto(7, tool: "send_slack_message", on: true)
        XCTAssertEqual(center.autoErrors[7], "Error: always asks")
    }

    // MARK: - Check and save in place

    func testAuto06_SavePressAfterAnUnflushedEditRechecksInsteadOfSaving() async throws {
        runner.on("validate") { _ in try Fixtures.validateJSON(approval: "h2") }
        runner.on("save") { _ in Self.saveJSON(approval: "h2") }
        let center = makeCenter()
        await center.beginEdit(7, chatNewestText: nil)
        let form = try XCTUnwrap(center.drafts[7])
        form.fields.budgetTokens = 120_000
        let plan = try await checkedPlan(center, 7)
        XCTAssertTrue(center.canSave(7))

        let typed = form.renderedText().replacingOccurrences(of: "const a = 1;", with: "const a = 3;")
        form.buffer.flushPending = { [weak form] in
            guard let form else { return }
            form.buffer.pageSent(text: typed, base: form.buffer.revision)
        }
        await center.commit(7, plan: plan, turnOn: false)

        XCTAssertEqual(runner.invocations.filter { $0[1] == "save" }.count, 0, "the unflushed keystroke is not saved")
        XCTAssertEqual(runner.invocations.filter { $0[1] == "validate" }.count, 2, "one more check")
        XCTAssertEqual(runner.fileTexts["validate"], typed)
        XCTAssertFalse(runner.invocations.contains { $0[1] == "disable" }, "nothing is written before the bytes are checked")
    }

    func testAuto06_SaveDisabledWhileChecking() async throws {
        runner.on("validate") { _ in try Fixtures.validateJSON(approval: "h1") }
        runner.hold("validate")
        let center = makeCenter()
        await center.beginEdit(7, chatNewestText: nil)
        center.drafts[7]?.fields.name = "Weekly digest"
        center.textChanged(7)
        await waitUntil { self.sleeper.calls >= 2 }
        sleeper.fire()
        await waitUntil { self.runner.isHolding }
        XCTAssertEqual(center.saving[7], .validating)
        XCTAssertFalse(center.canSave(7))

        runner.release()
        await waitUntil {
            if case .review = center.saving[7] { return true }
            return false
        }
        XCTAssertTrue(center.canSave(7))

        center.drafts[7]?.fields.name = "Weekly digest, edited"
        XCTAssertFalse(center.canSave(7), "bytes changed since the check")
    }

    func testCheckIsDebounced() async throws {
        runner.on("validate") { _ in try Fixtures.validateJSON(approval: "h1") }
        let center = makeCenter()
        await center.beginEdit(7, chatNewestText: nil)
        center.textChanged(7)
        center.textChanged(7)
        center.textChanged(7)
        await waitUntil { self.sleeper.calls >= 4 }
        sleeper.fire()
        await waitUntil {
            if case .review = center.saving[7] { return true }
            return false
        }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(runner.invocations.filter { $0[1] == "validate" }.count, 1)
    }

    func testSaveAndTurnOnEnablesAfterTheConfirmedSave() async throws {
        runner.on("validate") { _ in try Fixtures.validateJSON(approval: "hn") }
        runner.on("save") { _ in Self.saveJSON(approval: "hn") }
        let cache = try TestDatabase.create()
        try await cache.write { db in
            try db.execute(sql: """
                INSERT INTO chat_conversations (id, title, context_type, context_id, created_at, updated_at)
                VALUES (42, 'New automation', 'automation_draft', 'd', 0, 0)
                """)
            try AutomationDraftCacheQueries.append(db, conversationID: 42, entryJSON: "{}", at: Date())
        }
        let center = makeCenter(draftCache: cache)
        let key = AutomationEditorCenter.newDraftKey(conversationID: 42)
        XCTAssertEqual(key, -42)
        XCTAssertTrue(AutomationEditorCenter.isNewDraft(key))
        XCTAssertFalse(AutomationEditorCenter.isNewDraft(7))

        center.beginNew(key: key, scope: .personal, recipeDir: "/acme/automations", startText: nil)
        let text = Fixtures.recipe.replacingOccurrences(of: "name: Digest", with: "name: Morning digest")
        center.adoptChatDraft(key, text: text, slug: "morning-digest")
        let plan = try await checkedPlan(center, key)
        await center.commit(key, plan: plan, turnOn: true)

        XCTAssertEqual(subcommands, ["validate", "save", "enable"])
        let save = try XCTUnwrap(runner.invocations.first { $0[1] == "save" })
        let pathFlag = try XCTUnwrap(save.firstIndex(of: "--path"))
        XCTAssertEqual(save[pathFlag + 1], "/acme/automations/morning-digest.md")
        let hashFlag = try XCTUnwrap(save.firstIndex(of: "--expect-content-hash"))
        XCTAssertEqual(save[hashFlag + 1], "")
        XCTAssertEqual(runner.fileTexts["save"], text)
        XCTAssertEqual(runner.invocations.last, ["automations", "enable", "7"])
        XCTAssertEqual(center.saving[key], .done)
        XCTAssertEqual(center.savedIDs[key], 7)
        let left = try await cache.read { try AutomationDraftCacheQueries.entries($0, conversationID: 42) }
        XCTAssertEqual(left, [], "the draft cache is removed")
    }

    func testNewWorkbenchDraftValidatesAndSavesInItsFolder() async throws {
        runner.on("validate") { _ in try Fixtures.validateJSON(approval: "hw", name: "Board sweep") }
        runner.on("save") { _ in Self.saveJSON(approval: "hw") }
        let center = makeCenter()
        let key = AutomationEditorCenter.newDraftKey(conversationID: 9)
        let scope = AutomationScopeChoice.workbench(id: 3, name: "acme", folder: "/acme")
        center.beginNew(key: key, scope: scope, recipeDir: scope.recipeDir(workspaceDir: "/workspace"),
                        startText: nil)
        let form = try XCTUnwrap(center.drafts[key])
        XCTAssertEqual(form.detail.scope, "workbench")
        XCTAssertEqual(form.detail.projectID, 3)
        form.fields.name = "Board sweep"

        let plan = try await checkedPlan(center, key)
        await center.commit(key, plan: plan, turnOn: false)

        let validate = try XCTUnwrap(runner.invocations.first { $0[1] == "validate" })
        XCTAssertEqual(validate.suffix(3), ["--workbench", "3", "--json"])
        XCTAssertFalse(validate.contains("--against"))
        let save = try XCTUnwrap(runner.invocations.first { $0[1] == "save" })
        let pathFlag = try XCTUnwrap(save.firstIndex(of: "--path"))
        XCTAssertEqual(save[pathFlag + 1], "/acme/.watchtower/automations/board-sweep.md")
    }

    func testEnableFailureAfterSaveSaysSoAndKeepsTheSave() async throws {
        runner.on("validate") { _ in try Fixtures.validateJSON(approval: "hn") }
        runner.on("save") { _ in Self.saveJSON(approval: "hn") }
        runner.on("enable") { _ in throw CLIRunnerError.nonZeroExit(code: 1, stderr: "Error: daemon busy\n") }
        let center = makeCenter()
        let key = AutomationEditorCenter.newDraftKey(conversationID: 42)
        center.beginNew(key: key, scope: .personal, recipeDir: "/acme/automations", startText: nil)
        let plan = try await checkedPlan(center, key)
        await center.commit(key, plan: plan, turnOn: true)

        XCTAssertEqual(center.saving[key], .failed("Saved and confirmed, but not turned on: Error: daemon busy"))
        XCTAssertTrue(refreshed.contains(7))
        XCTAssertNil(center.drafts[key], "the save stands")
        XCTAssertEqual(center.savedIDs[key], 7)

        runner.on("enable") { _ in Data() }
        let before = runner.invocations.count
        await center.retryTurnOn(key)
        XCTAssertEqual(Array(runner.invocations.dropFirst(before)), [["automations", "enable", "7"]])
        XCTAssertEqual(center.saving[key], .done)
    }

    /// Runs `commit` with `enable` held: the state seen while the turn-on is
    /// in flight, and at each refresh, is never `.done` before it fails.
    private func commitWithHeldEnable(
        _ center: AutomationEditorCenter, _ key: Int64, plan: AutomationSavePlan
    ) async -> [AutomationEditorCenter.SaveState?] {
        var seen: [AutomationEditorCenter.SaveState?] = []
        runner.on("enable") { _ in throw CLIRunnerError.nonZeroExit(code: 1, stderr: "Error: daemon busy\n") }
        runner.hold("enable")
        let commit = Task { await center.commit(key, plan: plan, turnOn: true) }
        await waitUntil { self.runner.isHolding }
        seen.append(center.saving[key])
        runner.release()
        await commit.value
        return seen
    }

    func testSaveAndTurnOnIsNotDoneBeforeAFailedTurnOn() async throws {
        runner.on("validate") { _ in try Fixtures.validateJSON(approval: "hn") }
        runner.on("save") { _ in Self.saveJSON(approval: "hn") }
        let center = makeCenter()
        let key = AutomationEditorCenter.newDraftKey(conversationID: 42)
        center.beginNew(key: key, scope: .personal, recipeDir: "/acme/automations", startText: nil)
        let plan = try await checkedPlan(center, key)
        let seen = await commitWithHeldEnable(center, key, plan: plan)

        XCTAssertEqual(seen, [.saving], "a panel watching for .done must not close during the turn-on")
        XCTAssertEqual(center.saving[key], .failed(AutomationEditorCenter.notTurnedOn("Error: daemon busy")))
        XCTAssertEqual(center.savedIDs[key], 7)
        XCTAssertTrue(center.turnOnPending.contains(key))

        runner.on("enable") { _ in Data() }
        await center.retryTurnOn(key)
        XCTAssertEqual(center.saving[key], .done)
        XCTAssertFalse(center.turnOnPending.contains(key))
    }

    func testSaveAndConfirmOnADisabledAutomationIsNotDoneBeforeAFailedTurnOn() async throws {
        runner.on("show") { _ in
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Fixtures.showJSON()) as? [String: Any])
            object["enabled"] = false
            return try JSONSerialization.data(withJSONObject: object)
        }
        runner.on("validate") { _ in try Fixtures.validateJSON(approval: "h2") }
        runner.on("save") { _ in Self.saveJSON(approval: "h2") }
        let center = makeCenter()
        await center.beginEdit(7, chatNewestText: nil)
        center.drafts[7]?.fields.name = "Weekly digest"
        let plan = try await checkedPlan(center, 7)
        let seen = await commitWithHeldEnable(center, 7, plan: plan)

        XCTAssertEqual(seen, [.saving])
        XCTAssertEqual(center.saving[7], .failed(AutomationEditorCenter.notTurnedOn("Error: daemon busy")))
        XCTAssertEqual(center.savedIDs[7], 7)
        XCTAssertTrue(center.turnOnPending.contains(7))
    }

    func testConfirmedButNotEnabledOffersTurnOn() async {
        runner.on("confirm") { _ in Data() }
        runner.on("enable") { _ in throw CLIRunnerError.nonZeroExit(code: 1, stderr: "Error: daemon busy\n") }
        let center = makeCenter()
        await center.confirmForeign(7, shownHash: "h2", enable: true)
        XCTAssertEqual(center.confirmations[7], .failed(AutomationEditorCenter.confirmedNotEnabled("Error: daemon busy")))
        XCTAssertTrue(center.turnOnPending.contains(7))

        runner.on("enable") { _ in Data() }
        let before = runner.invocations.count
        await center.retryTurnOn(7)
        XCTAssertEqual(Array(runner.invocations.dropFirst(before)), [["automations", "enable", "7"]], "enable only")
        XCTAssertEqual(center.confirmations[7], .done)
        XCTAssertFalse(center.turnOnPending.contains(7))
    }

    func testReloadSchedulesACheck() async throws {
        runner.on("validate") { _ in try Fixtures.validateJSON(approval: "h1") }
        let center = makeCenter()
        await center.beginEdit(7, chatNewestText: nil)
        await waitUntil { self.sleeper.calls >= 1 }
        sleeper.fire()
        await waitUntil {
            if case .review = center.saving[7] { return true }
            return false
        }
        await center.reloadFromDisk(7)
        XCTAssertNil(center.saving[7])
        // The reloaded text equals the old one: no edit would check it.
        await waitUntil { self.sleeper.calls >= 2 }
        sleeper.fire()
        await waitUntil {
            if case .review = center.saving[7] { return true }
            return false
        }
    }

    func testComposerPrefillIsClaimedOncePerDraft() {
        let center = makeCenter()
        XCTAssertTrue(center.claimComposerPrefill(-42))
        XCTAssertFalse(center.claimComposerPrefill(-42))
        center.discard(-42)
        XCTAssertTrue(center.claimComposerPrefill(-42), "a discarded draft starts over")
    }

    func testSaveTurnedOffOnAnEnabledAutomationDisablesBeforeSaving() async throws {
        runner.on("validate") { _ in try Fixtures.validateJSON(approval: "h2") }
        runner.on("save") { _ in Self.saveJSON(approval: "h2") }
        let center = makeCenter()
        await center.beginEdit(7, chatNewestText: nil)
        XCTAssertEqual(center.drafts[7]?.detail.enabled, true)
        center.drafts[7]?.fields.budgetTokens = 120_000
        let plan = try await checkedPlan(center, 7)
        await center.commit(7, plan: plan, turnOn: false)

        XCTAssertEqual(subcommands, ["show", "validate", "disable", "save"])
        XCTAssertEqual(runner.invocations[2], ["automations", "disable", "7"])
        XCTAssertFalse(subcommands.contains("enable"))
        XCTAssertEqual(center.saving[7], .done)
    }

    /// The draft's loaded `enabled` may be stale (turned on or off from the
    /// card since the panel opened): **Save Turned Off** always disables a
    /// saved automation first, and a turned-on save always enables after —
    /// both idempotent in Go.
    func testSaveTurnsOnOrOffWhateverTheLoadedEnabledSays() async throws {
        runner.on("validate") { _ in try Fixtures.validateJSON(approval: "h2") }
        runner.on("save") { _ in Self.saveJSON(approval: "h2") }
        for (loadedEnabled, turnOn) in [(true, true), (false, false)] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Fixtures.showJSON()) as? [String: Any])
            object["enabled"] = loadedEnabled
            let show = try JSONSerialization.data(withJSONObject: object)
            runner.on("show") { _ in show }
            let before = runner.invocations.count
            let center = makeCenter()
            await center.beginEdit(7, chatNewestText: nil)
            center.drafts[7]?.fields.budgetTokens = 120_000
            let plan = try await checkedPlan(center, 7)
            await center.commit(7, plan: plan, turnOn: turnOn)

            let calls = runner.invocations.dropFirst(before).map { $0[1] }
            let label = "loaded enabled=\(loadedEnabled), turnOn=\(turnOn)"
            if turnOn {
                XCTAssertEqual(calls, ["show", "validate", "save", "enable"], label)
            } else {
                XCTAssertEqual(calls, ["show", "validate", "disable", "save"], label)
            }
            XCTAssertEqual(center.saving[7], .done, label)
        }
    }

    /// A save that landed while its panel was away: settling drops its
    /// finished state, so the next Edit opens the editor, not the card.
    func testSettleUnwatchedDropsALandedSave() async throws {
        runner.on("validate") { _ in try Fixtures.validateJSON(approval: "h2") }
        runner.on("save") { _ in Self.saveJSON(approval: "h2") }
        let center = makeCenter()
        await center.beginEdit(7, chatNewestText: nil)
        center.drafts[7]?.fields.budgetTokens = 120_000
        let plan = try await checkedPlan(center, 7)
        await center.commit(7, plan: plan, turnOn: false)
        XCTAssertEqual(center.saving[7], .done)
        XCTAssertEqual(center.savedIDs[7], 7)

        center.settleUnwatched(7)
        XCTAssertNil(center.saving[7])
        XCTAssertNil(center.savedIDs[7])

        // A confirm that landed unwatched is dropped too.
        runner.on("confirm") { _ in Data() }
        await center.beginEdit(7, chatNewestText: nil)
        await center.confirmForeign(7, shownHash: "h1")
        XCTAssertEqual(center.confirmations[7], .done)
        center.settleUnwatched(7)
        XCTAssertNil(center.confirmations[7])
        XCTAssertNil(center.drafts[7])
    }

    // MARK: - Chat drafts

    func testChatDraftOverOwnerEditsKeepsThemAside() async throws {
        let center = makeCenter()
        await center.beginEdit(7, chatNewestText: nil)
        let form = try XCTUnwrap(center.drafts[7])
        let draftA = Fixtures.recipe.replacingOccurrences(of: "const a = 1;", with: "const a = 10;")
        let draftB = Fixtures.recipe.replacingOccurrences(of: "const a = 1;", with: "const a = 20;")

        center.adoptChatDraft(7, text: draftA, slug: nil)
        XCTAssertEqual(form.renderedText(), draftA)
        XCTAssertNil(center.keptAside[7], "nothing of the owner's was replaced")

        let owners = draftA.replacingOccurrences(of: "const a = 10;", with: "const a = 11;")
        form.buffer.pageSent(text: owners, base: form.buffer.revision)
        center.adoptChatDraft(7, text: draftB, slug: nil)
        XCTAssertEqual(form.renderedText(), draftB)
        XCTAssertEqual(center.keptAside[7], owners)
        XCTAssertEqual(center.asideReason[7], .assistantReplaced)

        center.restoreAside(7)
        XCTAssertEqual(form.renderedText(), owners)
        XCTAssertNil(center.keptAside[7])

        center.adoptChatDraft(7, text: draftB, slug: nil)
        XCTAssertEqual(form.renderedText(), owners, "the adopted text is not adopted again")
    }

    func testOpenDoesNotAdoptAnOldCachedDraft() async throws {
        let center = makeCenter()
        await center.beginEdit(7, chatNewestText: "old")
        let form = try XCTUnwrap(center.drafts[7])
        XCTAssertEqual(form.renderedText(), Fixtures.recipe, "the file as shown")
        center.adoptChatDraft(7, text: "old", slug: nil)
        XCTAssertEqual(form.renderedText(), Fixtures.recipe)
        XCTAssertFalse(form.buffer.isDirty)
        XCTAssertNil(center.keptAside[7])
    }

    /// An Inbox proposal's **Open Draft** on a saved automation: the file is
    /// loaded, then the proposed text replaces it — even when the chat's
    /// newest draft is that same text (it would otherwise count as adopted).
    func testOpenWithStartTextAdoptsItOverTheFile() async throws {
        let center = makeCenter()
        let proposed = Fixtures.recipe + "// proposed\n"
        await center.beginEdit(7, chatNewestText: proposed, startText: proposed)
        let form = try XCTUnwrap(center.drafts[7])
        XCTAssertEqual(form.renderedText(), proposed)
        XCTAssertNil(center.keptAside[7], "an unedited file is not kept aside")
    }

    /// The panel opens again (the tab came back) on the same Inbox
    /// proposal: the owner's edits since the first open are kept, never
    /// replaced by the proposal again.
    func testStartTextIsAdoptedOncePerDraft() async throws {
        let center = makeCenter()
        let proposed = Fixtures.recipe + "// proposed\n"
        await center.beginEdit(7, chatNewestText: nil, startText: proposed)
        let form = try XCTUnwrap(center.drafts[7])
        let owners = proposed + "// owner\n"
        form.buffer.pageSent(text: owners, base: form.buffer.revision)

        await center.beginEdit(7, chatNewestText: nil, startText: proposed)
        XCTAssertTrue(center.drafts[7] === form)
        XCTAssertEqual(form.renderedText(), owners)
        XCTAssertNil(center.keptAside[7])

        center.discard(7)
        await center.beginEdit(7, chatNewestText: nil, startText: proposed)
        XCTAssertEqual(center.drafts[7]?.renderedText(), proposed, "a discarded draft starts over")
    }

    /// A **Reload** aside (the owner's text before the reload) is not
    /// replaced by a later assistant aside.
    func testReloadAsideIsNotOverwrittenByTheAssistant() async throws {
        let center = makeCenter()
        await center.beginEdit(7, chatNewestText: nil)
        var form = try XCTUnwrap(center.drafts[7])
        let owners = Fixtures.recipe + "// owner\n"
        form.buffer.pageSent(text: owners, base: form.buffer.revision)
        await center.reloadFromDisk(7)
        XCTAssertEqual(center.keptAside[7], owners)
        XCTAssertEqual(center.asideReason[7], .reloadedFromDisk)

        form = try XCTUnwrap(center.drafts[7])
        form.buffer.pageSent(text: Fixtures.recipe + "// again\n", base: form.buffer.revision)
        center.adoptChatDraft(7, text: Fixtures.recipe + "// assistant\n", slug: nil)
        XCTAssertEqual(form.renderedText(), Fixtures.recipe + "// assistant\n")
        XCTAssertEqual(center.keptAside[7], owners)
        XCTAssertEqual(center.asideReason[7], .reloadedFromDisk)
    }

    func testConfirmShownPassesTheValidatedHash() async throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Fixtures.showJSON(confirmed: "")) as? [String: Any])
        object["enabled"] = false
        let show = try JSONSerialization.data(withJSONObject: object)
        runner.on("show") { _ in show }
        runner.on("validate") { _ in try Fixtures.validateJSON(approval: "h1") }
        let center = makeCenter()
        await center.beginEdit(7, chatNewestText: nil)
        let plan = try await checkedPlan(center, 7)
        await center.confirmShown(7, plan: plan, turnOn: true)
        XCTAssertEqual(runner.invocations.suffix(2),
                       [["automations", "confirm", "7", "--hash", "h1"], ["automations", "enable", "7"]])
        XCTAssertFalse(subcommands.contains("save"), "unchanged bytes are confirmed, not saved")
        XCTAssertEqual(center.confirmations[7], .done)
    }

    // MARK: - Confirm

    func testAuto06_ConfirmSheetPassesTheShownHash() async {
        let center = makeCenter()
        await center.confirmForeign(7, shownHash: "abc123")
        XCTAssertEqual(runner.invocations, [["automations", "confirm", "7", "--hash", "abc123"]])
        XCTAssertEqual(center.confirmations[7], .done)
        XCTAssertEqual(refreshed, [7])

        await center.confirmForeign(8, shownHash: "def456", enable: true)
        XCTAssertEqual(runner.invocations.suffix(2),
                       [["automations", "confirm", "8", "--hash", "def456"], ["automations", "enable", "8"]])
    }

    func testStaleConfirmReloads() async {
        runner.on("confirm") { _ in
            throw CLIRunnerError.nonZeroExit(code: 1, stderr: "Error: approval hash does not match the recipe — the "
                + "recipe changed since you reviewed it; check it again with `watchtower automations show 7`\n")
        }
        let center = makeCenter()
        await center.confirmForeign(7, shownHash: "old", enable: true)
        XCTAssertEqual(center.confirmations[7], .stale("The recipe changed again — review it once more."))
        XCTAssertEqual(refreshed, [7], "the sheet's detail is read again")
        XCTAssertFalse(runner.invocations.contains { $0[1] == "enable" })
    }

    func testAuto06_ConfirmSheetShowsHashedFieldChanges() {
        let changes = [
            AutomationChange(field: "trigger", old: #"{"schedule":"0 16 * * 5"}"#, new: #"{"schedule":"0 16 * * 1-5"}"#),
            AutomationChange(field: "missed", old: "run_once", new: "skip"),
            AutomationChange(field: "budget_tokens", old: "50000", new: "120000"),
            AutomationChange(field: "budget_minutes", old: "5", new: "10"),
            AutomationChange(field: "concurrency", old: "1", new: "2"),
            AutomationChange(field: "outputs", old: #"["report"]"#, new: #"["inbox","report"]"#),
            AutomationChange(field: "script", old: "", new: "")
        ]
        XCTAssertEqual(AutomationChangePresentation.lines(changes, known: true, confirmedBefore: true), [
            "Schedule Fridays 16:00 → Weekdays 16:00",
            "Missed while asleep run once → skip",
            "Budget per run 50,000 tokens → 120,000 tokens",
            "Budget per run 5 minutes → 10 minutes",
            "Runs at a time 1 → 2",
            "Outputs report → inbox, report",
            "Script changed"
        ])
        XCTAssertEqual(
            AutomationChangePresentation.lines([AutomationChange(field: "trigger", old: #"{"button":{"confirm":false}}"#,
                                                                 new: #"{"button":{"confirm":true}}"#)],
                                               known: true, confirmedBefore: true),
            ["Runs Button → Button, asks before running"]
        )
    }

    func testConfirmSheetUnknownChangesSaysSo() {
        XCTAssertEqual(AutomationChangePresentation.lines([], known: false, confirmedBefore: true),
                       ["What changed is not known — review the whole recipe"])
        XCTAssertEqual(AutomationChangePresentation.lines([], known: false, confirmedBefore: false),
                       ["First confirmation"])
    }
}
