import Foundation
import GRDB
import WatchtowerCore

/// What the Jira driver uses of `JiraAccountsViewModel`: the add sheet's own
/// `jira add --app-site-picker` flow, its site question and its one-flow
/// rule (`isConnecting`).
@MainActor
protocol JiraConnectModel: AnyObject {
    var isConnecting: Bool { get }
    var error: String? { get }
    var accounts: [JiraAccount] { get }
    /// The running flow's site question, while it waits for an answer.
    var siteChoices: [JiraSiteChoice]? { get }
    /// The last `addAccount` that ended `.finished` saved its site (the CLI
    /// succeeded); false after an interrupted or failed one.
    var lastAuthFlowWroteAccount: Bool { get }
    /// The driver passes `.deferred` and restarts the daemon itself: the
    /// sheet's held restart (`addAccountHoldingRestart`/`finishBoardStep`)
    /// stays the sheet's alone.
    func addAccount(
        withConfluence: Bool, company: String?, site: String?, daemonPolicy: DaemonRestartPolicy
    ) async -> JiraAccountsViewModel.AuthFlowEnd
    func chooseSite(_ site: JiraSiteChoice)
    func cancelConnect()
    func refreshAsync() async
}

extension JiraAccountsViewModel: JiraConnectModel {}

/// The add sheet's steps after the sign-in: the Confluence selection line,
/// the board step and the Confluence spaces, on the same CLI verbs.
@MainActor
protocol JiraConnectSteps: AnyObject {
    /// `ConfluenceConnectSelection.run(accountIDsBefore:)`'s line.
    func confluenceLine(accountIDsBefore: Set<Int>?) async -> String
    /// Fetches the sites' boards from Jira (`jira --account N boards`) and
    /// reads them back; a failed fetch still lists what is stored.
    func boards(of sites: [JiraAccount]) async -> (boards: [JiraBoard], failure: String?)
    /// Runs `JiraBoardPicker.invocations`; nil when all succeeded.
    func saveBoards(_ calls: [[String]]) async -> String?
    /// The site's Confluence spaces with the synced ones marked.
    func spaces(accountID: Int) async -> Result<[ConnectChoice], ConnectDriverError>
    /// Selects the spaces; nil when all succeeded.
    func selectSpaces(_ keys: [String], accountID: Int) async -> String?
}

/// The jira and confluence playbooks' driver (docs/guide/connect/jira.md,
/// confluence.md). `site` names the site up front; `with_confluence` asks
/// for Confluence in the same consent. The sign-in goes through the stored
/// company's Atlassian app (`--company`): the public build has none of its
/// own. A `set_fields site` while the flow asks which site answers that
/// question; before a flow it is the next start's site.
@MainActor
final class JiraConnectDriver: ConnectServiceDriving {
    let service = "jira"
    let secretKinds: Set<String> = []
    let flows = ConnectFlowBook(service: "jira")

    private let model: any JiraConnectModel
    private let steps: any JiraConnectSteps
    private let policy: @MainActor () -> ManagedPolicy
    private let companySlug: @MainActor () -> String?
    /// The site `set_fields` named before the site question showed: for the
    /// next start (`flow` nil) or for that flow's question only.
    private var pendingSite: (flow: String?, site: String)?
    /// A site this driver added waits for the daemon restart until the
    /// boards are picked, the run ends, or the next start (the sheet's board
    /// step, #572). The driver's own state: the sheet's held restart in
    /// `JiraAccountsViewModel` is never read or released here.
    private var restartPending = false
    /// The run ended (`runEnded`) since the last start: a connect that
    /// finishes later restarts at once, as nothing would release it.
    private var runOver = false
    private let daemon: any DaemonRestarting
    /// `AppState.accountDaemonPolicy`, read when a restart is released:
    /// during onboarding a connect leaves the daemon to onboarding's finish,
    /// as the sheet does.
    private let daemonPolicy: @MainActor () -> DaemonRestartPolicy
    /// The last restart this driver kicked off (tests await it).
    private(set) var restartTask: Task<Void, Never>?
    /// The site ids before this driver's last connect: boards and spaces
    /// list the sites it added (`JiraBoardPicker.sites`).
    private var idsBefore: Set<Int>?
    /// The boards the last `choose jira_boards` listed.
    private var listedBoards: [JiraBoard] = []

