import XCTest
import GRDB
@testable import WatchtowerCore

/// Pins every string of screens spec §1.1 (chip, summary, tone) and §1.2
/// (Live rows, reasons, ages, the block's states and their actions).
final class SlackModePresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func stamp(_ secondsAgo: TimeInterval) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        // The Go writer's layout: nine fractional digits, UTC.
        return fmt.string(from: now.addingTimeInterval(-secondsAgo)).replacingOccurrences(of: "Z", with: ".000000000Z")
    }

    private func account(
        id: Int = 1,
        teamID: String = "T0ACME",
        name: String = "acme",
        label: String = "",
        status: String = "ok",
        enabled: Bool = true
    ) -> SlackAccount {
        SlackAccount(row: Row([
            "id": id, "team_id": teamID, "team_name": name, "team_domain": "", "label": label,
            "status": status, "error": "", "enabled": enabled
        ]))
    }

    private func row(
        _ provider: String, _ status: String, errorClass: String = "", team: String = "", ago: TimeInterval = 300
    ) -> SlackLiveStatusRow {
        SlackLiveStatusRow(
            teamID: team, provider: provider, status: status, errorClass: errorClass,
            connectorID: "", checkedAt: stamp(ago))
    }

    private func make(
        accounts: [SlackAccount] = [],
        shared: Set<Int> = [],
        rows: [SlackLiveStatusRow] = [],
        isRunning: Bool = false,
        hasRead: Bool = true,
        lastError: SlackLiveError? = nil
    ) -> SlackModePresentation {
        SlackModePresentation(
            accounts: accounts, sharedAppAccountIDs: shared, liveStatuses: rows,
            isRunning: isRunning, hasRead: hasRead, lastError: lastError, now: now)
    }

    // MARK: - §1.1 chip and summary

    func testFullChip() {
        let p = make(accounts: [account()], rows: [row("claude", "not_connected", errorClass: "connectors_off")])
        XCTAssertEqual(p.display, .full)
        XCTAssertEqual(p.title, "Slack mode")
        XCTAssertEqual(p.chip, "Full")
        XCTAssertEqual(p.chipTone, .success)
        XCTAssertEqual(p.summary, "Synced on this Mac through your workspace's own Slack app. Every feature works.")
    }

    func testFullLiveChip() {
        let p = make(accounts: [account()], rows: [row("claude", "ok", team: "T0ACME")])
        XCTAssertEqual(p.display, .fullLive)
        XCTAssertEqual(p.chip, "Full · Live on")
        XCTAssertEqual(p.chipTone, .success)
        XCTAssertEqual(p.summary, "Synced on this Mac through your workspace's own Slack app. "
            + "Chats also read Slack through Live for what is not synced.")
    }

    func testLiveChip() {
        let p = make(rows: [row("codex", "ok", team: "T0ACME")])
        XCTAssertEqual(p.display, .live)
        XCTAssertEqual(p.chip, "Live")
        XCTAssertEqual(p.chipTone, .blue)
        XCTAssertEqual(p.summary, "Chats and automations read Slack through your Claude or ChatGPT connector. "
            + "Nothing is synced, so digests, the Inbox, tracks and people need your workspace's app.")
    }

    func testOffChip() {
        let p = make()
        XCTAssertEqual(p.display, .off)
        XCTAssertEqual(p.chip, "Off")
        XCTAssertEqual(p.chipTone, .gray)
        XCTAssertEqual(p.summary, "Slack is not connected. Connect your workspace's app to sync, or turn on the Slack "
            + "connector in your Claude or ChatGPT account to ask about Slack in Chats.")
    }

    /// A disabled, failing or removed account is not Full (`HasFullSlackAccount`).
    func testOnlyEnabledOKAccountsAreFull() {
        XCTAssertEqual(make(accounts: [account(enabled: false)]).display, .off)
        XCTAssertEqual(make(accounts: [account(status: "revoked")]).display, .off)
        XCTAssertEqual(make(accounts: [account(status: "removed")]).display, .off)
    }

    func testSharedAppFollowsFlag() {
        let acme = account(id: 4)
        XCTAssertEqual(make(accounts: [acme]).display, .full, "no flag: a company app")
        let p = make(accounts: [acme], shared: [4])
        XCTAssertEqual(p.display, .sharedApp)
        XCTAssertEqual(p.chip, "Shared app")
        XCTAssertEqual(p.chipTone, .warning)
        XCTAssertEqual(p.summary, "acme syncs through Watchtower's old shared Slack app until Slack turns it off.")
        let blank = make(accounts: [account(id: 4, name: "", label: " ")], shared: [4])
        XCTAssertEqual(blank.summary,
                       "T0ACME syncs through Watchtower's old shared Slack app until Slack turns it off.",
                       "a blank label falls back to the team")
        XCTAssertEqual(make(accounts: [account(id: 4, enabled: false)], shared: [4]).display, .off,
                       "a disabled shared-app account does not sync")
        XCTAssertEqual(make(accounts: [acme, account(id: 5, teamID: "T0OTHER")], shared: [4]).display, .full,
                       "a company-app account makes the mode Full")
    }

    /// §5: the banner, the account tag and line, and Move to Full.
    func testSharedAppBanner() {
        let banner = make(accounts: [account(id: 4)], shared: [4]).sharedAppBanner
        XCTAssertEqual(banner?.title, "Watchtower's shared Slack app is retiring")
        XCTAssertEqual(banner?.body, "acme still syncs through it until Slack turns it off. Move to Full with your "
            + "workspace's own app, or use Live through your Claude or ChatGPT account.")
        XCTAssertEqual(banner?.setUpForCompany, "Set up for my company")
        XCTAssertEqual(banner?.pasteLink, "Paste a connect link")
        XCTAssertNotNil(make(accounts: [account(id: 4), account(id: 5, teamID: "T0OTHER")], shared: [4]).sharedAppBanner,
                        "shown while any account syncs through it, also when another makes the mode Full")
        XCTAssertNil(make(accounts: [account(id: 4)]).sharedAppBanner, "no flag, no banner")
        XCTAssertNil(make(accounts: [account(id: 4, enabled: false)], shared: [4]).sharedAppBanner)
        XCTAssertNil(make(accounts: [account(id: 4, status: "removed")], shared: [4]).sharedAppBanner)
        XCTAssertNil(make(accounts: [account(id: 4, status: "revoked")], shared: [4]).sharedAppBanner,
                     "Slack stopped the token: the row's Re-login state takes over")

        XCTAssertEqual(SlackModePresentation.sharedAppTag, "Shared app")
        XCTAssertEqual(SlackModePresentation.sharedAppAccountLine(lastSync: now.addingTimeInterval(-180), now: now),
                       "Syncing through the shared app · last sync 3 min ago")
        XCTAssertEqual(SlackModePresentation.sharedAppAccountLine(lastSync: nil, now: now),
                       "Syncing through the shared app")
        XCTAssertEqual(SlackModePresentation.reloginTitle(isOK: true, relogin: "move"), "Move to Full")
        XCTAssertEqual(SlackModePresentation.reloginTitle(isOK: false, relogin: "move"), "Move to Full")
        XCTAssertEqual(SlackModePresentation.reloginTitle(isOK: true, relogin: "connect"), "Reconnect")
        XCTAssertEqual(SlackModePresentation.reloginTitle(isOK: false, relogin: "builtin"), "Re-login")
        XCTAssertEqual(SlackModePresentation.reloginTitle(isOK: true, relogin: nil), "Reconnect", "flags not read yet")
    }

    /// §5: the overview card reads "Shared app retiring"; the account is OK,
    /// so the card's status (and the badge) stay the accounts' own.
    func testSharedAppIsNotAttention() {
        let acme = account(id: 4)
        XCTAssertEqual(SlackModePresentation.overviewStatusLine(accounts: [acme], sharedAppAccountIDs: [4]),
                       "Shared app retiring")
        XCTAssertNil(SlackModePresentation.overviewStatusLine(accounts: [acme], sharedAppAccountIDs: []))
        XCTAssertNil(SlackModePresentation.overviewStatusLine(
            accounts: [account(id: 4, enabled: false)], sharedAppAccountIDs: [4]))
        XCTAssertNil(SlackModePresentation.overviewStatusLine(
            accounts: [account(id: 4, status: "revoked")], sharedAppAccountIDs: [4]), "a stopped token is a problem")
        XCTAssertTrue(acme.isOK, "nothing about the shared app turns the account into a problem")
        XCTAssertEqual(make(accounts: [acme], shared: [4]).chipTone, .warning, "a warning, never an error")
    }

    // MARK: - §1.2 Live rows

    func testRowsClaudeFirstThenCodex() {
        let p = make(rows: [row("codex", "ok", team: "T0ACME", ago: 10), row("claude", "no_plan", ago: 20)])
        XCTAssertEqual(p.liveRows.map(\.provider), ["Claude", "ChatGPT (Codex)"])
    }

    func testOKIdentifiedTeamsUseLabels() {
        let acme = account(id: 1, teamID: "T0ACME", name: "acme", label: "Acme HQ")
        let rows = [
            row("claude", "ok", team: "", ago: 60), row("claude", "ok", team: "T0ACME", ago: 60),
            row("claude", "ok", team: "T0BETA", ago: 60)
        ]
        let live = make(accounts: [acme], rows: rows).liveRows[0]
        XCTAssertEqual(live.status, "On · Acme HQ, T0BETA")
        XCTAssertNil(live.reason)
        XCTAssertEqual(live.tone, .success)
    }

    func testOKUnidentified() {
        let live = make(rows: [row("claude", "ok")]).liveRows[0]
        XCTAssertEqual(live.status, "On · workspace not identified")
        XCTAssertEqual(live.reason, "Chats use it; Watchtower could not tell which workspace it reads.")
        XCTAssertEqual(live.tone, .success)
    }

    /// The provider's newest check decides; an older verdict does not linger.
    func testNewestRowDecides() {
        let rows = [row("claude", "not_connected", errorClass: "disabled", ago: 10), row("claude", "ok", team: "T0ACME", ago: 900)]
        let p = make(rows: rows)
        XCTAssertEqual(p.display, .off, "the chip reads the same verdict as the block")
        XCTAssertEqual(make(accounts: [account()], rows: rows).display, .full, "not Full · Live on")
        let live = p.liveRows
        XCTAssertEqual(live.count, 1)
        XCTAssertEqual(live[0].status, "Not connected")
        XCTAssertEqual(live[0].reason, "The Slack connector is switched off in Watchtower's chat settings.")
    }

    func testNotConnectedReasons() {
        let cases: [(String, String, String)] = [
            ("claude", "cli_missing", "Claude Code is not installed on this Mac."),
            ("codex", "cli_missing", "Codex is not installed on this Mac."),
            ("claude", "connectors_off", "Connectors are off in Watchtower's chat settings."),
            ("claude", "disabled", "The Slack connector is switched off in Watchtower's chat settings."),
            ("claude", "policy", "Your organization's policy turns this off."),
            ("claude", "workspace_not_connected", "The connector reads a different Slack workspace."),
            ("codex", "connector_id_unknown", "Codex has not loaded its Slack app yet. Check again later."),
            ("claude", "no_connector", "Turn on the Slack connector in your Claude or ChatGPT account."),
            ("claude", "", "Turn on the Slack connector in your Claude or ChatGPT account.")
        ]
        for (provider, errorClass, reason) in cases {
            let live = make(rows: [row(provider, "not_connected", errorClass: errorClass)]).liveRows[0]
            XCTAssertEqual(live.status, "Not connected", errorClass)
            XCTAssertEqual(live.reason, reason, errorClass)
            XCTAssertEqual(live.tone, .gray, errorClass)
        }
    }

    func testOtherStatuses() {
        struct Case { let status, errorClass, text, reason: String; let tone: SlackModeTone }
        let cases: [Case] = [
            Case(status: "needs_admin", errorClass: "", text: "Waiting for your Slack admin",
                 reason: "Your workspace admin must approve the connector.", tone: .warning),
            Case(status: "no_plan", errorClass: "", text: "Not in your plan",
                 reason: "Your plan has no Slack connector.", tone: .gray),
            Case(status: "unavailable", errorClass: "sandbox", text: "Unavailable",
                 reason: "The chat sandbox is not available on this Mac.", tone: .warning),
            Case(status: "unavailable", errorClass: "timeout", text: "Unavailable",
                 reason: "The connector did not answer. Check again later.", tone: .warning)
        ]
        for item in cases {
            let live = make(rows: [row("claude", item.status, errorClass: item.errorClass)]).liveRows[0]
            XCTAssertEqual(live.status, item.text, item.status)
            XCTAssertEqual(live.reason, item.reason, item.status)
            XCTAssertEqual(live.tone, item.tone, item.status)
        }
    }

    func testAgeWording() {
        let cases: [(TimeInterval, String)] = [
            (0, "checked just now"), (59, "checked just now"), (60, "checked 1 min ago"),
            (59 * 60, "checked 59 min ago"), (60 * 60, "checked 1 h ago"), (47 * 3600, "checked 47 h ago"),
            (48 * 3600, "checked 2 d ago"), (5 * 86400, "checked 5 d ago")
        ]
        for (ago, text) in cases {
            XCTAssertEqual(make(rows: [row("claude", "no_plan", ago: ago)]).liveRows[0].age, text, "\(ago)")
        }
    }

    func testUnreadableStampHasNoAge() {
        let bad = SlackLiveStatusRow(teamID: "", provider: "claude", status: "no_plan", errorClass: "",
                                     connectorID: "", checkedAt: "garbage")
        XCTAssertNil(make(rows: [bad]).liveRows[0].age)
    }

    // MARK: - §1.2 block states and actions

    func testLoading() {
        let p = make(hasRead: false)
        XCTAssertEqual(p.liveBlock, .loading)
        XCTAssertEqual(p.liveTitle, "Live")
        XCTAssertEqual(p.loadingLine, "Reading the Live status…")
        XCTAssertFalse(p.showsCheckAgain)
        XCTAssertFalse(p.showsTryAgain)
    }

    func testEmpty() {
        let p = make()
        XCTAssertEqual(p.liveBlock, .empty)
        XCTAssertEqual(p.emptyLine, "Live has not been checked yet.")
        XCTAssertTrue(p.showsCheckAgain)
        XCTAssertTrue(p.checkAgainEnabled)
        XCTAssertEqual(p.checkAgain, "Check again")
        XCTAssertNil(p.busyLine)
        XCTAssertNil(p.problem)
    }

    func testBusyKeepsRows() {
        let p = make(accounts: [account()], rows: [row("claude", "ok", team: "T0ACME")], isRunning: true)
        XCTAssertEqual(p.liveBlock, .rows)
        XCTAssertEqual(p.liveRows.count, 1)
        XCTAssertTrue(p.isBusy)
        XCTAssertTrue(p.showsCheckAgain)
        XCTAssertFalse(p.checkAgainEnabled)
        XCTAssertEqual(p.busyLine, "Checking Live… this takes a few seconds.")
    }

    func testProbeFailedKeepsCheckAgain() {
        let error = SlackLiveError(provider: "claude", message: "the watchtower command did not answer in 150 seconds",
                                   kind: .probe)
        let p = make(rows: [row("claude", "ok", team: "T0ACME")], lastError: error)
        XCTAssertEqual(p.liveBlock, .rows)
        XCTAssertEqual(p.liveRows.count, 1)
        XCTAssertEqual(p.problem,
                       "The Claude Live Slack check failed: the watchtower command did not answer in 150 seconds.")
        XCTAssertTrue(p.showsCheckAgain)
        XCTAssertTrue(p.checkAgainEnabled)
        XCTAssertFalse(p.showsTryAgain)

        let codex = make(lastError: SlackLiveError(provider: "codex", message: "boom.", kind: .probe))
        XCTAssertEqual(codex.problem, "The ChatGPT (Codex) Live Slack check failed: boom.")
    }

    func testReadFailedOffersTryAgainHidesCheckAgain() {
        let error = SlackLiveError(provider: "", message: "database is locked", kind: .read)
        let p = make(rows: [row("claude", "ok", team: "T0ACME")], lastError: error)
        XCTAssertEqual(p.liveBlock, .rows, "the rows read before stay")
        XCTAssertEqual(p.problem, "Could not read the Live Slack status: database is locked.")
        XCTAssertTrue(p.showsTryAgain)
        XCTAssertEqual(p.tryAgain, "Try again")
        XCTAssertFalse(p.showsCheckAgain)

        XCTAssertEqual(make(lastError: error).liveBlock, .readFailed, "nothing read yet: only the warning")
    }
}
