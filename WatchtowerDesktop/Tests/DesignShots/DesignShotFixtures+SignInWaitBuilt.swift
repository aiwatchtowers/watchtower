import AppKit
import DesignKit
import GRDB
import SwiftUI
import WatchtowerCore
import WatchtowerTestSupport
@testable import WatchtowerDesktop

/// Cancel for a waiting browser sign-in (#2132), as built: the production
/// rows, sections and cards with a sign-in held in the browser, for a
/// by-eye comparison with the `sign-in-wait-*` mockups
/// (`docs/design/mockups/sign-in-cancel/implemented/`). Each view model runs
/// its real start: a stub CLI that blocks until `cleanUp` (Slack, Jira,
/// Confluence, Quick Connections) or a held scripted CLI (the company models). Sample data only (`acme` / `example.com`).
@MainActor
enum SignInWaitBuiltShots {
    /// One shot per place; a Google place is one more case and its view.
    enum Frame: String, CaseIterable {
        case slackRow = "row-slack"
        case jiraRow = "row-jira"
        case quickRow = "row-quick"
        case narrow = "row-narrow"
        case confluence = "section-confluence"
        case ownGoogle = "section-own-google"
        case companyCard = "company-card"
        case chatCard = "chat-card"
        case wizardCheck = "wizard-check"
        case googleRow = "row-google"
        case connectCalendar = "section-connect-calendar"
        case calendarTop = "calendar-top"

        /// A zero height means "as tall as the content". The Jira pane scrolls, so its shot keeps the top: the
        /// sites and Add an account (the sections below read the live CLI, which a test process has none of).
        var size: NSSize {
            switch self {
            case .narrow: NSSize(width: 420, height: 0)
            case .jiraRow: NSSize(width: 680, height: 300)
            case .calendarTop: NSSize(width: 680, height: 560)
            default: NSSize(width: 680, height: 0)
            }
        }
    }

    static var shots: [DesignShot] { Frame.allCases.map(shot) }

    /// The company models are driven by spinning the run loop
    /// (`CompanyWizardLive`), so they build at once; the others await their
    /// stub's start.
    private static func shot(_ frame: Frame) -> DesignShot {
        let name = "sign-in-wait-built-\(frame.rawValue)"
        if let make = madeAtOnce(frame) {
            return DesignShot(name: name, size: frame.size) { framed(make()) }
        }
        return DesignShot(name: name, prepare: { framed(try await awaited(frame)) }, size: frame.size)
    }

    private static func framed(_ view: AnyView) -> AnyView {
        AnyView(view
            .padding(Spacing.large)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .detailBackground())
    }

    // MARK: - Teardown

    /// The held sign-ins of the rendered shots: each Cancel, then the stubs.
    private static var cancels: [@MainActor () -> Void] = []
    private static var stubs: [GatedLoginStub] = []
    private static var gates: [AsyncGate] = []
    private static var paths: [String] = []

    static func cleanUp() {
        cancels.forEach { $0() }
        stubs.forEach { $0.reap() }
        gates.forEach { $0.release() }
        gates = []
        paths.forEach(TestDatabase.cleanup(path:))
        cancels = []
        stubs = []
        paths = []
    }

    struct Unbuilt: Error {
        let what: String
    }

    // MARK: - Views

    private static func madeAtOnce(_ frame: Frame) -> (() -> AnyView)? {
        switch frame {
        case .ownGoogle: { OwnGoogleLive.page("checking") }
        case .companyCard: { companyCard }
        case .chatCard: { ApprovalCardShotFixtures.slackReconnectWaiting() }
        case .wizardCheck: { wizardCheck }
        case .slackRow, .narrow, .jiraRow, .quickRow, .confluence, .googleRow, .connectCalendar, .calendarTop: nil
        }
    }

    private static func awaited(_ frame: Frame) async throws -> AnyView {
        switch frame {
        case .slackRow, .narrow: try await slackPane()
        case .jiraRow: try await jiraPane()
        case .quickRow: try await quickRows()
        case .confluence: try await confluenceSection()
        case .googleRow: try await googlePane(.relogin)
        case .connectCalendar: try await googlePane(.connectCalendar)
        case .calendarTop: try await calendarTop()
        case .ownGoogle, .companyCard, .chatCard, .wizardCheck: AnyView(EmptyView()) // built at once
        }
    }

