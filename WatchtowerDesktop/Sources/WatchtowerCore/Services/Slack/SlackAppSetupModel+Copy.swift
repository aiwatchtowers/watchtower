import Foundation

/// Every string of **Set up for my company** (screens spec §3.2–§3.4, asks
/// #1425/#1438 A19/A23) and the choice of what the sheet and the record row
/// show; the views only lay it out (`SlackAppSetupModelTests`).
extension SlackAppSetupModel {
    // MARK: - Fixed lines

    package static let setupTitle = "Set up Watchtower for your company"
    package static let setupIntro = "Creates Watchtower's app in your Slack workspace from our manifest. Colleagues then "
        + "connect from the app's About page in Slack; nothing depends on this Mac afterwards."
    package static let step1Title = "1. Generate a configuration token"
    package static let step1Help = "On Slack's app page, under Your App Configuration Tokens, press Generate Token "
        + "for your workspace and copy the access token."
    package static let openTokenPage = "Open Slack's token page"
    package static let openAppsPage = "Open Slack's app page"
    package static let slackAppsURL = URL(string: "https://api.slack.com/apps")!
    package static let step2Title = "2. Paste it here"
    package static let tokenPlaceholder = "Configuration token"
    package static let tokenNote = "Used once for this setup and never stored."
    package static let progressCaption = "Keep this window open. If it closes, continue from Connections → Slack; "
        + "the app is never created twice."
    package static let addLinkBusy = "Writing the link…"
    package static let pendingBusy = "Saving…"
    package static let appIDLabel = "App ID"
    package static let appIDHelp = "Find it on the app's Basic Information page at api.slack.com/apps."
    package static let clientIDLabel = "Client ID"
    package static let adminNoteCopiedLine = "Copied. Send it to a workspace admin."
    /// The guide's company-setup section (A23): `main`, not the build's tag,
    /// because the note goes to an admin who may run another version.
    package static let guideURL = URL(string: ReleaseLinks.repository.absoluteString
        + "/blob/main/docs/guide/features/slack-full.md#set-up-slack-for-your-company") ?? ReleaseLinks.repository
    static let noAnswer = "the watchtower command gave no result"

    package static func adminNote(workspace: String) -> String {
        let name = workspace.isEmpty ? "our Slack workspace" : workspace
        return "Please set up Watchtower for \(name) in Slack: \(guideURL.absoluteString)"
    }

    package static let createSteps = [
        StepLine(id: "check_token", label: "Checking the token", mark: .waiting),
        StepLine(id: "create_app", label: "Creating the app", mark: .waiting),
        StepLine(id: "write_link", label: "Writing the connect link to its About page", mark: .waiting),
        StepLine(id: "connect", label: "Connecting your Slack account", mark: .waiting)
    ]
    /// The wizard's create (company screens spec §2.5): no link, no connect.
    package static let wizardCreateSteps = Array(createSteps.prefix(2))
    package static let adoptSteps = [
        StepLine(id: "check_token", label: "Checking the token", mark: .waiting),
        StepLine(id: "update_app", label: "Updating the app", mark: .waiting)
    ]
    package static let adoptFieldSteps = [
        StepLine(id: "check_token", label: "Checking the token", mark: .waiting),
        StepLine(id: "read_app", label: "Reading the app", mark: .waiting),
        StepLine(id: "update_app", label: "Updating the app", mark: .waiting)
    ]
    package static let linkSteps = [StepLine(id: "write_link", label: "Writing the connect link to its About page", mark: .waiting)]

    // MARK: - The sheet

    package var title: String {
        if case .addLink = form { return "Add the connect link to the app" }
        return Self.setupTitle
    }

    package var intro: String {
        if case let .addLink(target) = form {
            return "Writes the connect link and code into the About page of Watchtower's app in \(target.workspace). "
                + "Needs a fresh configuration token."
        }
        return Self.setupIntro
    }

    /// The token form (steps 1 and 2): while editing, and with a problem
    /// that a new token or a retry fixes; the link sheet keeps it while busy.
    package var showsTokenForm: Bool {
        if case .pending = form { return false }
        switch phase {
        case .editing: return true
        case .running: if case .addLink = form { return true } else { return false }
        case let .finished(outcome):
            if case .problem = outcome { return true }
            return false
        }
    }