    init(
        model: any JiraConnectModel,
        steps: any JiraConnectSteps,
        policy: @escaping @MainActor () -> ManagedPolicy,
        companySlug: @escaping @MainActor () -> String?,
        daemon: any DaemonRestarting = LiveDaemonRestarter(),
        daemonPolicy: @escaping @MainActor () -> DaemonRestartPolicy = { .restart }
    ) {
        self.model = model
        self.steps = steps
        self.policy = policy
        self.companySlug = companySlug
        self.daemon = daemon
        self.daemonPolicy = daemonPolicy
    }

    /// The stored company whose Atlassian app personal sign-ins use: the
    /// forced (MDM) one first, else the first with an Atlassian block. A
    /// personal bundle (an own Google project) never carries one.
    static func companySlug(_ companies: [CompanyRef]) -> String? {
        let withAtlassian = companies.filter { !$0.personal && $0.vendors[.atlassian] != nil }
        return (withAtlassian.first(where: \.forced) ?? withAtlassian.first)?.slug
    }

    private var rows: [ConnectAccountRow] {
        model.accounts.map { ConnectAccountRow(id: $0.id, ConnectionAccountState($0)) }
    }

    func status() async -> ConnectStatus {
        let state = flows.current != nil ? model.siteChoices.map(Self.siteQuestion) ?? "running" : "running"
        return ConnectStatus(service: service, accounts: rows.map(\.account), policyLocked: !policyAllows(),
                             flow: flows.statusFlow(state: state))
    }

    /// The flow's state while Watchtower asks which site to add: the prefix,
    /// then each site's name and address, so the agent can ask the customer.
    static let siteQuestionState = "choose_site"

    static func siteQuestion(_ choices: [JiraSiteChoice]) -> String {
        "\(siteQuestionState): " + choices.map { "\($0.name) (\($0.url))" }.joined(separator: "; ")
    }

    func start(options: [String: String]) async -> Result<String, ConnectDriverError> {
        let allowed: Set<String> = ["site", "with_confluence"]
        if let refusal = ConnectOptions.unknown(options, allowed: allowed, service: service) { return .failure(refusal) }
        guard !model.isConnecting, flows.current == nil else { return .failure(.busy) }
        releaseRestart()  // a pending restart from the last connect is not lost to this one
        runOver = false
        let withConfluence = options["with_confluence"] == "true"
        let named = options["site"].flatMap { $0.isEmpty ? nil : $0 }
        let site = named ?? (pendingSite?.flow == nil ? pendingSite?.site : nil)
        pendingSite = nil
        let before = Set(model.accounts.map(\.id))
        idsBefore = before
        listedBoards = []
        let company = companySlug()
        return .success(flows.begin { [model, steps, flows, weak self] id in
            let end = await model.addAccount(
                withConfluence: withConfluence, company: company, site: site, daemonPolicy: .deferred)
            self?.dropPendingSite(of: id)
            let addError = model.error
            let wrote = end == .finished && addError == nil && model.lastAuthFlowWroteAccount
            await model.refreshAsync()
            let reloadFailed = model.error != nil && model.error != addError
            let added = model.accounts.contains { !before.contains($0.id) }
            // The restart follows what the add wrote, not the reload or a
            // late Cancel: a site was saved when the list shows a new one,
            // when the Cancel came after the save, or when the add reports
            // the CLI's success but the list could not be re-read. Its
            // restart waits for the board pick, unless no board step follows
            // or the run is over.
            if added || end == .cancelledAfterConnecting || (wrote && reloadFailed) {
                self?.siteAdded(boardStepFollows: end == .finished)
            }
            if end == .cancelled, !added { return .failed(reason: ConnectFlowBook.cancelled) }
            let outcome = ConnectOutcome.of(
                error: model.error, before: Set(before.map(String.init)),
                after: model.accounts.map { ConnectAccountRow(id: $0.id, ConnectionAccountState($0)) },
                cancelled: flows.wasCancelled(id), noun: "site")
            guard withConfluence, case let .connected(name) = outcome else { return outcome }
            let line = await steps.confluenceLine(accountIDsBefore: before)
            return .connected(account: line.isEmpty ? name : "\(name). \(line)")
        })
    }

    private func siteAdded(boardStepFollows: Bool) {
        restartPending = true
        if !boardStepFollows || runOver { releaseRestart() }
    }