    /// S1: Connections → Slack with the second workspace's Re-login waiting
    /// on a stub `slack login`.
    private static func slackPane() async throws -> AnyView {
        let stub = try GatedLoginStub()
        stubs.append(stub)
        let (manager, path) = try TestDatabase.createDatabaseManager()
        paths.append(path)
        let pool = manager.dbPool
        let waitingID = try await pool.write { db -> Int64 in
            try TestDatabase.insertSlackAccount(db, teamID: "T0ACME", teamName: "Acme", teamDomain: "acme")
            return try TestDatabase.insertSlackAccount(db, teamID: "T0EXAMPLE", teamName: "Example", teamDomain: "example",
                                                       status: "error", error: "token expired or revoked")
        }
        let appState = AppState.isolated()
        appState.databaseManager = manager
        appState.initSlackAccounts(dbPool: pool) { stub.path }
        guard let vm = appState.slackAccountsViewModel else { throw Unbuilt(what: "the Slack accounts") }
        vm.loginEnvironment = { [:] }
        await vm.refreshAsync()
        guard let account = vm.accounts.first(where: { Int64($0.id) == waitingID }) else {
            throw Unbuilt(what: "the waiting workspace")
        }
        let run = Task { _ = await vm.relogin(account) }
        _ = try await stub.nextRun(or: run)
        cancels.append { vm.cancelConnect() }
        return AnyView(SlackConnectionDetail(config: appState.sharedConfig, flow: appState.slackAuthFlow)
            .environment(appState))
    }

    // MARK: - Google (G1–G4)

    /// Which Google sign-in the shot holds.
    private enum GoogleStart { case relogin, connectCalendar }

    /// A Google model over two accounts (the second's Calendar broken), its
    /// sign-in held before the CLI launches (the login environment waits on a
    /// gate `cleanUp` opens), so no process runs.
    private static func googleModel() async throws -> (GoogleAccountsViewModel, DatabaseManager, GoogleAccount) {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        paths.append(path)
        try await manager.dbPool.write { db in
            _ = try TestDatabase.insertGoogleAccount(db, email: "owner@example.com", calendarEnabled: true, gmailEnabled: true)
            _ = try TestDatabase.insertGoogleAccount(db, email: "team@acme.example", calendarEnabled: true,
                                                     status: "error", error: "token expired or revoked")
        }
        let vm = GoogleAccountsViewModel(dbPool: manager.dbPool, daemon: FakeDaemonRestarter()) { "/usr/bin/false" }
        let gate = AsyncGate()
        gates.append(gate)
        vm.loginEnvironment = { await gate.wait(); return [:] }
        await vm.refreshAsync()
        guard let broken = vm.accounts.first(where: { $0.status == "error" }) else {
            throw Unbuilt(what: "the Google account")
        }
        cancels.append { vm.cancelConnect() }
        return (vm, manager, broken)
    }

    /// G1 and G2: Connections → Google with a row's Re-login, or Connect
    /// Google Calendar, waiting.
    private static func googlePane(_ start: GoogleStart) async throws -> AnyView {
        let (vm, _, broken) = try await googleModel()
        let (appState, _) = LinearConnectionDetailTests.wired()
        appState.googleAccountsViewModel = vm
        switch start {
        case .relogin: vm.relogin(broken)
        case .connectCalendar: vm.addAccount(calendar: true, gmail: false, clientID: "", clientSecret: "")
        }
        return AnyView(GoogleConnectionDetail(config: appState.sharedConfig).environment(appState))
    }

    /// G4: Calendar with the revoked-calendar alert's legacy sign-in waiting
    /// at its top. (G3's banner needs Calendar's connected state and sync
    /// health, which the view reads from the live Google auth service and
    /// daemon into private state: no shot reaches it.)
    private static func calendarTop() async throws -> AnyView {
        let (vm, manager, _) = try await googleModel()
        let appState = AppState.isolated()
        appState.databaseManager = manager
        appState.googleAccountsViewModel = vm
        appState.reconnectGoogleCalendar(accountID: nil)
        return AnyView(CalendarEventsView().environment(appState))
    }

    /// A1: Connections → Jira with the second site's Re-login waiting on a
    /// stub `jira login`.
    private static func jiraPane() async throws -> AnyView {
        let stub = try GatedLoginStub()
        stubs.append(stub)
        let (pool, path) = try TestDatabase.createPool()
        paths.append(path)
        try await pool.write { db in
            try TestDatabase.insertJiraAccount(db, siteURL: "https://acme.atlassian.net", siteName: "acme")
            try TestDatabase.insertJiraAccount(db, siteURL: "https://example.atlassian.net", siteName: "example",
                                               status: "error", error: "token expired")
        }
        let vm = JiraAccountsViewModel(dbPool: pool, daemon: FakeDaemonRestarter()) { stub.path }
        await vm.refreshAsync()
        guard let account = vm.accounts.first(where: { $0.status == "error" }) else { throw Unbuilt(what: "the Jira site") }
        let (appState, _) = LinearConnectionDetailTests.wired()
        appState.jiraAccountsViewModel = vm
        let run = Task { await vm.relogin(account) }
        _ = try await stub.nextRun(or: run)
        cancels.append { vm.cancelConnect() }
        return AnyView(JiraConnectionDetail().environment(appState))
    }