    /// The Slack data disclosure (#1769) above the token field.
    package var showsDisclosure: Bool {
        guard showsTokenForm else { return false }
        if case .addLink = form { return false }
        return true
    }

    package var showsProgress: Bool {
        guard isRunning, !steps.isEmpty else { return false }
        if case .addLink = form { return false }
        return true
    }

    /// The one-line busy state of the link and pending sheets.
    package var busyLine: String? {
        guard isRunning else { return nil }
        switch form {
        case .addLink: return Self.addLinkBusy
        case .pending: return Self.pendingBusy
        default: return steps.isEmpty ? Self.pendingBusy : nil
        }
    }

    package var showsAppIDField: Bool {
        guard case let .adopt(adopt) = form, phase == .editing || isProblem else { return false }
        return adopt.needsAppID
    }

    package var appIDProblemLine: String? {
        guard case let .adopt(adopt) = form, let problem = adopt.appIDProblem else { return nil }
        return switch problem {
        case .format: Self.appIDFormatLine
        case .mismatch: "That App ID is not the app this workspace connects through."
        case .notFound: "Slack has no app with that App ID in this workspace."
        }
    }

    /// The pending sheet's App ID and Client ID fields.
    package var showsPendingFields: Bool {
        guard case .pending = form else { return false }
        return phase == .editing || isProblem
    }

    private var isProblem: Bool {
        if case .finished(.problem) = phase { return true }
        return false
    }

    package struct Notice: Equatable, Sendable {
        package let icon: String
        package let tone: SlackModeTone
        package let title: String?
        package let body: String
    }

    /// The card under the form: the outcome, the adopt or pending question.
    package var notice: Notice? {
        switch phase {
        case .running:
            return nil
        case .editing:
            return editingNotice
        case let .finished(outcome):
            return outcomeNotice(outcome)
        }
    }

    private var editingNotice: Notice? {
        switch form {
        case .create, .addLink:
            return nil
        case let .adopt(adopt):
            let body = adopt.confirm.map {
                "App \($0.appID) is called “\($0.appName)”. Update it only if it is your workspace's Watchtower app. "
                    + Self.adoptPKCEWarning
            } ?? Self.adoptBody
            return Notice(icon: "arrow.triangle.2.circlepath", tone: .blue, title: Self.adoptTitle(adopt.target.workspace), body: body)
        case let .pending(target):
            return Notice(icon: "questionmark.circle", tone: .warning, title: nil,
                          body: confirmingClear ? Self.confirmClearBody : Self.pendingBody(target.workspace))
        }
    }

    /// Shown on every screen with **Update the app** (the adopt body and the
    /// App ID check): the run passes `--enable-pkce` only after it.
    package static let adoptPKCEWarning = "Watchtower turns on PKCE sign-in for this app, which can be turned off "
        + "only by Slack support; Slack may ask colleagues already connected to allow Watchtower again."

    package static let adoptBody = "Update it to the current version: Watchtower adds the connect link to its About page "
        + "and the sign-in settings it needs. " + adoptPKCEWarning

    package static func adoptTitle(_ workspace: String) -> String {
        "Watchtower's app already exists in \(workspace)"
    }

    package static func successTitle(_ workspace: String) -> String {
        "Watchtower's app is ready in \(workspace)"
    }

    package static let successBody = "You are connected. Colleagues open Watchtower in Slack, go to About and click "
        + "the connect link."
    package static let linkFailedBody = "The app works, but its About page has no connect link yet: the token expired "
        + "before the link was written. Paste a fresh token to add it."
    package static let approvalBody = "Waiting for your admin's approval. Slack sent them a request to install Watchtower. "
        + "Check again once they approve; this window can close."
    package static let linkDoneBody = "The connect link is on the app's About page."

    package static func installLine(_ workspace: String) -> String {
        "Setup is not finished: Watchtower's app exists in \(workspace), but you have not connected yet."
    }

    package static func pendingBody(_ workspace: String) -> String {
        "Slack did not answer when Watchtower asked it to create the app in \(workspace), so the app may exist. "
            + "Look for “Watchtower” on api.slack.com/apps. If it is there, enter its App ID and Client ID from its "
            + "Basic Information page, then paste a fresh configuration token to add the connect link; if not, start again."
    }

