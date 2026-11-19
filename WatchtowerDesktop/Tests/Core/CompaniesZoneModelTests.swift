import WatchtowerTestSupport
import XCTest
@testable import WatchtowerCore

/// The Companies zone's reads and code field (company screens spec §4.1,
/// #1887 Task 25a) over a fake CLI: `company list --json`, then `company
/// draft show --json` while a draft exists.
@MainActor
final class CompaniesZoneModelTests: XCTestCase {
    private typealias Pres = CompanyConnectionsPresentation

    private static let acmeList = #"{"companies":[{"slug":"acme","company":"Acme","forced":false,"personal":false,"#
        + #""vendors":{"slack":{"team_id":"T0","client_id":"000.111"},"google":{"client_id":"g","domain":"example.com"},"#
        + #""atlassian":{"client_id":"a","site":"https://acme.atlassian.net","confluence":true},"#
        + #""microsoft":{"client_id":"m","tenant_id":"0000-acme"},"linear":{"client_id":"l"}}}],"#
        + #""errors":[],"draft":{"state":"none"}}"#

    private func list(draft: String = "none", errors: String = "[]", companies: String? = nil) -> FakeCLILineStream.Reply {
        var line = Self.acmeList.replacingOccurrences(of: #""draft":{"state":"none"}"#, with: #""draft":{"state":"\#(draft)"}"#)
        line = line.replacingOccurrences(of: #""errors":[]"#, with: #""errors":\#(errors)"#)
        if let companies {
            line = #"{"companies":\#(companies),"errors":\#(errors),"draft":{"state":"\#(draft)"}}"#
        }
        return .init(lines: [line])
    }

    private func model(_ replies: [FakeCLILineStream.Reply]) -> (CompaniesZoneModel, FakeCLILineStream) {
        let fake = FakeCLILineStream(replies: replies)
        return (CompaniesZoneModel { fake }, fake)
    }

    func testLoadingUntilTheFirstRead() async {
        let (model, fake) = model([list()])
        XCTAssertEqual(model.zone(accounts: [], portBusy: false).body, .loading(Pres.companiesLoading))
        await model.reload()
        XCTAssertEqual(fake.invocations.map(\.args), [["company", "list", "--json"]], "no draft: no draft read")
        XCTAssertEqual(model.companies.map(\.name), ["Acme"])
        XCTAssertEqual(model.companies.first?.vendors[.atlassian], "https://acme.atlassian.net")
        XCTAssertEqual(model.companies.first?.vendors[.microsoft], "0000-acme")
        XCTAssertEqual(model.companies.first?.vendors[.google], "example.com")
        XCTAssertEqual(model.slackClientIDs, ["acme": "000.111"])
        XCTAssertEqual(model.zone(accounts: [], portBusy: false).body.cards.map(\.name), ["Acme"])
    }

    /// A failed `company list` is read-failed, never "no company" (absent vs. error).
    func testListFailureIsReadFailedNotEmpty() async {
        let (model, _) = model([.init(lines: [], exitCode: 1, stderr: "database is locked")])
        await model.reload()
        guard case .readFailed(let text) = model.zone(accounts: [], portBusy: false).body else {
            return XCTFail("a failed list must not read as no company")
        }
        XCTAssertTrue(text.contains("database is locked"))
    }

    func testUnreadableAnswerIsReadFailed() async {
        let (model, _) = model([.init(lines: ["not json"])])
        await model.reload()
        guard case .readFailed = model.zone(accounts: [], portBusy: false).body else { return XCTFail("a failed read must not read as no company") }
    }

    func testNoCLIIsReadFailed() async {
        let model = CompaniesZoneModel { nil }
        await model.reload()
        guard case .readFailed = model.zone(accounts: [], portBusy: false).body else { return XCTFail("a failed read must not read as no company") }
    }

    /// A draft: "Setup in progress: Acme, at Atlassian (step 4 of 8)." from the draft's own step.
    func testDraftBecomesTheSetupLine() async {
        let draft = #"{"state":"ok","draft":{"company":"Acme","services":["slack","google","atlassian","linear","microsoft"],"#
            + #""step":"atlassian","slack":{}},"bad_file":"","checked_vendors":[]}"#
        let (model, fake) = model([list(draft: "ok"), .init(lines: [draft])])
        await model.reload()
        XCTAssertEqual(fake.invocations.map(\.args).last, ["company", "draft", "show", "--json"])
        XCTAssertEqual(model.draft, .inProgress(company: "Acme", step: "Atlassian", index: 3, count: 8))
        XCTAssertEqual(model.zone(accounts: [], portBusy: false).setup?.text,
                       "Setup in progress: Acme, at Atlassian (step 4 of 8).")
    }

    func testUnreadableDraftIsItsOwnLine() async {
        let (model, fake) = model([list(draft: "unreadable", errors: #"[{"file":"draft.json","error":"x"}]"#)])
        await model.reload()
        XCTAssertEqual(fake.invocations.count, 1)
        XCTAssertEqual(model.draft, .unreadable)
        let zone = model.zone(accounts: [], portBusy: false)
        XCTAssertEqual(zone.setup?.text, Pres.draftUnreadable)
        XCTAssertNil(zone.problem, "the draft is not a damaged company file")
    }

    /// The draft's read failing never hides the companies.
    func testDraftReadFailureKeepsTheCompanies() async {
        let (model, _) = model([list(draft: "ok"), .init(lines: [], exitCode: 1, stderr: "boom")])
        await model.reload()
        XCTAssertNil(model.draft)
        XCTAssertEqual(model.zone(accounts: [], portBusy: false).body.cards.map(\.name), ["Acme"])
    }

    func testDamagedFileBesideAGoodOne() async {
        let (model, _) = model([list(errors: #"[{"file":"beta.json","error":"bad json"}]"#)])
        await model.reload()
        let zone = model.zone(accounts: [], portBusy: false)
        XCTAssertEqual(zone.body.cards.count, 1)
        XCTAssertEqual(zone.problem, "Could not read the company setups: beta.json is damaged.")
    }

    /// Two reads racing (appear, then a flow ends): the last one started wins.
    func testLaterReadWins() async throws {
        let fake = FakeCLILineStream() // the first run gets a session the test drives
        let model = CompaniesZoneModel { fake }
        let first = Task { await model.reload() }
        let session = await fake.session(number: 1)
        fake.enqueue(list(companies: "[]"))
        await model.reload()
        XCTAssertEqual(model.companies, [])
        session.emit(Self.acmeList)
        session.exit(code: 0)
        await first.value
        XCTAssertEqual(model.companies, [], "the older read's answer is dropped")
    }

    // MARK: - Code field

    func testCodeFieldPasteError() async {
        let (model, _) = model([])
        model.openCodeField()
        XCTAssertTrue(model.codeFieldOpen)
        model.code = "hello"
        await model.submitCode { _ in Pres.codeInvalid }
        XCTAssertEqual(model.codeError, Pres.codeInvalid)
        XCTAssertTrue(model.codeFieldOpen)
        model.code = "hello2"
        XCTAssertNil(model.codeError, "typing clears the error")
    }

    func testCodeFieldClosesWhenTheConfirmOpens() async {
        let (model, _) = model([])
        model.openCodeField()
        model.code = "  abc  "
        var pasted: [String] = []
        await model.submitCode { text in
            pasted.append(text)
            return nil
        }
        XCTAssertEqual(pasted, ["abc"])
        XCTAssertFalse(model.codeFieldOpen)
        XCTAssertEqual(model.code, "")
        XCTAssertNil(model.codeError)
    }

    func testEmptyCodeStartsNothing() async {
        let (model, _) = model([])
        var called = false
        await model.submitCode { _ in
            called = true
            return nil
        }
        XCTAssertFalse(called)
    }

    func testCardProgressAndSlackCopy() {
        XCTAssertEqual(Pres.connecting(.google), "Connecting… Google")
        XCTAssertEqual(Pres.slackAppDetail(appID: "A0ACME"), "Watchtower (A0ACME)")
    }
}