    /// Q1: two Quick Connections, the first one's Sign in again waiting.
    private static func quickRows() async throws -> AnyView {
        let stub = try GatedLoginStub()
        stubs.append(stub)
        let (pool, path) = try TestDatabase.createPool()
        paths.append(path)
        let vm = ExternalConnectionsViewModel(dbPool: pool, makeRunner: { nil }, cliPath: { stub.path })
        let wiki = ExternalConnection(row: Row(["id": 3, "name": "acme-wiki", "kind": "http", "status": "revoked",
                                                "enabled": true]))
        let docs = ExternalConnection(row: Row(["id": 4, "name": "example-docs", "kind": "http", "status": "ok",
                                                "enabled": true]))
        let run = Task { await vm.signInAgain(wiki) }
        _ = try await stub.nextRun(or: run)
        cancels.append { vm.cancelSignIn() }
        return AnyView(Form {
            Section("Quick Connections") {
                ForEach([wiki, docs], id: \.id) { connection in
                    QuickConnectionRow(connection: connection, vm: vm, policy: .none) {}
                }
            }
        }
        .formStyle(.grouped)
        .controlSize(.small))
    }

    /// A2: Connections → Jira → Confluence, Grant Confluence access waiting
    /// on the site's stub `jira login --with-confluence`.
    private static func confluenceSection() async throws -> AnyView {
        let stub = try GatedLoginStub()
        stubs.append(stub)
        let (manager, path) = try TestDatabase.createDatabaseManager()
        paths.append(path)
        try await manager.dbPool.write { db in
            try TestDatabase.insertJiraAccount(db, siteURL: "https://acme.atlassian.net", siteName: "acme")
        }
        let jira = JiraAccountsViewModel(dbPool: manager.dbPool, daemon: FakeDaemonRestarter()) { stub.path }
        await jira.refreshAsync()
        guard let account = jira.accounts.first else { throw Unbuilt(what: "the Jira site") }
        let appState = AppState.isolated()
        appState.databaseManager = manager
        appState.jiraAccountsViewModel = jira
        guard let vm = appState.confluenceSpacesViewModel(forJiraAccount: Int64(account.id), runner: NoConsentRunner())
        else { throw Unbuilt(what: "the Confluence section") }
        await vm.load()
        let run = Task { await vm.reconsentAsync() }
        _ = try await stub.nextRun(or: run)
        cancels.append { vm.cancelReconsent() }
        return AnyView(ConfluenceSpacesSection(account: account, title: "Confluence")
            .environment(appState)
            .controlSize(.small))
    }

    /// Answers `confluence spaces` with the consent error, so the section
    /// asks for Confluence access. No process.
    private final class NoConsentRunner: CLIRunnerProtocol, @unchecked Sendable {
        func run(args: [String]) async throws -> Data {
            guard args.dropFirst().first == "spaces" else { return Data(#"{"read":false,"write":false}"#.utf8) }
            throw CLIRunnerError.nonZeroExit(
                code: 1, stderr: "Confluence access not granted — run: watchtower jira login --account 1 --with-confluence")
        }

        func run(args: [String], timeout: TimeInterval) async throws -> Data { try await run(args: args) }
    }

    /// C1: the company card while its chain waits on Google, its sheet closed.
    private static var companyCard: AnyView {
        let zone = CompanyConnectionsPresentation.zone(
            companies: [CompaniesZoneScenes.acme], errors: [], draft: nil,
            accounts: [AccountRef(vendor: .slack, accountID: 1, label: "acme", companySlug: "acme", status: "ok", error: "")],
            portBusy: false, loading: false)
        return AnyView(CompaniesZone(state: zone, model: CompaniesZoneModel { nil }, connecting: (slug: "acme", vendor: .google),
                                     flowBusy: true, actions: CompaniesZoneActions())
            .controlSize(.small))
    }

    /// C2: the setup wizard's Google step, its sign-in check waiting.
    private static var wizardCheck: AnyView {
        AnyView(CompanySetupVendorStep(model: CompanyWizardLive.wizardModel("google-checking"), vendor: .google,
                                       selection: .constant(0)))
    }
}
