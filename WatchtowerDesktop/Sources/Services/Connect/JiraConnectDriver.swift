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
    /// The site `set_fields` named, for the next start or the running flow's question.
    private var pendingSite: String?
    /// The site ids before this driver's last connect: boards and spaces
    /// list the sites it added (`JiraBoardPicker.sites`).
    private var idsBefore: Set<Int>?
    /// The boards the last `choose jira_boards` listed.
    private var listedBoards: [JiraBoard] = []

    init(
        model: any JiraConnectModel,
        steps: any JiraConnectSteps,
        policy: @escaping @MainActor () -> ManagedPolicy,
        companySlug: @escaping @MainActor () -> String?
    ) {
        self.model = model
        self.steps = steps
        self.policy = policy
        self.companySlug = companySlug
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
        let asking = flows.current != nil && model.siteChoices != nil
        return ConnectStatus(service: service, accounts: rows.map(\.account), policyLocked: !policyAllows(),
                             flow: flows.statusFlow(state: asking ? Self.siteQuestionState : "running"))
    }

    /// The flow's state while Watchtower asks which site to add.
    static let siteQuestionState = "choose_site"

    func start(options: [String: String]) async -> Result<String, ConnectDriverError> {
        let allowed: Set<String> = ["site", "with_confluence"]
        if let refusal = ConnectOptions.unknown(options, allowed: allowed, service: service) { return .failure(refusal) }
        guard !model.isConnecting, flows.current == nil else { return .failure(.busy) }
        let withConfluence = options["with_confluence"] == "true"
        let site = options["site"].flatMap { $0.isEmpty ? nil : $0 } ?? pendingSite
        pendingSite = nil
        let before = Set(model.accounts.map(\.id))
        idsBefore = before
        listedBoards = []
        let company = companySlug()
        return .success(flows.begin { [model, steps, flows] id in
            let end = await model.addAccount(
                withConfluence: withConfluence, company: company, site: site, daemonPolicy: .restart)
            await model.refreshAsync()
            // A Cancel that came too late still added the site (`.cancelledAfterConnecting`).
            if end == .cancelled { return .failed(reason: ConnectFlowBook.cancelled) }
            let outcome = ConnectOutcome.of(
                error: model.error, before: Set(before.map(String.init)),
                after: model.accounts.map { ConnectAccountRow(id: $0.id, ConnectionAccountState($0)) },
                cancelled: flows.wasCancelled(id), noun: "site")
            guard withConfluence, case let .connected(name) = outcome else { return outcome }
            let line = await steps.confluenceLine(accountIDsBefore: before)
            return .connected(account: line.isEmpty ? name : "\(name). \(line)")
        })
    }

    func wait(flowID: String) async -> ConnectWaitOutcome {
        if flows.current == flowID, let site = pendingSite, let choices = model.siteChoices,
           let pick = Self.match(site, in: choices) {
            pendingSite = nil
            model.chooseSite(pick)
        }
        return flows.outcome(of: flowID)
    }

    func cancel(flowID: String) async {
        if flows.cancel(flowID) { model.cancelConnect() }
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
            model.chooseSite(pick)
            return .success(())
        }
        // Before the question shows (or before a start): `wait` or the next start uses it.
        pendingSite = site
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
