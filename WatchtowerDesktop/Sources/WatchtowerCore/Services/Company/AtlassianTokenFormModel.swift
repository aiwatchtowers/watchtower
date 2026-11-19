import Foundation
import Observation

/// Connect Jira with an Atlassian API token (#1887 C5, company screens spec
/// §6.2): the sheet's form, its check and its outcome, and the replace mode
/// that pastes a new token for a dead one (A16). Every text the sheet shows
/// is here.
///
/// The token goes to `jira add --api-token-stdin` (or `jira login --account
/// N --api-token-stdin`) on stdin only, never in the arguments; the model
/// clears it once a run connects and whenever the sheet closes. A failed
/// check keeps it in the field so **Try again** can resend it.
///
/// Writers: Go alone writes the account row and its 0600 token file, and
/// only after the site and the token both checked out (a refused or
/// unreachable check stores nothing). **Cancel** during a check closes the
/// sheet but lets the run finish, so a check is never killed between the
/// row and its token file; a success that lands after the close still
/// refreshes the accounts.
@MainActor
@Observable
package final class AtlassianTokenFormModel {
    package enum Mode: Equatable, Sendable {
        case add
        /// A new token for API-token account `accountID` on `site` (email and site read-only).
        case replace(accountID: Int, email: String, site: String)
    }

    package enum Problem: Equatable, Sendable {
        case unauthorized
        case missingScope(String)
        case notCloud(String)
        case network(host: String, detail: String)
        /// Any other failure, in Go's words.
        case failed(String)
    }

    package enum Phase: Equatable, Sendable {
        case form, checking
        case problem(Problem)
        case done(host: String, email: String)
    }

    package private(set) var mode: Mode = .add
    package private(set) var phase: Phase = .form
    /// The sheet is up.
    package private(set) var isPresented = false
    package var email = ""
    package var site = ""
    package var token = ""

    @ObservationIgnored private let makeStreamer: @MainActor () -> (any CLILineStreaming)?
    /// A run connected a site or saved a new token: the owner refreshes the
    /// accounts and re-wires the daemon. Set before a sheet opens.
    @ObservationIgnored package var onConnected: @MainActor () -> Void = {}

    package init(makeStreamer: @escaping @MainActor () -> (any CLILineStreaming)?) {
        self.makeStreamer = makeStreamer
    }

    /// A model held in one state with its fields filled, for the design shots
    /// (no CLI behind it).
    package static func preview(
        _ phase: Phase, mode: Mode = .add, email: String, site: String, token: String
    ) -> AtlassianTokenFormModel {
        let model = AtlassianTokenFormModel { nil }
        model.mode = mode
        model.phase = phase
        model.email = email
        model.site = site
        model.token = token
        model.isPresented = true
        return model
    }

    // MARK: Opening and closing

    /// **Connect with an API token**: an empty form, or the check still running.
    package func openAdd() {
        if phase != .checking {
            mode = .add
            phase = .form
            email = ""
            site = ""
            token = ""
        }
        isPresented = true
    }

    /// **Paste a new token** on a dead token's row.
    package func openReplace(accountID: Int, email: String, site: String) {
        if phase != .checking {
            mode = .replace(accountID: accountID, email: email, site: site)
            phase = .form
            self.email = email
            self.site = Self.host(site)
            token = ""
        }
        isPresented = true
    }

    /// **Cancel**, **Done**, or the sheet dismissed: the token is dropped; a
    /// running check keeps running and lands as it ends.
    package func close() {
        isPresented = false
        token = ""
        if phase != .checking { phase = .form }
    }

    /// The organization turned API tokens off (§6.5): the sheet closes and the
    /// detail shows the lock card in its place.
    package func policyLocked() {
        guard isPresented else { return }
        close()
    }

    // MARK: State

    package var isChecking: Bool { phase == .checking }

    /// **Connect** / **Try again** wait for every field; **Save token** for
    /// the token alone (Go keeps the stored email when the row names none).
    package var canSubmit: Bool {
        guard phase != .checking else { return false }
        let required = mode == .add ? [email, site, token] : (emailEditable ? [email, token] : [token])
        return required.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// The site is typed only when adding.
    package var siteEditable: Bool { mode == .add }

    /// The email is typed when adding, and in replace mode when the row
    /// names none (the token file may be what is broken).
    package var emailEditable: Bool {
        if case .replace(_, let known, _) = mode { return known.isEmpty }
        return true
    }

    // MARK: Texts

    package static let addTitle = "Connect Jira with an API token"
    package static let addIntro = "For a person whose company has no Atlassian app yet, or who prefers a token. "
        + "The token stays on this Mac."
    package static let replaceIntro = "The old token stopped working. Your data was kept; a new token picks up where "
        + "the sync stopped."
    package static let step1 = "1. Create a scoped API token"
    package static let step1Help = "On your Atlassian account's Security page, create an API token with scopes: the "
        + "Jira scopes Watchtower lists, and the Confluence ones if you use Confluence."
    package static let openTokenPage = "Open Atlassian's token page"
    // A fixed https string always parses.
    package static let tokenPageURL = URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens")!
    package static let copyScopes = "Copy scopes"
    /// What **Copy scopes** copies: the Jira and Confluence scopes Watchtower
    /// reads with (Go's `jira.JiraScopes` without offline_access, and
    /// `jira.ConfluenceScopes`; both sides test `internal/jira/testdata/api_token_scopes.txt`).
    package static let scopes = [
        "read:jira-work", "write:jira-work", "read:jira-user", "read:board-scope:jira-software",
        "read:sprint:jira-software", "read:issue:jira-software", "read:project:jira",
        "read:space:confluence", "read:page:confluence", "read:blogpost:confluence", "read:comment:confluence",
        "read:attachment:confluence", "read:user:confluence", "read:content-details:confluence", "search:confluence",
        "readonly:content.attachment:confluence", "read:confluence-user"
    ]
    package static let step2 = "2. Fill in"
    package static let emailLabel = "Atlassian email"
    package static let siteLabel = "Site"
    package static let tokenLabel = "API token"
    package static let scopedHint = "A token without scopes works too, but a scoped one can read only what Watchtower needs."
    package static let cancelTitle = "Cancel"
    package static let connectTitle = "Connect"
    package static let saveTitle = "Save token"
    package static let tryAgainTitle = "Try again"
    package static let doneTitle = "Done"
    package static let unauthorized = "Atlassian did not accept this email and token. Check both, or create a new token."
    package static let doneBody = "The first sync starts now."

    package static func replaceTitle(_ host: String) -> String { "Paste a new token for \(host)" }
    package static func checking(_ host: String) -> String { "Checking the token with \(host)…" }
    package static func missingScope(_ scope: String) -> String {
        "This token lacks \(scope) — create one with the listed scopes."
    }
    package static func notCloud(_ host: String) -> String {
        "\(host) is not an Atlassian Cloud site. Enter the address you open Jira at, like acme.atlassian.net."
    }
    package static func network(_ host: String, _ detail: String) -> String {
        "Could not reach \(host): \(detail). Nothing was saved."
    }
    package static func connected(_ host: String, _ email: String) -> String { "Connected to \(host) as \(email)" }

    /// The sheet's heading.
    package var title: String {
        if case .done = phase { return Self.addTitle }
        switch mode {
        case .add: return Self.addTitle
        case .replace(_, _, let site): return Self.replaceTitle(Self.host(site))
        }
    }

    /// The line under the heading; none once connected.
    package var intro: String? {
        if case .done = phase { return nil }
        return mode == .add ? Self.addIntro : Self.replaceIntro
    }

    /// The scoped-token hint: the add form at rest.
    package var showsScopedHint: Bool { mode == .add && phase == .form }

    /// The busy line while checking.
    package var busyLine: String? { phase == .checking ? Self.checking(host) : nil }

    /// The problem line after a failed check.
    package var problemLine: String? {
        guard case .problem(let problem) = phase else { return nil }
        return switch problem {
        case .unauthorized: Self.unauthorized
        case .missingScope(let scope): Self.missingScope(scope)
        case .notCloud(let host): Self.notCloud(host)
        case let .network(host, detail): Self.network(host, detail)
        case .failed(let message): message
        }
    }

    /// The primary button.
    package var primaryTitle: String {
        switch phase {
        case .done: Self.doneTitle
        case .problem: Self.tryAgainTitle
        case .form, .checking: mode == .add ? Self.connectTitle : Self.saveTitle
        }
    }

    /// The site's host as typed ("acme.atlassian.net").
    package var host: String { Self.host(site) }

    /// "https://Acme.atlassian.net/" → "acme.atlassian.net".
    package static func host(_ site: String) -> String {
        let trimmed = site.trimmingCharacters(in: .whitespacesAndNewlines)
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        return URL(string: withScheme)?.host?.lowercased() ?? trimmed
    }

    // MARK: The CLI

    /// The arguments of the run; the token is never among them.
    package var args: [String] {
        switch mode {
        case .add:
            // Confluence rides the same token: the scope list asks for its scopes too.
            ["jira", "add", "--api-token-stdin", "--email", email.trimmingCharacters(in: .whitespacesAndNewlines),
             "--site", site.trimmingCharacters(in: .whitespacesAndNewlines), "--with-confluence", "--json"]
        case .replace(let id, _, _):
            // The email the sheet shows is the one used, not the token file's.
            ["jira", "login", "--account", String(id), "--api-token-stdin", "--email",
             email.trimmingCharacters(in: .whitespacesAndNewlines), "--json"]
        }
    }

    /// **Connect** / **Save token** / **Try again**: checks the token through
    /// the CLI. The outcome is the phase; a connect also refreshes the
    /// accounts (`onConnected`).
    package func submit() async {
        guard canSubmit else { return }
        let checkedHost = host
        let secret = token.trimmingCharacters(in: .whitespacesAndNewlines)
        phase = .checking
        let outcome = await run(args: args, stdin: Data((secret + "\n").utf8))
        let next: Phase = switch outcome {
        case let .connected(site, email):
            .done(host: site.isEmpty ? checkedHost : Self.host(site), email: email.isEmpty ? self.email : email)
        case .forbidden:
            .form
        case .problem(let problem):
            .problem(Self.named(problem, host: checkedHost))
        }
        phase = next
        switch outcome {
        case .connected:
            token = ""
            onConnected()
            // Closed during the check: the account shows in the list; no sheet to come back to.
            if !isPresented { phase = .form }
        case .forbidden:
            close()
        case .problem:
            if !isPresented { phase = .form }
        }
    }

    /// The problem with the host the check was about.
    private static func named(_ problem: Problem, host: String) -> Problem {
        switch problem {
        case .notCloud: .notCloud(host)
        case .network(_, let detail): .network(host: host, detail: detail)
        default: problem
        }
    }

    /// One run's outcome.
    private enum Outcome {
        case connected(site: String, email: String)
        case forbidden
        case problem(Problem)
    }

    /// `jira add|login --api-token-stdin --json`'s one line (Go `apiTokenResult`).
    private struct Answer: Decodable {
        let result: String
        let site: String?
        let email: String?
        let scope: String?
        let detail: String?
        let message: String?
    }

    private func run(args: [String], stdin: Data) async -> Outcome {
        guard let streamer = makeStreamer() else {
            return .problem(.failed(CLIRunnerError.binaryNotFound.localizedDescription))
        }
        var last: String?
        var failure: String?
        do {
            for try await line in streamer.lines(args: args, stdin: stdin) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("{") { last = trimmed }
            }
        } catch {
            failure = error.localizedDescription
        }
        guard let last, let result = try? JSONDecoder().decode(Answer.self, from: Data(last.utf8)) else {
            return .problem(.failed(failure ?? "The check ended without an answer."))
        }
        return switch result.result {
        case "ok": .connected(site: result.site ?? "", email: result.email ?? "")
        case "forbidden": .forbidden
        case "unauthorized": .problem(.unauthorized)
        case "missing_scope": .problem(.missingScope(result.scope ?? ""))
        case "not_cloud": .problem(.notCloud(""))
        case "network": .problem(.network(host: "", detail: result.detail ?? ""))
        default: .problem(.failed(result.message ?? failure ?? "The check failed."))
        }
    }
}
