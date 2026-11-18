import Foundation
import Observation

/// How the admin's own connect ended (plan B A4): the setup mirrors it as its
/// fourth step.
package enum SlackSetupConnectOutcome: Equatable, Sendable {
    case connected
    /// Slack sent the workspace admin an install request (spike Q5).
    case approvalRequested
    /// Cancelled, failed, or no connect flow to run: the app exists, the
    /// owner is not connected through it yet.
    case notConnected
}

/// The connect flow the setup starts for the admin's own account
/// (`SlackConnectFlowModel`, plan B Task 14): skip-confirm, returns once the
/// flow ends.
@MainActor
package protocol SlackSetupConnectStarting: AnyObject {
    func connectForSetup(teamID: String, clientID: String) async -> SlackSetupConnectOutcome
}

/// One `slack_app_setups` record as `slack app status --json` reports it.
package struct SlackSetupRecord: Decodable, Equatable, Sendable, Identifiable {
    package var id: String { teamID }
    package let teamID: String
    package let teamName: String
    package let appID: String
    package let clientID: String
    package let connected: Bool
    package let linkWritten: Bool
    package let installRequested: Bool
    /// `pending_create` | `install` | `approval` | `link_missing` | `done` (Go decides).
    package let stage: String

    package init(
        teamID: String,
        teamName: String,
        appID: String,
        clientID: String,
        connected: Bool,
        linkWritten: Bool,
        installRequested: Bool,
        stage: String
    ) {
        self.teamID = teamID
        self.teamName = teamName
        self.appID = appID
        self.clientID = clientID
        self.connected = connected
        self.linkWritten = linkWritten
        self.installRequested = installRequested
        self.stage = stage
    }

    enum CodingKeys: String, CodingKey {
        case teamID = "team_id", teamName = "team_name", appID = "app_id", clientID = "client_id"
        case connected, linkWritten = "link_written", installRequested = "install_requested", stage
    }

    var target: SlackSetupTarget {
        SlackSetupTarget(teamID: teamID, teamName: teamName, appID: appID, clientID: clientID, linkWritten: linkWritten)
    }
}

/// The workspace app a setup works on.
package struct SlackSetupTarget: Equatable, Sendable {
    package var teamID: String
    package var teamName: String
    package var appID: String
    package var clientID: String
    package var linkWritten: Bool

    package init(teamID: String, teamName: String, appID: String = "", clientID: String = "", linkWritten: Bool = false) {
        self.teamID = teamID
        self.teamName = teamName
        self.appID = appID
        self.clientID = clientID
        self.linkWritten = linkWritten
    }

    /// The workspace's label: Slack's name, else its id.
    package var workspace: String { teamName.isEmpty ? teamID : teamName }
}