    package static let confirmClearBody = "Watchtower may have created the app already. Check Slack's app page first: "
        + "if “Watchtower” is there, enter its ids and use it. Start again only if it is not there, or the workspace "
        + "gets a second Watchtower app."

    private func outcomeNotice(_ outcome: Outcome) -> Notice {
        switch outcome {
        case let .success(target):
            Notice(icon: "checkmark.circle.fill", tone: .success, title: Self.successTitle(target.workspace), body: Self.successBody)
        case let .notConnected(target):
            Notice(icon: "wrench.and.screwdriver", tone: .warning, title: nil, body: Self.installLine(target.workspace))
        case .approval:
            Notice(icon: "hourglass", tone: .warning, title: nil, body: Self.approvalBody)
        case let .linkFailed(target):
            Notice(icon: "exclamationmark.triangle.fill", tone: .warning, title: Self.successTitle(target.workspace),
                   body: Self.linkFailedBody)
        case .linkDone:
            Notice(icon: "checkmark.circle.fill", tone: .success, title: nil, body: Self.linkDoneBody)
        case let .problem(.notCollaborator(workspace)):
            Notice(icon: "exclamationmark.triangle.fill", tone: .warning, title: isAdopt ? Self.adoptTitle(workspace) : nil,
                   body: Self.notCollaboratorBody)
        case let .problem(problem):
            Notice(icon: "exclamationmark.triangle.fill", tone: .warning, title: nil, body: problemLine(problem))
        }
    }

    package static let badTokenBody = "That token did not work: it has expired or is not a configuration token. "
        + "Generate a new one and paste it."
    package static let notAllowedBody = "Your workspace does not let you create apps. Ask a workspace admin to run this setup."
    package static let notCollaboratorBody = "Your token cannot change this app. Ask one of its collaborators "
        + "(listed on its Collaborators page) to run this setup."
    package static let saveFailedBody = "Watchtower could not save this on this Mac. Nothing changed on Slack's side; try again."

    package static func notPendingLine(_ workspace: String) -> String {
        "The setup for \(workspace) no longer waits for Slack's answer. Connections → Slack shows where it stands."
    }

    package static let appIDFormatLine = "That is not an App ID: it starts with A."
    package static let clientIDFormatLine = "That is not a Client ID: two numbers joined by a dot."

    package static let busyBody = "Another setup is already running on this Mac. Try again once it has finished."
    /// The storage line names the button the setup's record row shows; with
    /// no row, the owner tries again.
    package static func storageBody(rowAction: String?) -> String {
        let next = rowAction.map { "Connections → Slack shows the setup: press \($0) on its row there." }
            ?? "Try again."
        return "Watchtower could not save the setup on this Mac, so it stopped. \(next) The app is never created twice."
    }

    private var isAdopt: Bool {
        if case .adopt = form { return true }
        return false
    }

    private var changesNothingCreated: Bool {
        if case .create = form { return true }
        return false
    }

    /// `wrong_workspace` (company screens spec §2.5): the app is this Mac's in
    /// another workspace than the token's.
    package static func wrongWorkspaceLine(appID: String, appTeam: String, workspace: String) -> String {
        let team = appTeam.isEmpty ? "" : " (\(appTeam))"
        return "App \(appID) belongs to another workspace\(team), not \(workspace). Check the link and paste it again."
    }

