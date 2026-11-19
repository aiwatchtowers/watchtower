import WatchtowerTestSupport
import XCTest
@testable import WatchtowerCore

/// The API-token sheet's model (#1887 C5, company screens spec §6.2) over
/// scripted `jira add|login --api-token-stdin --json` runs (Go
/// `apiTokenResult`): the token only on stdin, each outcome's text, the
/// replace mode and the policy lock.
@MainActor
final class AtlassianTokenFormModelTests: XCTestCase {
    private typealias Model = AtlassianTokenFormModel
    private static let token = "ATATT-sample-not-real" // leak-check:allow

    private func makeModel(_ replies: [FakeCLILineStream.Reply] = []) -> (Model, FakeCLILineStream, () -> Int) {
        let fake = FakeCLILineStream(replies: replies)
        var connected = 0
        let model = Model { fake }
        model.onConnected = { connected += 1 }
        return (model, fake, { connected })
    }

    private func fill(_ model: Model, site: String = "acme.atlassian.net") {
        model.openAdd()
        model.email = "alice@example.com"
        model.site = site
        model.token = Self.token
    }

    private static func reply(_ json: String, exit: Int32 = 0) -> FakeCLILineStream.Reply {
        FakeCLILineStream.Reply(lines: ["Checking…", json], exitCode: exit)
    }

    func testConnectDisabledUntilAllThree() {
        let (model, _, _) = makeModel()
        model.openAdd()
        XCTAssertTrue(model.isPresented)
        XCTAssertFalse(model.canSubmit)
        model.email = "alice@example.com"
        model.site = "acme.atlassian.net"
        XCTAssertFalse(model.canSubmit)
        model.token = "   "
        XCTAssertFalse(model.canSubmit, "a blank token is no token")
        model.token = Self.token
        XCTAssertTrue(model.canSubmit)
        XCTAssertEqual(model.primaryTitle, Model.connectTitle)
        XCTAssertTrue(model.showsScopedHint)
        XCTAssertTrue(model.siteEditable)
        XCTAssertTrue(model.emailEditable)
    }

