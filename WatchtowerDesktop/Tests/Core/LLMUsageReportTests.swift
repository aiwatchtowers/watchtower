import XCTest
@testable import WatchtowerCore

/// `watchtower usage llm --json` (LLM usage ledger, Task 7) decoded by the
/// Usage → Watchtower tab, its display names and the text it shows.
final class LLMUsageReportTests: XCTestCase {
    static func fixture() throws -> Data {
        let url = URL(fileURLWithPath: #filePath)   // …/Tests/Core/<this file>
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/llm-usage-report.json")
        return try Data(contentsOf: url)
    }

    private func report() throws -> LLMUsageReport {
        try JSONDecoder().decode(LLMUsageReport.self, from: Self.fixture())
    }

    // MARK: - Decode

    func testFixtureDecodes() throws {
        let rep = try report()
        XCTAssertEqual(rep.period, "7d")
        XCTAssertEqual(rep.ledgerSince, "2026-10-20T07:12:03Z")
        XCTAssertEqual(rep.watchtower.totals.calls, 1284)
        XCTAssertEqual(rep.watchtower.totals.estimatedCalls, 12)
        XCTAssertEqual(rep.watchtower.totals.noPriceCalls, 30)
        XCTAssertEqual(rep.watchtower.totals.untaggedCalls, 3)
        XCTAssertEqual(rep.watchtower.totals.cacheRead, 9_000_000)
        XCTAssertEqual(rep.watchtower.totals.cacheWrite, 400_000)
        XCTAssertEqual(rep.watchtower.totals.costUSD, 41.2)
        XCTAssertTrue(rep.watchtower.totals.costIsLowerBound)
        XCTAssertEqual(rep.watchtower.rows.count, 7)

        let digest = try XCTUnwrap(rep.watchtower.rows.first { $0.purpose == "digest.channel" })
        XCTAssertEqual(digest.models, ["haiku", "sonnet"])
        XCTAssertEqual(digest.perCallTokens, 7524)
        XCTAssertEqual(digest.tokens, 90000 + 2_800_000 + 90000 + 120_000)

        let untagged = try XCTUnwrap(rep.watchtower.rows.first { $0.purpose.isEmpty })
        XCTAssertEqual(untagged.process, "cli:jira boards")
        XCTAssertTrue(untagged.isUntagged)

        let noPrice = try XCTUnwrap(rep.watchtower.rows.first { $0.purpose == "memory.extract_episodes" })
        XCTAssertNil(noPrice.costUSD)
        XCTAssertTrue(noPrice.costIsLowerBound)

        XCTAssertEqual(rep.ownAutomations.rows.map(\.name), ["Weekly to-do", "Triage new tracker issues"])
        XCTAssertEqual(rep.ownAutomations.rows[1].automationID, 3)
        XCTAssertEqual(rep.ownAutomations.rows[1].runs, 110)
        XCTAssertTrue(rep.ownAutomations.rows[0].costIsEstimate)
        XCTAssertFalse(rep.ownAutomations.rows[0].costIsLowerBound, "absent key: not a lower bound")
        XCTAssertTrue(rep.ownAutomations.rows[1].costIsLowerBound)
        XCTAssertEqual(rep.chats.costUSD, 61.0)
        XCTAssertEqual(rep.pageTotal.calls, 1606)
        XCTAssertEqual(rep.workbenches.sessions.sessions, 41)
        XCTAssertEqual(rep.workbenches.helpers.calls, 120)
        XCTAssertEqual(rep.workbenches.analyticsOff, ["demo-bench"])
    }

    /// The empty-ledger wire shape: nil Go slices arrive as `null`, a cost as
    /// `null` or absent, `ledger_since` as "".
    func testEmptyLedgerWireShapeDecodes() throws {
        let zero = #"{"calls":0,"errors":0,"estimated_calls":0,"no_price_calls":0,"untagged_calls":0,"input":0,"#
            + #""cache_read":0,"cache_write":0,"output":0,"cost_usd":null,"cost_is_lower_bound":false}"#
        let json = """
        {"chats":\(zero),"ledger_since":"","own_automations":{"totals":\(zero),"rows":null},
         "page_total":\(zero),"period":"today","watchtower":{"totals":\(zero),"rows":null},
         "workbenches":{"totals":\(zero),"sessions":{"calls":0},"helpers":\(zero),"analytics_off":null}}
        """
        let rep = try JSONDecoder().decode(LLMUsageReport.self, from: Data(json.utf8))
        XCTAssertTrue(rep.ledgerSince.isEmpty)
        XCTAssertTrue(rep.watchtower.rows.isEmpty)
        XCTAssertTrue(rep.ownAutomations.rows.isEmpty)
        XCTAssertTrue(rep.workbenches.analyticsOff.isEmpty)
        XCTAssertNil(rep.chats.costUSD)
        XCTAssertEqual(rep.workbenches.sessions.output, 0)
    }

    // MARK: - Purpose names

    func testPurposeNames() {
        XCTAssertEqual(LLMPurposeNames.display(purpose: "digest.channel").name, "Slack digests")
        XCTAssertEqual(LLMPurposeNames.display(purpose: "briefing.daily").name, "Morning brief")
        XCTAssertEqual(LLMPurposeNames.display(purpose: "ideas.consolidate").name, "Idea finder")
        XCTAssertEqual(LLMPurposeNames.display(purpose: "media.describe").name, "Image descriptions")
        XCTAssertEqual(LLMPurposeNames.display(purpose: "instructions.suggest").name, "Agent instruction suggestions")
        XCTAssertEqual(LLMPurposeNames.display(purpose: "jira.boards").group, "Jira")
        XCTAssertEqual(LLMPurposeNames.display(purpose: "probe").name, "Model checks")
    }

    func testUnknownPurposeFallsBackToTheRawTag() {
        let shown = LLMPurposeNames.display(purpose: "brand.new_thing")
        XCTAssertEqual(shown.name, "brand.new_thing")
        XCTAssertEqual(shown.group, "Other")
    }

    /// Every tag the Go code passes to `digest.WithSource` (and the tags the
    /// ledger plan adds) has a name of its own, not the raw fallback.
    func testEveryKnownPurposeHasAName() {
        for purpose in LLMPurposeNames.knownPurposes {
            XCTAssertNotEqual(LLMPurposeNames.display(purpose: purpose).name, purpose, purpose)
        }
        XCTAssertGreaterThan(LLMPurposeNames.knownPurposes.count, 50)
    }

    func testRowName() throws {
        let rows = try report().watchtower.rows
        XCTAssertEqual(rows.first { $0.purpose.isEmpty }?.displayName, "Untagged (cli:jira boards)")
        XCTAssertEqual(rows.first { $0.purpose == "digest.channel" }?.displayName, "Slack digests")
    }

    // MARK: - Text

    func testCostText() {
        XCTAssertEqual(LLMUsagePresentation.cost(14.1, isEstimate: false, isLowerBound: false), "$14.10")
        XCTAssertEqual(LLMUsagePresentation.cost(3.1, isEstimate: true, isLowerBound: false), "≈ $3.10")
        XCTAssertEqual(LLMUsagePresentation.cost(41.2, isEstimate: true, isLowerBound: true), "≥ $41.20")
        XCTAssertEqual(LLMUsagePresentation.cost(nil, isEstimate: false, isLowerBound: true), "—")
        XCTAssertEqual(LLMUsagePresentation.cost(0, isEstimate: false, isLowerBound: true), "—")
        XCTAssertEqual(LLMUsagePresentation.cost(0, isEstimate: false, isLowerBound: false), "$0.00")
    }

    func testTokenText() {
        XCTAssertEqual(LLMUsagePresentation.tokens(512), "512")
        XCTAssertEqual(LLMUsagePresentation.tokens(1000), "1 K")
        XCTAssertEqual(LLMUsagePresentation.tokens(7524), "7.5 K")
        XCTAssertEqual(LLMUsagePresentation.tokens(212_000), "212 K")
        XCTAssertEqual(LLMUsagePresentation.tokens(999_700), "1 M")
        XCTAssertEqual(LLMUsagePresentation.tokens(9_400_000), "9.4 M")
        XCTAssertEqual(LLMUsagePresentation.tokens(412_000_000), "412 M")
    }

    func testGapsNameOnlyNonZeroParts() throws {
        let totals = try report().watchtower.totals
        XCTAssertEqual(LLMUsagePresentation.gaps(totals), [
            .init(text: "12 calls with estimated usage", isWarning: false),
            .init(text: "30 calls without a price (Codex/Ollama)", isWarning: false),
            .init(text: "3 untagged calls", isWarning: true)
        ])
        var one = LLMUsageTotals.zero
        one.untaggedCalls = 1
        XCTAssertEqual(LLMUsagePresentation.gaps(one), [.init(text: "1 untagged call", isWarning: true)])
        XCTAssertEqual(LLMUsagePresentation.gaps(.zero), [])
    }

    /// By cost, highest first; rows with no cost after them by tokens;
    /// untagged rows always last.
    func testRowsSortByCostThenTokensUntaggedLast() throws {
        let sorted = LLMUsagePresentation.sorted(try report().watchtower.rows)
        XCTAssertEqual(sorted.map(\.purpose), [
            "digest.channel", "briefing.daily", "instructions.suggest", "ideas.consolidate",
            "media.describe", "memory.extract_episodes", ""
        ])
    }

    func testAutomationsSortByCost() throws {
        let sorted = LLMUsagePresentation.sorted(try report().ownAutomations.rows)
        XCTAssertEqual(sorted.map(\.name), ["Triage new tracker issues", "Weekly to-do"])
    }

    func testWorkbenchLines() throws {
        let rep = try report()
        XCTAssertEqual(LLMUsagePresentation.workbenchDetail(rep.workbenches), "sessions 410 M · Watchtower helpers 2 M")
        XCTAssertEqual(LLMUsagePresentation.analyticsOffNote(["demo-bench"]),
                       "Agent analytics is off for: demo-bench — its sessions are not counted.")
        XCTAssertEqual(LLMUsagePresentation.analyticsOffNote(["a", "b"]),
                       "Agent analytics is off for: a, b — their sessions are not counted.")
        XCTAssertNil(LLMUsagePresentation.analyticsOffNote([]))
    }

    // MARK: - Screen state

    private let now = Date(timeIntervalSince1970: 1_793_188_800)  // 2026-10-28T12:00:00Z

    func testScreenLoadingOnFirstLoadOnly() throws {
        XCTAssertEqual(LLMUsagePresentation.screen(report: nil, error: nil, lastUpdated: nil,
                                                   period: .sevenDays, now: now), .loading)
    }

    func testScreenEmptyLedger() throws {
        var rep = try report()
        rep.ledgerSince = ""
        XCTAssertEqual(LLMUsagePresentation.screen(report: rep, error: nil, lastUpdated: now,
                                                   period: .sevenDays, now: now), .emptyLedger)
    }

    func testScreenFailedWithoutAReport() {
        XCTAssertEqual(LLMUsagePresentation.screen(report: nil, error: .timedOut, lastUpdated: nil,
                                                   period: .sevenDays, now: now), .failed(.timedOut))
    }

    /// The ledger started inside the period: the layout plus "Recording since".
    func testScreenRecordingSinceWhenTheLedgerIsYoungerThanThePeriod() throws {
        let rep = try report()  // ledger since 2026-10-20, 8 days before `now`
        guard case let .report(_, since, failedAt) = LLMUsagePresentation.screen(
            report: rep, error: nil, lastUpdated: now, period: .thirtyDays, now: now
        ) else { return XCTFail("expected the report") }
        XCTAssertNotNil(since)
        XCTAssertTrue(since?.hasPrefix("Recording since ") == true)
        XCTAssertNil(failedAt)

        guard case let .report(_, sinceInWeek, _) = LLMUsagePresentation.screen(
            report: rep, error: nil, lastUpdated: now, period: .sevenDays, now: now
        ) else { return XCTFail("expected the report") }
        XCTAssertNil(sinceInWeek, "the ledger is older than the 7-day period")
    }

    func testScreenKeepsTheReportWhenARefreshFails() throws {
        let rep = try report()
        let updated = now.addingTimeInterval(-60)
        guard case let .report(kept, _, failedAt) = LLMUsagePresentation.screen(
            report: rep, error: .timedOut, lastUpdated: updated, period: .sevenDays, now: now
        ) else { return XCTFail("expected the report") }
        XCTAssertEqual(kept, rep)
        XCTAssertEqual(failedAt, updated)
    }

    func testPeriodStart() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        XCTAssertEqual(LLMUsagePeriod.today.start(now: now, calendar: cal),
                       Date(timeIntervalSince1970: 1_793_145_600))
        XCTAssertEqual(LLMUsagePeriod.sevenDays.start(now: now, calendar: cal), now.addingTimeInterval(-7 * 86400))
        XCTAssertEqual(LLMUsagePeriod.thirtyDays.rawValue, "30d")
    }

    // MARK: - Errors

    func testErrorClasses() {
        XCTAssertEqual(LLMUsageLoadError(CLIRunnerError.binaryNotFound), .cliMissing)
        XCTAssertEqual(LLMUsageLoadError(CLIRunnerError.nonZeroExit(code: -1, stderr: "timed out after 10 s")), .timedOut)
        XCTAssertEqual(LLMUsageLoadError(CLIRunnerError.nonZeroExit(code: 2, stderr: "boom")), .failed(exitCode: 2))
        XCTAssertEqual(LLMUsageLoadError(CLIRunnerError.launchFailed(underlying: CocoaError(.fileNoSuchFile))),
                       .couldNotStart)
        XCTAssertEqual(LLMUsageLoadError(DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: ""))),
                       .unreadable)
        XCTAssertEqual(LLMUsageLoadError.timedOut.subtitle, "The command timed out.")
    }
}
