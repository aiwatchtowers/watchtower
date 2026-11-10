import XCTest
import WatchtowerCore

/// Report a Problem sheet state (#1527): the diagnostics run, the Open /
/// Copy / Save rules and the clipboard rule, over a fake CLI, opener,
/// pasteboard and writer.
@MainActor
final class ReportProblemModelTests: XCTestCase {
    /// Stands in for the CLI. With `gate` set, each run waits until the test
    /// calls `release(_:)` (or the awaiting task is cancelled).
    private final class FakeRunner: CLIRunnerProtocol, @unchecked Sendable {
        enum Outcome {
            case answer(Data)
            case failure(Error)
        }

        private let lock = NSLock()
        private var outcome: Outcome
        private var pending: [CheckedContinuation<Outcome, Never>] = []
        private(set) var calls: [[String]] = []
        private(set) var timeouts: [TimeInterval] = []
        private(set) var cancelled = 0
        let gated: Bool
        /// A gated run that keeps waiting for `release(_:)` after a cancel,
        /// like a child that answers before it is terminated.
        let ignoresCancel: Bool

        init(_ outcome: Outcome, gated: Bool = false, ignoresCancel: Bool = false) {
            self.outcome = outcome
            self.gated = gated
            self.ignoresCancel = ignoresCancel
        }

        func run(args: [String]) async throws -> Data {
            XCTFail("the model must pass a timeout")
            return Data()
        }