    /// The pending daemon restart runs now, on the driver's own path.
    private func releaseRestart() {
        guard restartPending else { return }
        restartPending = false
        restartTask = daemonPolicy().apply(using: daemon)
    }

    /// The run is over: a pending restart runs now, and a connect that
    /// finishes later runs its own at once. At app quit the restart is a
    /// queued daemon restart that may not finish; the next launch starts
    /// the daemon with the new site anyway.
    func runEnded() {
        runOver = true
        releaseRestart()
    }

    private func dropPendingSite(of flowID: String) {
        if pendingSite?.flow == flowID { pendingSite = nil }
    }

    func wait(flowID: String) async -> ConnectWaitOutcome {
        if flows.current == flowID, let pending = pendingSite, pending.flow == flowID,
           let choices = model.siteChoices, let pick = Self.match(pending.site, in: choices) {
            pendingSite = nil
            model.chooseSite(pick)
        }
        return flows.outcome(of: flowID)
    }

    func cancel(flowID: String) async {
        guard flows.cancel(flowID) else { return }
        dropPendingSite(of: flowID)
        model.cancelConnect()
    }

    func setFields(_ fields: [String: String]) async -> Result<Void, ConnectDriverError> {
        let extra = fields.keys.filter { $0 != "site" }.sorted()
        guard extra.isEmpty else { return .failure(.badArgs("Jira has no field \(extra.joined(separator: ", "))")) }
        guard let site = fields["site"]?.trimmingCharacters(in: .whitespacesAndNewlines), !site.isEmpty else {
            return .failure(.badArgs("site is the site's address, like acme.atlassian.net"))
        }
        if flows.current != nil, let choices = model.siteChoices {
            guard let pick = Self.match(site, in: choices) else {
                return .failure(.badArgs("\(site) is not one of: \(choices.map(\.url).joined(separator: ", "))"))
            }
            pendingSite = nil
            model.chooseSite(pick)
            return .success(())
        }
        // Before the question shows: that flow's `wait` answers with it; with
        // no flow, the next start passes it as `--site`.
        pendingSite = (flows.current, site)
        return .success(())
    }

    /// The one choice whose URL or name holds `site`, as `jira add --site` matches.
    static func match(_ site: String, in choices: [JiraSiteChoice]) -> JiraSiteChoice? {
        let needle = site.lowercased()
        let hits = choices.filter { $0.url.lowercased().contains(needle) || $0.name.lowercased().contains(needle) }
        return hits.count == 1 ? hits[0] : hits.first { $0.url.lowercased().hasSuffix("//\(needle)") }
    }

    func submitSecret(kind: String, value: String) async -> Result<Data, ConnectDriverError> {
        .failure(.badArgs("Jira takes no secret here"))
    }

    func choose(kind: String, select: [String]?) async -> Result<[ConnectChoice], ConnectDriverError> {
        switch kind {
        case "jira_boards": await chooseBoards(select)
        case "confluence_spaces": await chooseSpaces(select)
        default: .failure(.badArgs("Jira chooses jira_boards or confluence_spaces"))
        }
    }

    private func chooseBoards(_ select: [String]?) async -> Result<[ConnectChoice], ConnectDriverError> {
        var boards = listedBoards
        if boards.isEmpty || select == nil {
            let sites = JiraBoardPicker.sites(model.accounts, before: idsBefore)
            let fetched = await steps.boards(of: sites)
            if let failure = fetched.failure, fetched.boards.isEmpty { return .failure(.failed(failure)) }
            boards = fetched.boards
            listedBoards = boards
        }
        guard let select else { return .success(Self.choices(boards, chosen: JiraBoardPicker.selected(boards))) }
        let chosen = Set(select)
        let unknown = chosen.subtracting(boards.map(\.rowID)).sorted()
        guard unknown.isEmpty else { return .failure(.badArgs("no board \(unknown.joined(separator: ", "))")) }
        if let failure = await steps.saveBoards(JiraBoardPicker.invocations(for: boards, chosen: chosen)) {
            return .failure(.failed(failure))
        }
        listedBoards = []
        releaseRestart()  // the boards are picked: one restart wires the site and them in
        return .success(Self.choices(boards, chosen: chosen))
    }

    private static func choices(_ boards: [JiraBoard], chosen: Set<String>) -> [ConnectChoice] {
        boards.map { ConnectChoice(id: $0.rowID, name: "\($0.name) (\($0.projectKey))", selected: chosen.contains($0.rowID)) }
    }