/// **Set up for my company** (screens spec §3, plan B Task 13): creates or
/// adopts Watchtower's Slack app through `watchtower slack app … --json`,
/// mirrors each step, then runs the admin's own connect. Held on `AppState`
/// (`slackAppSetup`), so a run survives closing the sheet. The configuration
/// token reaches the CLI on stdin only and lives here until its run ends.
/// Every string is in `SlackAppSetupModel+Copy.swift`.
@MainActor
@Observable
package final class SlackAppSetupModel {
    /// What the sheet asks for.
    package enum Form: Equatable, Sendable {
        case create
        /// Add the connect link to an existing setup's app (§3.3).
        case addLink(SlackSetupTarget)
        /// The workspace already has Watchtower's app: update it (ask #1425).
        case adopt(Adopt)
        /// A create whose answer was lost: clear it or attach the app found.
        case pending(SlackSetupTarget)
    }

    package struct Adopt: Equatable, Sendable {
        package var target: SlackSetupTarget
        /// The App ID is unknown: the sheet asks for it (A19).
        package var needsAppID = false
        /// Why the given App ID was not taken (`need_app_id` codes, `app_not_found`).
        package var appIDProblem: AppIDProblem?
        /// `confirm_app`: the App ID came from the field; the owner checks the name.
        package var confirm: (appID: String, appName: String)?

        package init(target: SlackSetupTarget, needsAppID: Bool = false) {
            self.target = target
            self.needsAppID = needsAppID
        }

        package static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.target == rhs.target && lhs.needsAppID == rhs.needsAppID && lhs.appIDProblem == rhs.appIDProblem
                && lhs.confirm?.appID == rhs.confirm?.appID && lhs.confirm?.appName == rhs.confirm?.appName
        }
    }

    package enum AppIDProblem: Equatable, Sendable {
        case format, mismatch, notFound
    }

    package enum Phase: Equatable, Sendable {
        case editing
        case running
        case finished(Outcome)
    }

    package enum Outcome: Equatable, Sendable {
        case success(SlackSetupTarget)
        case notConnected(SlackSetupTarget)
        case approval(SlackSetupTarget)
        case linkFailed(SlackSetupTarget)
        case linkDone
        case problem(Problem)
    }

    package enum Problem: Equatable, Sendable {
        case badToken
        case notAllowed(workspace: String)
        case notCollaborator(workspace: String)
        case network(String)
        case refused(String)
        case busy
        case storage
        case wrongTeam(workspace: String)
        case noRecord(workspace: String)
        case noApp(workspace: String)
        case idsRejected(clientID: Bool)
        /// `pending`: the setup no longer waits on a lost create.
        case notPending(workspace: String)
        /// `pending`: the local save failed.
        case saveFailed
        /// The CLI ended without a result line (crashed, killed, refused to start).
        case stopped(String)
    }

    package enum StepMark: Equatable, Sendable {
        case waiting, running, done, failed
    }

    package struct StepLine: Equatable, Sendable, Identifiable {
        package let id: String
        package let label: String
        package var mark: StepMark
    }

    package private(set) var form: Form = .create
    package private(set) var phase: Phase = .editing
    package private(set) var steps: [StepLine] = []
    package private(set) var records: [SlackSetupRecord] = []
    package var isPresented = false
    /// The admin note was copied (A23): the sheet says so.
    package private(set) var adminNoteCopied = false

    /// Strong: the connect flow lives on `AppState` beside this model and
    /// never holds the model, so there is no cycle to break.
    @ObservationIgnored package var connector: (any SlackSetupConnectStarting)?
    /// Resolved per run, so a CLI installed (or moved) after launch is found.
    @ObservationIgnored private let makeStreamer: @MainActor () -> (any CLILineStreaming)?
    private var streamer: (any CLILineStreaming)? { makeStreamer() }
    /// The configuration token of the running run; nil once it ends.
    private var heldToken: String?
    /// Bumped per status read; a read answers only while it is the newest.
    @ObservationIgnored private var readGeneration = 0
    /// **Start again** on a lost create asks once more first: Slack may have made the app.
    package private(set) var confirmingClear = false

    package convenience init(
        streamer: (any CLILineStreaming)?,
        form: Form = .create,
        phase: Phase = .editing,
        steps: [StepLine] = [],
        records: [SlackSetupRecord] = []
    ) {
        self.init(makeStreamer: { streamer }, form: form, phase: phase, steps: steps, records: records)
    }

    package init(
        makeStreamer: @escaping @MainActor () -> (any CLILineStreaming)?,
        form: Form = .create,
        phase: Phase = .editing,
        steps: [StepLine] = [],
        records: [SlackSetupRecord] = []
    ) {
        self.makeStreamer = makeStreamer
        self.form = form
        self.phase = phase
        self.steps = steps
        self.records = records
    }

    package var isRunning: Bool { phase == .running }
    /// The model holds a configuration token (only while a run is running).
    package var holdsToken: Bool { heldToken != nil }

    // MARK: - Opening the sheet

    /// **Set up for my company**: a fresh form, or the run still going.
    package func present() {
        if !isRunning { reset(.create) }
        isPresented = true
    }

    /// The record row's button (§3.4).
    package func open(_ record: SlackSetupRecord) {
        guard !isRunning else { isPresented = true; return }
        switch record.stage {
        case "pending_create": reset(.pending(record.target))
        case "link_missing": reset(.addLink(record.target))
        default:
            isPresented = true
            continueSetup(record.target)
            return
        }
        isPresented = true
    }

    /// Hides the sheet; a running run keeps going.
    package func close() {
        isPresented = false
    }

    /// **Add the link to the app** from the link-failed outcome.
    package func showAddLink() {
        guard !isRunning, case let .finished(.linkFailed(target)) = phase else { return }
        reset(.addLink(target))
    }

    /// **Try again**: back to the form the problem came from.
    package func tryAgain() {
        guard !isRunning else { return }
        if case .finished(.problem(.noApp)) = phase { form = .create }
        phase = .editing
        adminNoteCopied = false
    }

    private func reset(_ next: Form) {
        confirmingClear = false
        form = next
        phase = .editing
        steps = []
        adminNoteCopied = false
    }

    // MARK: - Runs

    /// **Create the app** (A4): create → the admin's connect → the link
    /// again if it was not written → the token dropped.
    package func startCreate(token: String) {
        startRun(token: token, steps: Self.createSteps) { [self] token in
            await runCreate(token: token)
        }
    }

    /// **Update the app** (ask #1425). A repeated App ID after `confirm_app`
    /// confirms it.
    package func startAdopt(token: String, appID: String?) {
        let appID = appID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fromField = !appID.isEmpty
        startRun(token: token, steps: fromField ? Self.adoptFieldSteps : Self.adoptSteps) { [self] token in
            await runAdopt(token: token, appID: appID)
        }
    }

    /// **Add the link** (§3.3).
    package func startLink(team: String, token: String) {
        startRun(token: token, steps: Self.linkSteps) { [self] token in
            await runLink(team: team, token: token)
        }
    }

    /// **Check again** (approval) and **Continue setup**: the admin's connect
    /// again on the current setup's app; never a second create.
    package func checkAgain() {
        switch phase {
        case let .finished(.approval(target)), let .finished(.notConnected(target)):
            continueSetup(target)
        default:
            break
        }
    }

    /// A lost create, nothing on api.slack.com/apps: drop the pending record.
    package func clearPending() {
        guard case let .pending(target) = form, !isRunning else { return }
        // A create may have made the app: the first press only asks to check.
        guard confirmingClear else {
            confirmingClear = true
            return
        }
        confirmingClear = false
        phase = .running
        steps = []
        Task { [self] in
            let result = await stream(Self.pendingArgs(team: target.teamID) + ["--clear"], token: nil)
            if let result {
                if result.result == "ok" {
                    reset(.create)
                } else {
                    finishPendingProblem(result, workspace: target.workspace)
                }
            }
            await reloadRecords()
        }
    }

    /// A lost create, the app found on api.slack.com/apps: record its ids,
    /// then the link needs a fresh token.
    package func attachPending(appID: String, clientID: String) {
        guard case let .pending(target) = form, !isRunning else { return }
        phase = .running
        steps = []
        let ids = [appID, clientID].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let args = Self.pendingArgs(team: target.teamID) + ["--attach", "--app-id", ids[0], "--client-id", ids[1]]
        Task { [self] in
            if let result = await stream(args, token: nil) {
                if result.result == "ok" {
                    reset(.addLink(result.target(fallback: target)))
                } else {
                    finishPendingProblem(result, workspace: target.workspace)
                }
            }
            await reloadRecords()
        }
    }

    /// `slack app status --json`: the setup records behind the rows of §3.4.
    /// A failed read keeps the last records.
    /// Reads may overlap (a run ends while the accounts change): a read that
    /// a later one has superseded drops its answer, so older records never
    /// overwrite newer ones. Returns false when this read failed.
    @discardableResult
    package func reloadRecords() async -> Bool {
        guard let streamer else { return false }
        readGeneration += 1
        let generation = readGeneration
        var last: String?
        do {
            for try await line in streamer.lines(args: Self.statusArgs, stdin: nil) { last = line }
            guard let last, let data = last.data(using: .utf8) else { return false }
            let read = try JSONDecoder().decode(StatusDocument.self, from: data).setups ?? []
            if generation == readGeneration { records = read }
            return true
        } catch {
            print("[SlackAppSetup] status read failed: \(error.localizedDescription)")
            return false
        }
    }

    /// The Workspaces list changed (an account connected, removed, re-bound):
    /// `connected` and the stage of each setup are derived from it.
    package func accountsChanged() {
        Task { await reloadRecords() }
    }

    /// Copies nothing itself: the note for a workspace admin (A23); the
    /// sheet puts it on the pasteboard and says so.
    package func copyAdminNote() -> String {
        adminNoteCopied = true
        return Self.adminNote(workspace: problemWorkspace)
    }

    private func startRun(token: String, steps lines: [StepLine], _ body: @escaping (String) async -> Void) {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isRunning, !token.isEmpty else { return }
        heldToken = token
        steps = lines
        phase = .running
        adminNoteCopied = false
        Task { [self] in
            await body(token)
            heldToken = nil
            await reloadRecords()
        }
    }

    private func continueSetup(_ target: SlackSetupTarget) {
        guard !isRunning else { return }
        steps = Self.continueSteps(linkWritten: target.linkWritten)
        phase = .running
        adminNoteCopied = false
        Task { [self] in
            await finishSetup(target)
            await reloadRecords()
        }
    }

    /// The create's steps when it resumes at the connect.
    private static func continueSteps(linkWritten: Bool) -> [StepLine] {
        createSteps.map { line in
            var line = line
            if line.id == "check_token" || line.id == "create_app" || (line.id == "write_link" && linkWritten) {
                line.mark = .done
            }
            return line
        }
    }

    private func runCreate(token: String) async {
        guard let result = await stream(["slack", "app", "create", "--json"], token: token) else { return }
        var target = result.target(fallback: nil)
        switch result.result {
        case "ok", "link_failed":
            await finishSetup(target)
        case "exists":
            // The record row's Continue setup path: never a second create.
            await reloadRecords()
            if let record = records.first(where: { $0.teamID == target.teamID }) {
                target.linkWritten = record.linkWritten
                if record.connected {
                    await writeLinkIfNeeded(&target)
                    phase = .finished(target.linkWritten ? .success(target) : .linkFailed(target))
                    return
                }
            }
            await finishSetup(target)
        case "existing_app":
            reset(.adopt(Adopt(target: target)))
        case "pending_create":
            reset(.pending(target))
        default:
            finishWithProblem(result, workspace: target.workspace)
        }
    }

    /// The admin's connect (step 4), then the link while the token is still
    /// held (Q2: a link written right after the create can fail).
    private func finishSetup(_ setup: SlackSetupTarget) async {
        var target = setup
        mark("connect", .running)
        let outcome = await connector?.connectForSetup(teamID: target.teamID, clientID: target.clientID) ?? .notConnected
        mark("connect", outcome == .connected ? .done : .failed)
        await writeLinkIfNeeded(&target)
        switch outcome {
        case .connected: phase = .finished(target.linkWritten ? .success(target) : .linkFailed(target))
        case .approvalRequested: phase = .finished(.approval(target))
        case .notConnected: phase = .finished(.notConnected(target))
        }
    }

    private func writeLinkIfNeeded(_ target: inout SlackSetupTarget) async {
        guard !target.linkWritten, let token = heldToken else { return }
        let result = await stream(["slack", "app", "link", "--json", "--team", target.teamID], token: token, keepPhase: true)
        if result?.result == "ok" { target.linkWritten = true }
    }

    private func runAdopt(token: String, appID: String) async {
        guard case let .adopt(adopt) = form else { return }
        var args = ["slack", "app", "adopt", "--json"]
        // The workspace the sheet names: a token of another one changes nothing (wrong_team).
        if !adopt.target.teamID.isEmpty { args += ["--team", adopt.target.teamID] }
        if !appID.isEmpty {
            args += ["--app-id", appID]
            if adopt.confirm?.appID == appID { args += ["--confirm-app-id", appID] }
        }
        guard let result = await stream(args, token: token) else { return }
        var next = adopt
        next.target = result.target(fallback: adopt.target)
        next.confirm = nil
        next.appIDProblem = nil
        switch result.result {
        case "ok":
            phase = .finished(.success(next.target))
        case "need_app_id":
            next.needsAppID = true
            next.appIDProblem = switch result.code {
            case "app_id_format": .format
            case "app_id_mismatch": .mismatch
            default: nil
            }
            reset(.adopt(next))
        case "app_not_found":
            next.needsAppID = true
            next.appIDProblem = .notFound
            reset(.adopt(next))
        case "confirm_app":
            next.needsAppID = true
            next.confirm = (result.appID ?? appID, result.appName ?? "")
            reset(.adopt(next))
        case "exists":
            await reloadRecords()
            let record = records.first { $0.teamID == next.target.teamID }
            continueAfterExists(record?.target ?? next.target, connected: record?.connected ?? false)
        case "pending_create":
            reset(.pending(next.target))
        default:
            finishWithProblem(result, workspace: next.target.workspace)
        }
    }

    private func continueAfterExists(_ target: SlackSetupTarget, connected: Bool) {
        if connected {
            phase = .finished(target.linkWritten ? .success(target) : .linkFailed(target))
        } else {
            phase = .finished(.notConnected(target))
        }
    }

    private func runLink(team: String, token: String) async {
        var args = ["slack", "app", "link", "--json"]
        if !team.isEmpty { args += ["--team", team] }
        guard let result = await stream(args, token: token) else { return }
        if result.result == "ok" {
            var target = result.target(fallback: nil)
            target.linkWritten = true
            // Done only when the records confirm the owner is connected; an
            // unreadable status goes on to the connect (re-connecting re-binds
            // the same account, so it is safe).
            if await reloadRecords() {
                let record = records.first { $0.teamID == target.teamID }
                if record?.connected ?? true {
                    phase = .finished(.linkDone)
                    return
                }
                if let record { target = SlackSetupTarget(teamID: record.teamID, teamName: record.teamName,
                                                          appID: record.appID, clientID: record.clientID, linkWritten: true) }
            }
            // A setup whose owner is not connected yet (an attached app): on to the connect.
            form = .create
            steps = Self.continueSteps(linkWritten: true)
            await finishSetup(target)
        } else if result.result == "pending_create" {
            reset(.pending(result.target(fallback: nil)))
        } else {
            finishWithProblem(result, workspace: result.target(fallback: nil).workspace)
        }
    }

    private func finishWithProblem(_ result: ResultLine, workspace: String) {
        phase = .finished(.problem(Self.problem(for: result, workspace: workspace)))
    }

    /// `pending --clear/--attach` answers: nothing pending any more, or the
    /// local save failed (Slack had no part in it).
    private func finishPendingProblem(_ result: ResultLine, workspace: String) {
        switch result.result {
        case "no_pending": phase = .finished(.problem(.notPending(workspace: workspace)))
        case "storage": phase = .finished(.problem(.saveFailed))
        default: finishWithProblem(result, workspace: workspace)
        }
    }

    private static func problem(for result: ResultLine, workspace: String) -> Problem {
        switch result.result {
        case "bad_token": .badToken
        case "not_allowed": .notAllowed(workspace: workspace)
        case "not_collaborator": .notCollaborator(workspace: workspace)
        case "network": .network(result.error ?? "")
        case "refused": .refused(result.code ?? "")
        case "busy": .busy
        case "storage": .storage
        case "wrong_team": .wrongTeam(workspace: workspace)
        case "no_record": .noRecord(workspace: workspace)
        case "no_pending": .notPending(workspace: workspace)
        case "no_app": .noApp(workspace: workspace)
        case "bad_ids": .idsRejected(clientID: result.code == "client_id_format")
        default: .stopped(result.error ?? result.result)
        }
    }

    /// The workspace the current problem names (the admin note's).
    var problemWorkspace: String {
        switch phase {
        case let .finished(.problem(.notAllowed(workspace))), let .finished(.problem(.notCollaborator(workspace))):
            workspace
        default:
            ""
        }
    }

    private func mark(_ step: String, _ mark: StepMark) {
        guard let index = steps.firstIndex(where: { $0.id == step }) else { return }
        steps[index].mark = mark
    }

    // MARK: - The CLI

    private struct Line: Decodable {
        let step: String?
        let state: String?
        let result: String?
    }

    /// The final line of a setup verb.
    struct ResultLine: Decodable {
        let result: String
        let teamID: String?
        let teamName: String?
        let appID: String?
        let appName: String?
        let clientID: String?
        /// Absent on early results (a bad token): then the fallback's.
        let linkWritten: LinkWritten
        let code: String?
        let error: String?

        enum LinkWritten: Equatable { case absent, value(Bool) }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            result = try c.decode(String.self, forKey: .result)
            teamID = try c.decodeIfPresent(String.self, forKey: .teamID)
            teamName = try c.decodeIfPresent(String.self, forKey: .teamName)
            appID = try c.decodeIfPresent(String.self, forKey: .appID)
            appName = try c.decodeIfPresent(String.self, forKey: .appName)
            clientID = try c.decodeIfPresent(String.self, forKey: .clientID)
            linkWritten = try c.decodeIfPresent(Bool.self, forKey: .linkWritten).map(LinkWritten.value) ?? .absent
            code = try c.decodeIfPresent(String.self, forKey: .code)
            error = try c.decodeIfPresent(String.self, forKey: .error)
        }

        enum CodingKeys: String, CodingKey {
            case result, teamID = "team_id", teamName = "team_name", appID = "app_id", appName = "app_name"
            case clientID = "client_id", linkWritten = "link_written", code, error
        }

        func target(fallback: SlackSetupTarget?) -> SlackSetupTarget {
            SlackSetupTarget(
                teamID: Self.nonEmpty(teamID) ?? fallback?.teamID ?? "",
                teamName: Self.nonEmpty(teamName) ?? fallback?.teamName ?? "",
                appID: Self.nonEmpty(appID) ?? fallback?.appID ?? "",
                clientID: Self.nonEmpty(clientID) ?? fallback?.clientID ?? "",
                linkWritten: { if case let .value(written) = linkWritten { written } else { fallback?.linkWritten ?? false } }())
        }

        private static func nonEmpty(_ value: String?) -> String? {
            value.flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    private struct StatusDocument: Decodable {
        let setups: [SlackSetupRecord]?
    }

    /// Runs one verb: step lines move the marks, the last result line is
    /// returned. A run without a result line (the CLI died, was refused,
    /// or is missing) finishes as `stopped`, unless `keepPhase` (the link
    /// retry inside a run, whose failure is the outcome's).
    private func stream(_ args: [String], token: String?, keepPhase: Bool = false) async -> ResultLine? {
        let stdin = token.map { Data(($0 + "\n").utf8) }
        var result: ResultLine?
        var failure: String?
        if let streamer {
            do {
                for try await text in streamer.lines(args: args, stdin: stdin) {
                    guard let data = text.data(using: .utf8), let line = try? JSONDecoder().decode(Line.self, from: data) else {
                        continue
                    }
                    if let step = line.step, let state = line.state {
                        mark(step, Self.mark(state))
                    } else if line.result != nil {
                        result = try? JSONDecoder().decode(ResultLine.self, from: data)
                    }
                }
            } catch {
                failure = error.localizedDescription
            }
        } else {
            failure = CLIRunnerError.binaryNotFound.localizedDescription
        }
        if let result { return result }
        steps = steps.map { line in
            var line = line
            if line.mark == .running { line.mark = .failed }
            return line
        }
        if !keepPhase {
            phase = .finished(.problem(.stopped(failure ?? Self.noAnswer)))
        }
        return nil
    }

    private static func mark(_ state: String) -> StepMark {
        switch state {
        case "running": .running
        case "done": .done
        default: .failed
        }
    }

    static let statusArgs = ["slack", "app", "status", "--json"]

    private static func pendingArgs(team: String) -> [String] {
        ["slack", "app", "pending", "--json", "--team", team]
    }
}