    /// The line a problem shows (the company wizard words two of them itself).
    package func problemLine(_ problem: Problem) -> String {
        let nothing = changesNothingCreated ? "Nothing was created." : "Nothing was changed."
        switch problem {
        case .badToken: return Self.badTokenBody
        case .notAllowed: return Self.notAllowedBody
        case .notCollaborator: return Self.notCollaboratorBody
        case let .network(error): return "Could not reach Slack: \(error). \(nothing)"
        case let .refused(code):
            return changesNothingCreated ? "Slack refused the app: \(code). \(nothing)" : "Slack refused the change: \(code). \(nothing)"
        case .busy: return Self.busyBody
        case let .storage(teamID):
            return Self.storageBody(rowAction: recordRows.first { $0.record.teamID == teamID && !teamID.isEmpty }?.label)
        case let .wrongTeam(workspace):
            return "That token is for \(workspace), not this setup's workspace. Generate one in the right workspace."
        case let .wrongWorkspace(appID, appTeam, workspace):
            return Self.wrongWorkspaceLine(appID: appID, appTeam: appTeam, workspace: workspace)
        case let .noRecord(workspace):
            return "This Mac has no unfinished setup for \(workspace), so there is nothing to add the link to."
        case let .noApp(workspace):
            return "Watchtower's app is not connected in \(workspace) any more, so there is nothing to update. "
                + "Create the app instead."
        case let .idsRejected(clientID):
            return clientID ? Self.clientIDFormatLine : Self.appIDFormatLine
        case let .notPending(workspace):
            return Self.notPendingLine(workspace)
        case .saveFailed:
            return Self.saveFailedBody
        case let .stopped(detail):
            return "The setup stopped before it finished: \(detail). Connections → Slack shows where it got to; "
                + "the app is never created twice."
        }
    }

    // MARK: - Buttons

    package enum Action: Equatable, Sendable {
        case cancel, close, done, create, tryAgain, copyAdminNote, updateApp, copyCode, cancelConnect
        case showAddLink, addLink, continueSetup, checkAgain, clearPending, confirmClear, attachPending
    }

    package struct ActionButton: Equatable, Sendable, Identifiable {
        package var id: Action { action }
        package let action: Action
        package let label: String
        package let prominent: Bool
    }

    /// The sheet's buttons, left to right; at most one prominent.
    package var actions: [ActionButton] {
        switch phase {
        case .running:
            if case .addLink = form { return [button(.close), button(.addLink, prominent: true)] }
            return isConnecting ? [button(.close), button(.cancelConnect)] : [button(.close)]
        case .editing:
            return editingActions
        case let .finished(outcome):
            return outcomeActions(outcome)
        }
    }

    private var editingActions: [ActionButton] {
        switch form {
        case .create: [button(.cancel), button(.create, prominent: true)]
        case .addLink: [button(.cancel), button(.addLink, prominent: true)]
        case .adopt: [button(.cancel), button(.updateApp, prominent: true)]
        case .pending:
            [button(.cancel), button(confirmingClear ? .confirmClear : .clearPending), button(.attachPending, prominent: true)]
        }
    }

    private func outcomeActions(_ outcome: Outcome) -> [ActionButton] {
        switch outcome {
        case .success: [button(.copyCode), button(.done, prominent: true)]
        case .notConnected: [button(.close), button(.continueSetup, prominent: true)]
        case .approval: [button(.close), button(.checkAgain, prominent: true)]
        case .linkFailed: [button(.close), button(.showAddLink, prominent: true)]
        case .linkDone, .problem(.notPending): [button(.done, prominent: true)]
        case .problem(.notAllowed), .problem(.notCollaborator):
            [button(.cancel), button(.copyAdminNote), button(.tryAgain, prominent: true)]
        case .problem: [button(.cancel), button(.tryAgain, prominent: true)]
        }
    }

    private func button(_ action: Action, prominent: Bool = false) -> ActionButton {
        ActionButton(action: action, label: Self.label(action), prominent: prominent)
    }

    package static func label(_ action: Action) -> String {
        switch action {
        case .cancel, .cancelConnect: action == .cancel ? "Cancel" : "Cancel connecting"
        case .close: "Close"
        case .done: "Done"
        case .create: "Create the app"
        case .tryAgain: "Try again"
        case .copyAdminNote: "Copy a note for your admin"
        case .updateApp: "Update the app"
        case .copyCode: "Copy connect code"
        case .showAddLink: "Add the link to the app"
        case .addLink: "Add the link"
        case .continueSetup: "Continue setup"
        case .checkAgain: "Check again"
        case .clearPending: "Start again"
        case .confirmClear: "Nothing there: start again"
        case .attachPending: "Use this app"
        }
    }