    private func chooseSpaces(_ select: [String]?) async -> Result<[ConnectChoice], ConnectDriverError> {
        guard let site = JiraBoardPicker.sites(model.accounts, before: idsBefore).max(by: { $0.id < $1.id }) else {
            return .failure(.failed("no Jira site is connected"))
        }
        if let select, !select.isEmpty {
            let listed = await steps.spaces(accountID: site.id)
            guard case let .success(spaces) = listed else { return listed }
            let unknown = Set(select).subtracting(spaces.map(\.id)).sorted()
            guard unknown.isEmpty else { return .failure(.badArgs("no space \(unknown.joined(separator: ", "))")) }
            let picked = spaces.filter { select.contains($0.id) && !$0.selected }.map(\.id)
            if let failure = await steps.selectSpaces(picked, accountID: site.id) { return .failure(.failed(failure)) }
        }
        return await steps.spaces(accountID: site.id)
    }

    func confirmNeeded(tool: String, options: [String: String]) -> ConnectAssistantConfirm? {
        nil
    }

    func policyAllows() -> Bool {
        PolicySourceMap.allowed(service, policy: policy())
    }
}

/// The steps on the CLI and the database, as the add sheet runs them
/// (`JiraBoardChoiceView`, `ConfluenceConnectSelection`,
/// `ConfluenceSpacesViewModel`).
@MainActor
final class LiveJiraConnectSteps: JiraConnectSteps {
    private let dbPool: DatabasePool
    private let isConfluenceOff: @MainActor () -> Bool

    init(dbPool: DatabasePool, isConfluenceOff: @escaping @MainActor () -> Bool) {
        self.dbPool = dbPool
        self.isConfluenceOff = isConfluenceOff
    }

    func confluenceLine(accountIDsBefore: Set<Int>?) async -> String {
        let selection = ConfluenceConnectSelection(
            dbPool: dbPool, runner: ProcessCLIRunner.makeDefault(), isFeatureOff: isConfluenceOff)
        await selection.run(accountIDsBefore: accountIDsBefore)
        return selection.line ?? ""
    }

    func boards(of sites: [JiraAccount]) async -> (boards: [JiraBoard], failure: String?) {
        guard let cliPath = Constants.findCLIPath() else { return ([], "Watchtower CLI not found") }
        var failures: [String] = []
        for call in JiraAccountFanOut.invocations(for: sites, subcommand: ["boards"]) {
            if let failure = await JiraBoardsCLI.run(
                cliPath: cliPath, arguments: call.arguments, fallbackMessage: "failed to fetch boards") {
                failures.append("\(call.account.displayName): \(failure)")
            }
        }
        do {
            let all = try await dbPool.read { db in try JiraQueries.fetchAllBoards(db) }
            return (JiraBoardPicker.boards(all, of: sites), JiraAccountFanOut.failureMessage(failures))
        } catch {
            return ([], "Failed to load boards: \(error.localizedDescription)")
        }
    }

    func saveBoards(_ calls: [[String]]) async -> String? {
        guard !calls.isEmpty else { return nil }
        guard let cliPath = Constants.findCLIPath() else { return "Watchtower CLI not found" }
        var failures: [String] = []
        for arguments in calls {
            if let failure = await JiraBoardsCLI.run(
                cliPath: cliPath, arguments: arguments, fallbackMessage: "failed to save the board choice") {
                failures.append(failure)
            }
        }
        return JiraAccountFanOut.failureMessage(failures)
    }

    func spaces(accountID: Int) async -> Result<[ConnectChoice], ConnectDriverError> {
        let model = spacesModel(accountID)
        await model.load()
        if let error = model.errorMessage { return .failure(.failed(error)) }
        return .success(model.spaces.map { ConnectChoice(id: $0.key, name: $0.name, selected: $0.selected) })
    }

    func selectSpaces(_ keys: [String], accountID: Int) async -> String? {
        let model = spacesModel(accountID)
        for key in keys {
            await model.setSelected(key, true)
            if let error = model.errorMessage { return error }
        }
        return nil
    }

    private func spacesModel(_ accountID: Int) -> ConfluenceSpacesViewModel {
        ConfluenceSpacesViewModel(accountID: Int64(accountID), dbPool: dbPool, runner: ProcessCLIRunner.makeDefault())
    }
}