        func run(args: [String], timeout: TimeInterval) async throws -> Data {
            let outcome: Outcome = lock.withLock {
                calls.append(args)
                timeouts.append(timeout)
                return self.outcome
            }
            let result: Outcome
            if gated {
                result = await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in
                        lock.withLock { pending.append(continuation) }
                    }
                } onCancel: {
                    lock.withLock {
                        cancelled += 1
                        guard !ignoresCancel else { return }
                        pending.forEach { $0.resume(returning: .failure(CancellationError())) }
                        pending = []
                    }
                }
            } else {
                result = outcome
            }
            switch result {
            case .answer(let data): return data
            case .failure(let error): throw error
            }
        }

        var runCount: Int { lock.withLock { calls.count } }
        var cancelCount: Int { lock.withLock { cancelled } }

        func release(_ outcome: Outcome) {
            let waiting = lock.withLock {
                let waiting = pending
                pending = []
                return waiting
            }
            waiting.forEach { $0.resume(returning: outcome) }
        }

        /// Spins the main actor until the run reached the gate.
        func waitUntilWaiting() async {
            for _ in 0..<1_000 where lock.withLock({ pending.isEmpty }) {
                await Task.yield()
            }
        }
    }

    private enum Fixture {
        static let answer = DiagnosticsAnswer(
            text: "Watchtower 0.27.0 (default)\nmacOS 15.5 · Apple M3\nDatabase: ok",
            version: "0.27.0",
            macos: "15.5",
            chip: "Apple M3",
            provider: "Claude",
            flavor: "default",
            sources: ["slack"],
            partial: false
        )

        static func json(_ answer: DiagnosticsAnswer = answer) -> Data {
            let object: [String: Any] = [
                "text": answer.text, "version": answer.version, "macos": answer.macos,
                "chip": answer.chip, "provider": answer.provider, "flavor": answer.flavor,
                "sources": answer.sources, "partial": answer.partial
            ]
            // swiftlint:disable:next force_try
            return try! JSONSerialization.data(withJSONObject: object)
        }
    }

    private struct WriteFailure: LocalizedError {
        var errorDescription: String? { "The disk is full." }
    }

    private var opened: [URL] = []
    private var openResult = true
    private var pasteboard: [String] = []
    private var written: [(String, URL)] = []
    private var writeError: Error?

    override func setUp() {
        super.setUp()
        opened = []
        openResult = true
        pasteboard = []
        written = []
        writeError = nil
    }

    private func makeModel(
        _ runner: FakeRunner,
        iPhoneOn: Bool = false,
        isCorp: Bool = false
    ) -> ReportProblemModel {
        ReportProblemModel(
            runner: runner,
            appVersion: "0.27.0",
            macOS: "15.5",
            iPhoneOn: iPhoneOn,
            isCorp: isCorp,
            openURL: { [weak self] url in
                self?.opened.append(url)
                return self?.openResult ?? false
            },
            writePasteboard: { [weak self] in self?.pasteboard.append($0) },
            writeFile: { [weak self] text, url in
                if let writeError = self?.writeError { throw writeError }
                self?.written.append((text, url))
            }
        )
    }

    private func collected(
        _ outcome: FakeRunner.Outcome,
        isCorp: Bool = false
    ) async -> (ReportProblemModel, FakeRunner) {
        let runner = FakeRunner(outcome)
        let model = makeModel(runner, isCorp: isCorp)
        model.start()
        await model.collection?.value
        return (model, runner)
    }

    // MARK: - Collection

    func testDiagnosticsArguments() async {
        for (iPhoneOn, flag) in [(true, "on"), (false, "off")] {
            let runner = FakeRunner(.answer(Fixture.json()))
            let model = makeModel(runner, iPhoneOn: iPhoneOn)
            model.start()
            await model.collection?.value
            XCTAssertEqual(runner.calls, [["diagnostics", "--json", "--app-version", "0.27.0", "--iphone", flag]])
            XCTAssertEqual(runner.timeouts, [10])
        }
    }

    func testReadyShowsCLIText() async {
        let (model, _) = await collected(.answer(Fixture.json()))
        XCTAssertEqual(model.phase, .ready(Fixture.answer))
        XCTAssertEqual(model.diagnosticsText, Fixture.answer.text)
        XCTAssertTrue(model.canSave)
    }

    func testMissingCLI() async {
        for error: Error in [CLIRunnerError.binaryNotFound, CLIRunnerError.launchFailed(underlying: CocoaError(.fileNoSuchFile))] {
            let (model, _) = await collected(.failure(error))
            XCTAssertEqual(model.phase, .failed(.missing))
            XCTAssertEqual(model.diagnosticsText, "Watchtower app 0.27.0\nmacOS 15.5")
            XCTAssertTrue(model.canSave)
        }
    }

    func testTimeoutShowsRetry() async {
        let (model, runner) = await collected(.failure(CLIRunnerError.nonZeroExit(code: -1, stderr: "timed out")))
        XCTAssertEqual(model.phase, .failed(.timedOut))
        model.retry()
        XCTAssertEqual(model.phase, .collecting)
        await model.collection?.value
        XCTAssertEqual(runner.runCount, 2)
    }

    func testNonZeroExit() async {
        let (model, _) = await collected(.failure(CLIRunnerError.nonZeroExit(code: 3, stderr: "")))
        XCTAssertEqual(model.phase, .failed(.exit(3)))
    }

    func testUndecodableJSON() async {
        let (model, _) = await collected(.answer(Data("not json\n".utf8)))
        XCTAssertEqual(model.phase, .failed(.unreadable))
    }

    func testBusyDatabaseLinesShown() async {
        let busy = DiagnosticsAnswer(
            text: "Database: unknown (database busy)", version: "0.27.0", macos: "15.5",
            chip: "Apple M3", provider: "Claude", flavor: "default", sources: [], partial: true
        )
        let (model, _) = await collected(.answer(Fixture.json(busy)))
        XCTAssertEqual(model.phase, .ready(busy))
        XCTAssertEqual(model.diagnosticsText, busy.text)
    }

    func testRetryWhileCollectingRunsOnce() async {
        let runner = FakeRunner(.answer(Fixture.json()), gated: true)
        let model = makeModel(runner)
        model.start()
        await runner.waitUntilWaiting()
        model.retry()
        model.retry()
        model.start()
        XCTAssertEqual(runner.runCount, 1)
        runner.release(.failure(CLIRunnerError.nonZeroExit(code: 3, stderr: "")))
        await model.collection?.value
        XCTAssertEqual(model.phase, .failed(.exit(3)))

        // From failed, two presses still start one run.
        model.retry()
        model.retry()
        await runner.waitUntilWaiting()
        XCTAssertEqual(runner.runCount, 2)
        runner.release(.answer(Fixture.json()))
        await model.collection?.value
        XCTAssertEqual(model.phase, .ready(Fixture.answer))

        // A ready model does not collect again (a re-open of the sheet).
        model.start()
        model.retry()
        XCTAssertEqual(runner.runCount, 2)
    }

    func testCancelWhileCollectingTerminates() async {
        let runner = FakeRunner(.answer(Fixture.json()), gated: true)
        let model = makeModel(runner)
        model.text = "It crashed."
        model.start()
        await runner.waitUntilWaiting()
        let task = model.collection
        model.cancel()
        await task?.value
        XCTAssertEqual(runner.cancelCount, 1)
        XCTAssertNil(model.collection)
        XCTAssertEqual(model.phase, .collecting)
        XCTAssertTrue(written.isEmpty)
        XCTAssertTrue(pasteboard.isEmpty)
        XCTAssertTrue(opened.isEmpty)
    }

    func testAnswerAfterCancelChangesNothing() async {
        let runner = FakeRunner(.answer(Fixture.json()), gated: true, ignoresCancel: true)
        let model = makeModel(runner)
        model.text = "It crashed."
        model.start()
        await runner.waitUntilWaiting()
        let task = model.collection
        model.cancel()
        XCTAssertEqual(runner.cancelCount, 1)
        runner.release(.answer(Fixture.json()))
        await task?.value
        XCTAssertEqual(model.phase, .collecting)
        XCTAssertNil(model.collection)
        XCTAssertEqual(model.notice, .none)
        XCTAssertEqual(model.diagnosticsText, "")
        XCTAssertTrue(written.isEmpty)
        XCTAssertTrue(pasteboard.isEmpty)
        XCTAssertTrue(opened.isEmpty)
    }

    func testRunnerCancellationWithoutCancelFails() async {
        let (model, runner) = await collected(.failure(CancellationError()))
        XCTAssertEqual(model.phase, .failed(.unreadable))
        XCTAssertNil(model.collection)
        model.retry()
        await model.collection?.value
        XCTAssertEqual(runner.runCount, 2)
    }

    // MARK: - Open GitHub Issue

    func testOpenNeedsTextInEveryState() async {
        let gatedRunner = FakeRunner(.answer(Fixture.json()), gated: true)
        let collecting = makeModel(gatedRunner)
        collecting.start()
        await gatedRunner.waitUntilWaiting()
        let (ready, _) = await collected(.answer(Fixture.json()))
        let (failed, _) = await collected(.failure(CLIRunnerError.binaryNotFound))

        for (name, model, openWithText) in [("collecting", collecting, false), ("ready", ready, true), ("failed", failed, true)] {
            model.text = ""
            XCTAssertFalse(model.canOpen, "\(name), empty")
            model.text = "The sync stopped."
            XCTAssertEqual(model.canOpen, openWithText, "\(name), text")
        }
        XCTAssertFalse(collecting.canSave)
        XCTAssertTrue(ready.canSave)
        XCTAssertTrue(failed.canSave)

        collecting.cancel()
    }

    func testWhitespaceOnlyKeepsOpenDisabled() async {
        let (model, _) = await collected(.answer(Fixture.json()))
        for blank in [" ", "   ", "\n", " \n\t \n"] {
            model.text = blank
            XCTAssertFalse(model.canOpen, "\(blank.debugDescription)")
            model.openIssue()
        }
        XCTAssertTrue(opened.isEmpty)
        XCTAssertFalse(model.afterOpen)
    }

    func testTextIsCappedAt2000() async {
        let (model, _) = await collected(.answer(Fixture.json()))
        model.text = String(repeating: "я", count: 2_500)
        XCTAssertEqual(model.text.count, 2_000)
    }

    func testSheetStaysOpenAfterOpen() async {
        let (model, _) = await collected(.answer(Fixture.json()))
        model.text = "The sync stopped."
        XCTAssertFalse(model.afterOpen)
        model.openIssue()
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(model.notice, .opened)
        XCTAssertEqual(model.noticeText, ReportProblemCopy.opened)
        XCTAssertTrue(model.afterOpen)
        XCTAssertEqual(model.text, "The sync stopped.")
        XCTAssertFalse(model.offersCopyReport)
        XCTAssertFalse(model.offersCopyLink)

        // Open again rebuilds the link from the current text.
        model.text = "The sync stopped again."
        model.openIssue()
        XCTAssertEqual(opened.count, 2)
        XCTAssertNotEqual(opened[0], opened[1])
    }

    func testOpenedLinkIsTheBuiltLink() async {
        let (model, _) = await collected(.answer(Fixture.json()))
        model.text = "The sync stopped."
        model.openIssue()
        let expected = ReportProblemLink.make(
            userText: "The sync stopped.", answer: Fixture.answer, appVersion: "0.27.0", macOS: "15.5"
        )
        XCTAssertEqual(opened, [expected.url])
    }

    func testFailedStateOpensAppVersionsLink() async {
        let (model, _) = await collected(.failure(CLIRunnerError.binaryNotFound))
        model.text = "The app does not start."
        model.openIssue()
        let expected = ReportProblemLink.make(
            userText: "The app does not start.", answer: nil, appVersion: "0.27.0", macOS: "15.5"
        )
        XCTAssertEqual(opened, [expected.url])
    }

    func testTooLongLinkShowsNoticeAndCopyReport() async {
        let long = DiagnosticsAnswer(
            text: String(repeating: "Database: ok\n", count: 600), version: "0.27.0", macos: "15.5",
            chip: "Apple M3", provider: "Claude", flavor: "default", sources: [], partial: false
        )
        let (model, _) = await collected(.answer(Fixture.json(long)))
        model.text = "The sync stopped."
        model.openIssue()
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(model.notice, .tooLong)
        XCTAssertEqual(model.noticeText, ReportProblemCopy.tooLong)
        XCTAssertTrue(model.offersCopyReport)
        XCTAssertTrue(model.afterOpen)
        XCTAssertTrue(pasteboard.isEmpty)
    }

    func testBrowserFailureOffersCopyLink() async {
        let (model, _) = await collected(.answer(Fixture.json()))
        model.text = "The sync stopped."
        openResult = false
        model.openIssue()
        XCTAssertEqual(model.notice, .browserFailed)
        XCTAssertEqual(model.noticeText, ReportProblemCopy.browserFailed)
        XCTAssertTrue(model.offersCopyLink)
        XCTAssertTrue(model.afterOpen)
        XCTAssertTrue(pasteboard.isEmpty)

        model.copyLink()
        XCTAssertEqual(pasteboard, [opened[0].absoluteString])
        XCTAssertEqual(model.notice, .copied(.link))
        XCTAssertEqual(model.noticeText, ReportProblemCopy.linkCopied)
    }

    func testClipboardWrittenOnlyByCopyButtons() async {
        let (model, _) = await collected(.answer(Fixture.json()))
        model.text = "The sync stopped."
        model.openIssue()
        openResult = false
        model.openIssue()
        model.save(to: URL(fileURLWithPath: "/tmp/report.txt"))
        XCTAssertTrue(pasteboard.isEmpty)

        model.copyReport()
        XCTAssertEqual(model.noticeText, "Report copied.")
        model.copyLink()
        XCTAssertEqual(model.noticeText, "Link copied.")
        let link = ReportProblemLink.make(
            userText: "The sync stopped.", answer: Fixture.answer, appVersion: "0.27.0", macOS: "15.5"
        )
        XCTAssertEqual(pasteboard, [model.report, link.url.absoluteString])
    }

    func testCopyButtonsNeedTheirInputs() async {
        let runner = FakeRunner(.answer(Fixture.json()), gated: true)
        let collecting = makeModel(runner)
        collecting.text = "The sync stopped."
        collecting.start()
        await runner.waitUntilWaiting()
        collecting.copyReport()
        collecting.copyLink()
        XCTAssertTrue(pasteboard.isEmpty)
        XCTAssertEqual(collecting.notice, .none)
        collecting.cancel()

        let (ready, _) = await collected(.answer(Fixture.json()))
        ready.text = "  \n"
        ready.copyLink()
        XCTAssertTrue(pasteboard.isEmpty)
        XCTAssertEqual(ready.notice, .none)
    }

    func testSaveKeepsTheOpenNoticeAndItsCopyButtons() async {
        let long = DiagnosticsAnswer(
            text: String(repeating: "Database: ok\n", count: 600), version: "0.27.0", macos: "15.5",
            chip: "Apple M3", provider: "Claude", flavor: "default", sources: [], partial: false
        )
        let (model, _) = await collected(.answer(Fixture.json(long)))
        model.text = "The sync stopped."
        openResult = false
        model.openIssue()
        XCTAssertEqual(model.notice, .browserFailed)
        let url = URL(fileURLWithPath: "/tmp/watchtower-diagnostics.txt")

        // A successful save leaves the Open's notice alone.
        model.save(to: url)
        XCTAssertEqual(model.notice, .browserFailed)

        // A failed save shows its reason; the next successful one returns to
        // the Open's notice. The Copy buttons stay offered throughout.
        writeError = WriteFailure()
        model.save(to: url)
        XCTAssertEqual(model.notice, .saveFailed("The disk is full."))
        XCTAssertTrue(model.offersCopyLink)
        XCTAssertTrue(model.offersCopyReport)
        writeError = nil
        model.save(to: url)
        XCTAssertEqual(model.notice, .browserFailed)
        XCTAssertTrue(model.offersCopyLink)
        XCTAssertTrue(model.offersCopyReport)
    }

    // MARK: - Report and Save

    func testReportCarriesOnlyCLITextAndUserText() async {
        let (model, _) = await collected(.answer(Fixture.json()))
        model.text = "The sync stopped.\nSince Monday."
        XCTAssertEqual(model.report, "The sync stopped.\nSince Monday." + "\n\n" + Fixture.answer.text)
        model.text = "  \n"
        XCTAssertEqual(model.report, Fixture.answer.text)
    }

    func testFailedReportCarriesPartialLines() async {
        let (model, _) = await collected(.failure(CLIRunnerError.binaryNotFound))
        model.text = "It crashed."
        XCTAssertEqual(model.report, "It crashed.\n\nWatchtower app 0.27.0\nmacOS 15.5")
    }

    func testSaveWritesReport() async {
        let (model, _) = await collected(.answer(Fixture.json()))
        model.text = "It crashed."
        let url = URL(fileURLWithPath: "/tmp/watchtower-diagnostics.txt")
        model.save(to: url)
        XCTAssertEqual(written.map(\.0), [model.report])
        XCTAssertEqual(written.map(\.1), [url])
        XCTAssertEqual(model.notice, .none)
    }

    func testSaveFailureShowsReason() async {
        let (model, _) = await collected(.answer(Fixture.json()))
        writeError = WriteFailure()
        model.save(to: URL(fileURLWithPath: "/tmp/watchtower-diagnostics.txt"))
        XCTAssertEqual(model.notice, .saveFailed("The disk is full."))
        XCTAssertEqual(model.noticeText, "Could not save the file: The disk is full.")

        writeError = nil
        model.save(to: URL(fileURLWithPath: "/tmp/watchtower-diagnostics.txt"))
        XCTAssertEqual(model.notice, .none)
    }

    func testSaveDisabledWhileCollecting() async {
        let runner = FakeRunner(.answer(Fixture.json()), gated: true)
        let model = makeModel(runner)
        model.start()
        await runner.waitUntilWaiting()
        model.save(to: URL(fileURLWithPath: "/tmp/watchtower-diagnostics.txt"))
        XCTAssertTrue(written.isEmpty)
        model.cancel()
    }

    func testSaveWritesAtomically() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let file = dir.appendingPathComponent("watchtower-diagnostics.txt")
        try Data(String(repeating: "old report line\n", count: 100).utf8).write(to: file)

        // An existing file is fully replaced.
        try ReportProblemModel.writeAtomically("new report", to: file)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "new report")

        // A read-only folder: the write throws, the old file stays byte-identical,
        // nothing partial is left beside it.
        let before = try Data(contentsOf: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        XCTAssertThrowsError(try ReportProblemModel.writeAtomically("half-written", to: file))
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["watchtower-diagnostics.txt"])
    }

    // MARK: - Corporate build

    func testCorpBuildOffersSaveOnly() async {
        let (model, _) = await collected(.answer(Fixture.json()), isCorp: true)
        for text in ["", "The sync stopped."] {
            model.text = text
            XCTAssertFalse(model.canOpen)
            model.openIssue()
            model.copyLink()
        }
        XCTAssertTrue(opened.isEmpty)
        XCTAssertTrue(pasteboard.isEmpty)
        XCTAssertFalse(model.afterOpen)
        XCTAssertEqual(model.notice, .none)
        XCTAssertTrue(model.canSave)
        model.save(to: URL(fileURLWithPath: "/tmp/watchtower-diagnostics.txt"))
        XCTAssertEqual(written.count, 1)
    }
}