    /// Whether `action` can run with what the sheet's fields hold.
    package func isEnabled(_ action: Action, token: String, appID: String = "", clientID: String = "") -> Bool {
        let hasToken = !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch action {
        case .create, .addLink:
            return !isRunning && hasToken
        case .updateApp:
            return !isRunning && hasToken && (!showsAppIDField || !appID.trimmingCharacters(in: .whitespaces).isEmpty)
        case .attachPending:
            return !isRunning && !appID.trimmingCharacters(in: .whitespaces).isEmpty
                && !clientID.trimmingCharacters(in: .whitespaces).isEmpty
        case .clearPending, .confirmClear:
            return !isRunning
        case .copyCode:
            return connectCode != nil
        default:
            return true
        }
    }

    /// What the sheet's fields hold; a run takes the token and the field is emptied.
    package struct Fields: Equatable, Sendable {
        package var token = ""
        package var appID = ""
        package var clientID = ""

        package init(token: String = "", appID: String = "", clientID: String = "") {
            self.token = token
            self.appID = appID
            self.clientID = clientID
        }
    }

    /// A sheet button. A run that takes the token clears the field, so the
    /// token lives only here for that run. Returns text to put on the
    /// pasteboard (the connect code, the admin note).
    package func perform(_ action: Action, fields: inout Fields) -> String? {
        guard isEnabled(action, token: fields.token, appID: fields.appID, clientID: fields.clientID) else { return nil }
        switch action {
        case .cancel, .close, .done: close()
        case .create: startCreate(token: fields.token)
        case .updateApp: startAdopt(token: fields.token, appID: showsAppIDField ? fields.appID : nil)
        case .addLink:
            guard case let .addLink(target) = form else { return nil }
            startLink(team: target.teamID, token: fields.token)
        case .tryAgain: tryAgain()
        case .cancelConnect: cancelConnect()
        case .copyAdminNote: return copyAdminNote()
        case .copyCode: return connectCode
        case .showAddLink: showAddLink()
        case .continueSetup, .checkAgain: checkAgain()
        case .clearPending, .confirmClear: clearPending()
        case .attachPending: attachPending(appID: fields.appID, clientID: fields.clientID)
        }
        if [.create, .updateApp, .addLink].contains(action) { fields.token = "" }
        return nil
    }

    /// The note for a workspace admin, shown ready to copy (ask #1438 A23)
    /// while the setup needs someone with more rights.
    package var adminNotePreview: String? {
        switch phase {
        case .finished(.problem(.notAllowed)), .finished(.problem(.notCollaborator)): Self.adminNote(workspace: problemWorkspace)
        default: nil
        }
    }

    /// The connect code of a finished setup (`<team id>:<client id>`).
    package var connectCode: String? {
        guard case let .finished(.success(target)) = phase, !target.clientID.isEmpty else { return nil }
        return "\(target.teamID):\(target.clientID)"
    }

    // MARK: - The record rows on Connections → Slack (§3.4)

    package struct RecordRow: Equatable, Sendable, Identifiable {
        package var id: String { record.teamID }
        package let record: SlackSetupRecord
        package let text: String
        package let action: Action
        package let label: String
        /// Waiting on someone else (the approval): an hourglass, a quiet button.
        package let waiting: Bool
    }

    /// One row per unfinished setup; the approval row only when the record
    /// says Slack reported the request.
    package var recordRows: [RecordRow] {
        records.compactMap { record in
            let workspace = record.target.workspace
            switch record.stage {
            case "pending_create":
                return RecordRow(record: record, text: "Setup is not finished: Slack did not confirm Watchtower's app in "
                    + "\(workspace). Check api.slack.com/apps before going on.",
                                 action: .continueSetup, label: Self.label(.continueSetup), waiting: false)
            case "install":
                return RecordRow(record: record, text: Self.installLine(workspace), action: .continueSetup,
                                 label: Self.label(.continueSetup), waiting: false)
            case "approval":
                return RecordRow(record: record, text: "Waiting for your admin's approval in \(workspace). "
                    + "Check again once they approve.", action: .checkAgain, label: Self.label(.checkAgain), waiting: true)
            case "link_missing":
                return RecordRow(record: record, text: "The app's About page has no connect link yet, so colleagues cannot connect.",
                                 action: .showAddLink, label: Self.label(.showAddLink), waiting: false)
            default:
                return nil
            }
        }
    }
}
