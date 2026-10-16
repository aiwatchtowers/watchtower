import XCTest
@testable import WatchtowerCore

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

@MainActor
final class AutomationEditorCenterTests: XCTestCase {
    private typealias Fixtures = AutomationEditFixtures

    private var runner: EditorRunner!
    private var tempDir: URL!
    private var grants: [AutomationToolGrant] = []
    private var refreshed: [Int64] = []

    override func setUp() async throws {
        try await super.setUp()
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
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    private func makeCenter() -> AutomationEditorCenter {
        AutomationEditorCenter(
            cli: AutomationsCLI(runner: runner),
            grants: { [weak self] _ in self?.grants ?? [] },
            refresh: { [weak self] id in self?.refreshed.append(id) },
            tempDirectory: tempDir
        )
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
        await center.beginEdit(7)
        let form = try XCTUnwrap(center.drafts[7]?.form)
        form.fields.trigger = .schedule("0 16 * * 1-5")
        let text = form.renderedText()

        await center.save(7)
        guard case let .review(plan) = center.saving[7] else {
            return XCTFail("a changed hash puts the Save sheet up, got \(String(describing: center.saving[7]))")
        }
        XCTAssertFalse(runner.invocations.contains { $0[1] == "save" }, "nothing is written before the sheet")
        await center.commit(7, plan: plan)

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
    }

    func testQuietSaveSavesInTheSameGesture() async throws {
        runner.on("validate") { _ in try Fixtures.validateJSON(approval: "h1") }
        runner.on("save") { _ in Self.saveJSON(approval: "h1") }
        let center = makeCenter()
        await center.beginEdit(7)
        center.drafts[7]?.form.fields.name = "Weekly digest"
        await center.save(7)
        XCTAssertEqual(center.saving[7], .done)
        XCTAssertEqual(runner.invocations.map { $0[1] }, ["show", "validate", "save"])
    }

    /// Review Focus 4: no `auto … on` unless the owner checked a box, then one
    /// per checked box with the NEW hash.
    func testNoAutoOnWithoutACheckedBox() async throws {
        grants = [Fixtures.grant("create_jira_issue", hash: "h1"), Fixtures.grant("add_comment", hash: "h1")]
        runner.on("validate") { _ in try Fixtures.validateJSON(approval: "h2") }
        runner.on("save") { _ in Self.saveJSON(approval: "h2") }
        let center = makeCenter()

        await center.beginEdit(7)
        center.drafts[7]?.form.fields.budgetTokens = 120_000
        await center.save(7)
        guard case let .review(plan) = center.saving[7] else { return XCTFail("no sheet") }
        XCTAssertEqual(plan.pausedGrants, ["add_comment", "create_jira_issue"])
        await center.commit(7, plan: plan)
        XCTAssertFalse(runner.invocations.contains { $0[1] == "auto" })

        await center.beginEdit(7)
        center.drafts[7]?.form.fields.budgetTokens = 120_000
        await center.save(7)
        guard case var .review(second) = center.saving[7] else { return XCTFail("no sheet") }
        second.keepAuto = ["create_jira_issue"]
        await center.commit(7, plan: second)
        XCTAssertEqual(runner.invocations.filter { $0[1] == "auto" },
                       [["automations", "auto", "7", "create_jira_issue", "on", "--hash", "h2", "--json"]])
    }

    /// Review Focus 7: the save finishes in the center after the form is gone.
    func testSaveSurvivesNavigation() async throws {
        runner.on("validate") { _ in try Fixtures.validateJSON(approval: "h1") }
        runner.on("save") { _ in Self.saveJSON(approval: "h1") }
        runner.hold("save")
        let center = makeCenter()
        await center.beginEdit(7)
        center.drafts[7]?.form.fields.name = "Weekly digest"

        let task = Task { await center.save(7) }
        await waitUntil { self.runner.isHolding }
        XCTAssertEqual(center.saving[7], .saving)
        // The form view is gone: nothing holds the draft but the center.
        await center.beginEdit(7)
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
        await center.beginEdit(7)
        let form = try XCTUnwrap(center.drafts[7]?.form)
        form.fields.name = "Weekly digest"
        let typed = form.renderedText().replacingOccurrences(of: "const a = 1;", with: "const a = 2;")
        form.buffer.flushPending = { [weak form] in
            guard let form else { return }
            form.buffer.pageSent(text: typed, base: form.buffer.revision)
        }
        await center.save(7)
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
        await center.beginEdit(7)
        center.drafts[7]?.form.fields.budgetTokens = 120_000
        await center.save(7)
        guard case var .review(plan) = center.saving[7] else { return XCTFail("no sheet") }
        plan.keepAuto = ["create_jira_issue"]
        await center.commit(7, plan: plan)

        XCTAssertNil(center.drafts[7], "the recipe was saved")
        guard case let .finished(message) = center.formContent(7) else {
            return XCTFail("the form shows the outcome, got \(center.formContent(7))")
        }
        XCTAssertEqual(message, "Saved, but auto could not be kept for create_jira_issue: Error: not admitted")
        center.discard(7)
        guard case .loading = center.formContent(7) else { return XCTFail("closed") }
    }

    func testTempFileRemovedOnFailure() async throws {
        runner.on("validate") { _ in throw CLIRunnerError.nonZeroExit(code: 1, stderr: "Error: boom\n") }
        let center = makeCenter()
        await center.beginEdit(7)
        await center.save(7)
        XCTAssertEqual(center.saving[7], .failed("Error: boom"))
        XCTAssertNotNil(runner.fileTexts["validate"], "the file existed while validate ran")
        XCTAssertEqual(try tempEntries(), [])

        runner.on("validate") { _ in try Fixtures.validateJSON(approval: "h1") }
        runner.on("save") { _ in throw CLIRunnerError.nonZeroExit(code: 1, stderr: "Error: disk full\n") }
        await center.save(7)
        XCTAssertEqual(center.saving[7], .failed("Error: disk full"))
        XCTAssertEqual(try tempEntries(), [])
    }

    func testInvalidRecipeIsNotSaved() async throws {
        runner.on("validate") { _ in try Fixtures.validateJSON(approval: "", ok: false, errors: ["line 3: bad cron"]) }
        let center = makeCenter()
        await center.beginEdit(7)
        await center.save(7)
        XCTAssertEqual(center.saving[7], .failed("The recipe has errors:\nline 3: bad cron"))
        XCTAssertFalse(runner.invocations.contains { $0[1] == "save" })
    }

    func testChangedOnDiskSurfacesMessage() async throws {
        runner.on("validate") { _ in try Fixtures.validateJSON(approval: "h1") }
        runner.on("save") { _ in
            throw CLIRunnerError.nonZeroExit(code: 1, stderr: "Error: not saved: the recipe changed on disk since you "
                + "opened it (/acme/automations/digest.md) — reload it and review again\n")
        }
        let center = makeCenter()
        await center.beginEdit(7)
        center.drafts[7]?.form.fields.name = "Weekly digest"
        await center.save(7)
        guard case let .failed(message) = center.saving[7] else { return XCTFail("not failed") }
        XCTAssertTrue(message.hasPrefix("The recipe changed on disk since you opened it"), message)
        XCTAssertTrue(center.drafts[7]?.form.renderedText().contains("Weekly digest") ?? false, "the draft is kept")
    }

    func testBeginEditKeepsAnUnsavedDraft() async throws {
        let center = makeCenter()
        await center.beginEdit(7)
        center.drafts[7]?.form.fields.name = "Unsaved"
        runner.on("show") { _ in try Fixtures.showJSON(contentHash: "c9") }
        await center.beginEdit(7)
        XCTAssertTrue(center.drafts[7]?.form.renderedText().contains("Unsaved") ?? false)
        XCTAssertEqual(runner.invocations.filter { $0[1] == "show" }.count, 1, "the file is not read over the edits")

        center.discard(7)
        await center.beginEdit(7)
        XCTAssertEqual(center.drafts[7]?.form.buffer.baseContentHash, "c9")
    }

    func testAutoToggleUsesTheLoadedHash() async {
        let center = makeCenter()
        await center.beginEdit(7)
        center.drafts[7]?.form.fields.name = "Unsaved"
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

    func testConfirmSheetAuthorLine() {
        let now = Date(timeIntervalSince1970: 1_792_152_000)
        let tenMinutesAgo = now.addingTimeInterval(-600)
        XCTAssertEqual(AutomationChangePresentation.authorLine(changedBy: "assistant", changedAt: tenMinutesAgo, now: now),
                       "Changed by the assistant in the chat · 10 min ago")
        XCTAssertEqual(AutomationChangePresentation.authorLine(changedBy: "", changedAt: tenMinutesAgo, now: now),
                       "Changed outside Watchtower · 10 min ago")
        XCTAssertEqual(AutomationChangePresentation.authorLine(changedBy: "", changedAt: nil, now: now),
                       "Changed outside Watchtower")
    }
}