    func testUnauthorized() async {
        let (model, _, connected) = makeModel([Self.reply(#"{"result":"unauthorized"}"#)])
        fill(model)
        await model.submit()
        XCTAssertEqual(model.phase, .problem(.unauthorized))
        XCTAssertEqual(model.problemLine, "Atlassian did not accept this email and token. Check both, or create a new token.")
        XCTAssertEqual(model.primaryTitle, "Try again")
        XCTAssertFalse(model.showsScopedHint)
        XCTAssertEqual(model.token, Self.token, "Try again resends what is in the field")
        XCTAssertTrue(model.canSubmit)
        XCTAssertEqual(connected(), 0)
    }

    func testMissingScopeNamesScope() async {
        let (model, _, _) = makeModel([Self.reply(#"{"result":"missing_scope","scope":"read:jira-work"}"#)])
        fill(model)
        await model.submit()
        XCTAssertEqual(model.problemLine, "This token lacks read:jira-work — create one with the listed scopes.")
    }

    func testNotCloud() async {
        let (model, _, _) = makeModel([Self.reply(#"{"result":"not_cloud"}"#)])
        fill(model, site: "https://Acme.example.com/")
        await model.submit()
        XCTAssertEqual(model.problemLine, "acme.example.com is not an Atlassian Cloud site. Enter the address you open "
            + "Jira at, like acme.atlassian.net.")
    }

    func testNetwork() async {
        let (model, _, connected) = makeModel([Self.reply(#"{"result":"network","detail":"the request timed out"}"#)])
        fill(model)
        await model.submit()
        XCTAssertEqual(model.problemLine, "Could not reach acme.atlassian.net: the request timed out. Nothing was saved.")
        XCTAssertEqual(connected(), 0)
    }

    func testFailedShowsGoMessageAndNoAnswerIsAFailure() async {
        let (model, _, _) = makeModel([
            Self.reply(#"{"result":"failed","message":"creating jira account: disk full"}"#, exit: 1),
            FakeCLILineStream.Reply(lines: [], exitCode: 1, stderr: "Error: unknown flag: --json")
        ])
        fill(model)
        await model.submit()
        XCTAssertEqual(model.problemLine, "creating jira account: disk full")
        await model.submit()
        guard case .problem(.failed(let text)) = model.phase else { return XCTFail("\(model.phase)") }
        XCTAssertTrue(text.contains("unknown flag"), text)
    }

    func testDone() async {
        let (model, _, connected) = makeModel([
            Self.reply(#"{"result":"ok","account_id":4,"site":"https://acme.atlassian.net","email":"alice@example.com"}"#)
        ])
        fill(model)
        await model.submit()
        XCTAssertEqual(model.phase, .done(host: "acme.atlassian.net", email: "alice@example.com"))
        XCTAssertEqual(Model.connected("acme.atlassian.net", "alice@example.com"),
                       "Connected to acme.atlassian.net as alice@example.com")
        XCTAssertEqual(model.title, Model.addTitle)
        XCTAssertNil(model.intro)
        XCTAssertEqual(model.primaryTitle, "Done")
        XCTAssertEqual(connected(), 1)
        model.close()
        XCTAssertFalse(model.isPresented)
    }

    func testReplaceModeReadOnlyEmailSite() async {
        let (model, fake, connected) = makeModel([
            Self.reply(#"{"result":"ok","account_id":7,"site":"https://beta.atlassian.net","email":"bob@example.com"}"#)
        ])
        model.openReplace(accountID: 7, email: "bob@example.com", site: "https://beta.atlassian.net")
        XCTAssertEqual(model.title, "Paste a new token for beta.atlassian.net")
        XCTAssertEqual(model.intro, Model.replaceIntro)
        XCTAssertFalse(model.siteEditable)
        XCTAssertFalse(model.emailEditable)
        XCTAssertFalse(model.showsScopedHint)
        XCTAssertEqual(model.primaryTitle, "Save token")
        XCTAssertFalse(model.canSubmit)
        model.token = Self.token
        await model.submit()
        let login = ["jira", "login", "--account", "7", "--api-token-stdin", "--email", "bob@example.com", "--json"]
        XCTAssertEqual(fake.invocations.map(\.args), [login])
        XCTAssertEqual(model.phase, .done(host: "beta.atlassian.net", email: "bob@example.com"))
        XCTAssertEqual(connected(), 1)
    }

    /// A row that names no email (an unknown owner) asks for it: the token
    /// file the re-auth would read it from may be the broken part.
    func testReplaceWithoutKnownEmailAsksForIt() {
        let (model, _, _) = makeModel()
        model.openReplace(accountID: 7, email: "", site: "https://beta.atlassian.net")
        XCTAssertTrue(model.emailEditable)
        XCTAssertFalse(model.siteEditable)
        model.token = Self.token
        XCTAssertFalse(model.canSubmit)
        model.email = "bob@example.com"
        XCTAssertTrue(model.canSubmit)
    }

    func testTokenOnStdinOnlyAndDropped() async {
        let (model, fake, _) = makeModel([
            Self.reply(#"{"result":"ok","account_id":4,"site":"https://acme.atlassian.net","email":"alice@example.com"}"#)
        ])
        fill(model)
        await model.submit()
        let run = try? XCTUnwrap(fake.invocations.first)
        XCTAssertEqual(run?.args, ["jira", "add", "--api-token-stdin", "--email", "alice@example.com",
                                   "--site", "acme.atlassian.net", "--with-confluence", "--json"])
        XCTAssertFalse(run?.args.contains { $0.contains(Self.token) } ?? true, "never in argv")
        XCTAssertEqual(run?.stdin, Data((Self.token + "\n").utf8))
        XCTAssertEqual(model.token, "", "dropped once connected")

        // A failed check keeps the field for Try again; closing drops it.
        let (failing, _, _) = makeModel([Self.reply(#"{"result":"unauthorized"}"#)])
        fill(failing)
        await failing.submit()
        failing.close()
        XCTAssertEqual(failing.token, "")
        XCTAssertEqual(failing.phase, .form)
    }

    func testPolicyLockClosesSheet() async {
        let (model, _, _) = makeModel()
        fill(model)
        model.policyLocked()
        XCTAssertFalse(model.isPresented)
        XCTAssertEqual(model.token, "")

        // Go refuses a token the policy forbids: the sheet closes the same way.
        let (refused, _, connected) = makeModel([Self.reply(#"{"result":"forbidden"}"#)])
        fill(refused)
        await refused.submit()
        XCTAssertFalse(refused.isPresented)
        XCTAssertEqual(refused.phase, .form)
        XCTAssertEqual(connected(), 0)
    }

    /// Cancel during a check closes the sheet but never kills the run (a
    /// kill between the account row and its token file would leave half an
    /// account); its success still refreshes the accounts.
    func testCancelDuringCheckLetsTheRunFinish() async {
        let (model, fake, connected) = makeModel()
        fill(model)
        let running = Task { await model.submit() }
        let child = await fake.session(number: 1)
        XCTAssertTrue(model.isChecking)
        XCTAssertEqual(model.busyLine, "Checking the token with acme.atlassian.net…")
        XCTAssertFalse(model.canSubmit)
        model.close()
        XCTAssertFalse(model.isPresented)
        XCTAssertFalse(child.terminated)
        // Reopening while it runs shows the check, not a fresh form.
        model.openAdd()
        XCTAssertTrue(model.isChecking)
        model.close()
        child.emit(#"{"result":"ok","account_id":4,"site":"https://acme.atlassian.net","email":"alice@example.com"}"#)
        child.exit()
        await running.value
        XCTAssertEqual(connected(), 1)
        XCTAssertEqual(model.phase, .form)
        XCTAssertFalse(model.isPresented)
    }

    func testCopyScopesMatchGoFixture() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("internal/jira/testdata/api_token_scopes.txt")
        let fixture = try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isWhitespace).map(String.init)
        XCTAssertEqual(Model.scopes, fixture)
        XCTAssertFalse(Model.scopes.contains("offline_access"))
    }
}
