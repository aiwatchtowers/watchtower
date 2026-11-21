import Foundation
import WatchtowerTestSupport
import XCTest
@testable import WatchtowerCore

/// Cancel on the wizard's sign-in check (#2132 C2): the check's waiting
/// line, and `cancelCheck` putting the step back to not-run with no failed
/// line, whichever way the run's end races the press.
@MainActor
final class CompanySetupCheckCancelTests: XCTestCase {
    private typealias Model = CompanySetupWizardModel
    private let check = ["company", "check", "atlassian"]
    private let atlassianOK = #"{"result":"ok","slug":"acme","account_id":7,"email":"alice@example.com","#
        + #""site":"https://acme.atlassian.net","checked":true,"confluence":true}"#
    private let atlassianDraft = #"{"company":"Acme","services":["atlassian"],"step":"atlassian","#
        + #""started_at":"2026-11-17T09:00:00Z","slack":{},"atlassian":{"client_id":"9f3a8d0e4b7c21","#
        + #""client_secret":"sample-secret","site":"https://acme.atlassian.net","confluence":true}}"#

    /// A model on the Atlassian step whose check is held in the browser.
    private func waiting() async -> (Model, CompanyScriptedCLI, Task<Void, Never>) {
        let cli = CompanyScriptedCLI()
        cli.on(["company", "draft", "show"], [#"{"state":"ok","draft":"# + atlassianDraft
            + #","bad_file":"","checked_vendors":[]}"#])
        let model = Model(streamer: cli, slack: SlackAppSetupModel(streamer: cli, mode: .wizard))
        await model.open()
        cli.hold(check)
        let run = Task { await model.check(.atlassian) }
        await cli.waitFor(check)
        return (model, cli, run)
    }

    private func assertNotRun(_ model: Model, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(model.checks[.atlassian], file: file, line: line)
        XCTAssertNil(model.checkLine(.atlassian), "no failed line", file: file, line: line)
        XCTAssertNil(model.checkWait(.atlassian), file: file, line: line)
        XCTAssertFalse(model.isChecked(.atlassian), file: file, line: line)
        XCTAssertEqual(model.primary, .init(title: "Check by signing in", enabled: true), file: file, line: line)
    }

    func testCancelPutsTheCheckBackToNotRun() async {
        let (model, cli, run) = await waiting()
        XCTAssertEqual(model.checks[.atlassian], .running)
        XCTAssertEqual(model.checkWait(.atlassian), .atlassian)
        XCTAssertFalse(model.primary.enabled)

        model.cancelCheck(.atlassian)
        assertNotRun(model)
        await run.value
        await model.rereadAfterCancel?.value
        assertNotRun(model)
        XCTAssertEqual(cli.cancelled(check), 1, "the check's child is ended, not left to its timeout")
        cli.release(check, [atlassianOK])
    }

    func testCancelAfterTheCheckExitedStaysNotRun() async {
        let (model, cli, run) = await waiting()
        // The child answered and exited; its run has not resumed yet.
        cli.release(check, [atlassianOK])
        model.cancelCheck(.atlassian)
        await run.value
        await model.rereadAfterCancel?.value
        assertNotRun(model)

        // A check that already ended: Cancel changes nothing.
        cli.on(check, [atlassianOK])
        await model.check(.atlassian)
        XCTAssertEqual(model.checks[.atlassian], .passed)
        model.cancelCheck(.atlassian)
        XCTAssertEqual(model.checks[.atlassian], .passed)
    }

    func testCancelledRunEndingLateLeavesTheNewCheckRunning() async {
        let (model, cli, first) = await waiting()
        model.cancelCheck(.atlassian)
        cli.hold(check)
        let second = Task { await model.check(.atlassian) }
        await cli.waitFor(check, count: 2)
        // The first child exits now: its answer lands nowhere.
        cli.release(check, [atlassianOK])
        await first.value
        XCTAssertEqual(model.checks[.atlassian], .running)
        XCTAssertEqual(model.checkWait(.atlassian), .atlassian)

        cli.release(check, [atlassianOK])
        await second.value
        XCTAssertEqual(model.checks[.atlassian], .passed)
    }

    private var storedShow: String {
        let stored = atlassianDraft.replacingOccurrences(of: #""company":"Acme","#, with: #""company":"Acme","slug":"acme","#)
        return #"{"state":"ok","draft":"# + stored + #","bad_file":"","checked_vendors":["atlassian"]}"#
    }

    /// A sign-in killed after Go stored and marked it: one draft re-read
    /// keeps the slug and shows the step checked; nothing else is shown.
    func testCancelAfterTheSignInLandedShowsItChecked() async {
        let (model, cli, run) = await waiting()
        cli.on(["company", "draft", "show"], [storedShow])
        model.cancelCheck(.atlassian)
        XCTAssertNil(model.checks[.atlassian])
        await model.rereadAfterCancel?.value
        await run.value
        XCTAssertEqual(cli.calls(["company", "draft", "show"]).count, 2, "open, then the one re-read")
        XCTAssertEqual(model.draft.slug, "acme")
        XCTAssertEqual(model.draft.company, "Acme", "a stored company keeps its name")
        XCTAssertTrue(model.isChecked(.atlassian))
        XCTAssertNil(model.checkLine(.atlassian), "no failed line")
        XCTAssertNil(model.storageProblem)
        cli.release(check, [])
    }

    /// Check pressed again while the re-read after Cancel is still out: its
    /// answer lands nowhere, so the running check keeps the company name.
    func testRereadAnsweringAfterARetryChangesNothing() async {
        let (model, cli, first) = await waiting()
        cli.hold(["company", "draft", "show"])
        model.cancelCheck(.atlassian)
        await cli.waitFor(["company", "draft", "show"], count: 2)
        await first.value
        cli.release(check, []) // the cancelled child's held stream
        cli.hold(check)
        let second = Task { await model.check(.atlassian) }
        await cli.waitFor(check, count: 2)
        // Nothing stored yet: on its own, this answer would release the name.
        cli.release(["company", "draft", "show"], [#"{"state":"none","draft":null,"bad_file":"","checked_vendors":[]}"#])
        await model.rereadAfterCancel?.value
        XCTAssertEqual(model.draft.company, "Acme")
        XCTAssertEqual(model.checks[.atlassian], .running)

        cli.release(check, [atlassianOK])
        await second.value
        XCTAssertEqual(model.checks[.atlassian], .passed)
        XCTAssertEqual(cli.calls(["company", "draft", "show"]).count, 2)
    }

    func testDryChecksHaveNoWaitingLine() {
        let model = Model(streamer: CompanyScriptedCLI(), slack: SlackAppSetupModel(streamer: nil, mode: .wizard))
        for vendor in CompanyVendor.allCases { XCTAssertNil(model.checkWait(vendor)) }
    }
}
