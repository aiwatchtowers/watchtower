import Foundation
import WatchtowerInterface

// The per-service seam of a connect assistant run (agent connect spec §5.3,
// §5.4): `ConnectRunController` keeps the run's rules and hands each allowed
// call to the service's driver, which runs it on the same view models and
// flows the buttons use. The result types below are the Go
// `internal/connectwire` result shapes; `ConnectRunControllerTests` pins
// each against `wire_cases.json`.

/// One service's connect actions.
@MainActor
package protocol ConnectServiceDriving: AnyObject {
    /// A `ConnectionService` raw value, or "company".
    var service: String { get }
    /// The `request_secret` kinds this service takes (its playbooks'
    /// `secrets`); any other kind is refused before the card shows.
    var secretKinds: Set<String> { get }
    func status() async -> ConnectStatus
    /// Starts the sign-in; returns its flow id.
    func start(options: [String: String]) async -> Result<String, ConnectDriverError>
    /// Waits on the flow. May return `.waiting` at any time; honours task
    /// cancellation (which ends the wait, never the flow). On a flow that
    /// already ended, or one the driver does not know (it ended before this
    /// app run, or was cancelled elsewhere), it returns that flow's final
    /// `.connected`/`.failed` at once (`.failed` when the end is unknown),
    /// never `.waiting` forever: the controller keeps waiting on a flow
    /// that left the status until its wait reports how it ended.
    func wait(flowID: String) async -> ConnectWaitOutcome
    /// Cancels the named flow only, never whatever flow is current: an id
    /// of a flow that already ended is a no-op.
    func cancel(flowID: String) async
    /// Hands a secret to the verb its kind names; returns the verb's JSON
    /// result, never the secret.
    func submitSecret(kind: String, value: String) async -> Result<Data, ConnectDriverError>
    /// Where `submitSecret(kind:)` would send the value right now, as the
    /// secret card shows it ("imap.example.com:993 as alice@example.com"):
    /// every field that picks the host, URL, server or key name. nil when the
    /// place is fixed (the vendor's own endpoint, Watchtower's store). The
    /// controller fixes it when the card opens and refuses Send when it
    /// changed since.
    func secretDestination(kind: String) -> String?
    func setFields(_ fields: [String: String]) async -> Result<Void, ConnectDriverError>
    func choose(kind: String, select: [String]?) async -> Result<[ConnectChoice], ConnectDriverError>
    /// The card the customer must press before `tool` runs with `options`
    /// (Slack PKCE, an own Google client, a Quick Connection's `enable`, a
    /// company Publish or Replace); nil when none is needed.
    func confirmNeeded(tool: String, options: [String: String]) -> ConnectAssistantConfirm?
    /// False when the organization's policy blocks the service.
    func policyAllows() -> Bool
    /// The run ended (`ConnectRunController.end`): a driver releases what it
    /// held for the run's later steps (Jira's daemon restart held for the
    /// board pick). Never ends a flow.
    func runEnded()
}

extension ConnectServiceDriving {
    package func runEnded() {}
    package func secretDestination(kind: String) -> String? { nil }
}

/// The company setup's extra actions (spec §5.4), on the setup wizard's
/// model and draft.
@MainActor
package protocol ConnectCompanyDriving: ConnectServiceDriving {
    /// The `company_draft` read as JSON (`ConnectCompanyDraft`). The
    /// controller re-encodes it through `ConnectCompanyDraft`, so a key the
    /// shape does not name (a secret) never leaves. It reads the stored
    /// draft first; a draft it cannot read is an error, never an empty one.
    func draftView() async -> Result<Data, ConnectDriverError>
    func saveDraft(vendor: String, fields: [String: String]) async -> Result<Void, ConnectDriverError>
    /// `company check <vendor>`; a Google or Atlassian check opens a sign-in.
    /// Success is `ConnectCompanyChecked`.
    func check(vendor: String) async -> Result<Data, ConnectDriverError>
    /// Publishes the setup with the Slack configuration token. The
    /// controller calls it only after the Publish confirm card and, when
    /// `publishNeedsToken`, the token's secret card (else with ""). Publishes
    /// only while `publishRevision` is still `approvedRevision`, checked
    /// again once the draft Go publishes is saved (`.failed` otherwise).
    /// Success is `ConnectCompanyPublished`.
    func publish(token: String, approvedRevision: String) async -> Result<Data, ConnectDriverError>
    /// Slack is part of the setup: Publish takes the configuration token.
    var publishNeedsToken: Bool { get }
    /// Why Publish cannot run yet (no confirm card shows), nil when it can.
    var publishBlockedReason: String? { get }
    /// What Publish would publish now (the company name and the draft's
    /// values), as a SHA-256 hex digest: comparable, and never a secret the
    /// draft holds. The controller fixes it when the Publish card opens and
    /// publishes only while it is unchanged.
    var publishRevision: String { get }
}

/// A driver whose secret may need the customer's confirm before its verb
/// changes anything: the company Slack step reads an existing app with the
/// token first, then the panel shows the update's changes (spec §5.4, F3
/// relaxed). The controller asks right after `submitSecret` succeeded.
@MainActor
package protocol ConnectSecretConfirming: AnyObject {
    /// The card for the secret `kind` just submitted; nil when its verb is done.
    func secretConfirm(kind: String) -> ConnectAssistantConfirm?
    /// The customer's answer to that card: yes runs the change and returns
    /// the verb's JSON; no drops it (nothing changed, the result is unused).
    func answerSecretConfirm(kind: String, yes: Bool) async -> Result<Data, ConnectDriverError>
    /// The card went unanswered (the run ended, the step timed out, or the
    /// read finished after the run ended): drop what waits on it (the token,
    /// the shown changes). A no-op when nothing waits.
    func secretConfirmDropped(kind: String)
}

/// A driver that can check Slack Live (`slack live probe --provider <p> --json`).
@MainActor
package protocol ConnectLiveProbing: AnyObject {
    /// `provider` is the agent's non-empty value, passed as is: the probe
    /// refuses a provider it does not know (`.badArgs`/`.failed`). Returns
    /// the probe's JSON row.
    func liveProbe(provider: String) async -> Result<Data, ConnectDriverError>
}

/// Why a driver refused or failed a call.
package enum ConnectDriverError: Error, Equatable, Sendable {
    /// Another flow of this service runs (here or elsewhere in the app).
    case busy
    /// The organization's policy blocks it.
    case policy
    case failed(String)
    case badArgs(String)
}

/// How a flow wait ended.
package enum ConnectWaitOutcome: Equatable, Sendable {
    case connected(account: String)
    case failed(reason: String)
    /// Nothing yet.
    case waiting
}

/// `connect_status` (Go `Status`). `flow` and `setup` encode as null when absent.
package struct ConnectStatus: Codable, Equatable, Sendable {
    package struct Account: Codable, Equatable, Sendable {
        package let name: String
        package let status: String

        package init(name: String, status: String) {
            self.name = name
            self.status = status
        }
    }

    package struct Flow: Codable, Equatable, Sendable {
        package let id: String
        package let state: String

        package init(id: String, state: String) {
            self.id = id
            self.state = state
        }
    }

    package struct Setup: Codable, Equatable, Sendable {
        package let stage: String

        package init(stage: String) {
            self.stage = stage
        }
    }

    package let service: String
    package let accounts: [Account]
    package let policyLocked: Bool
    package let flow: Flow?
    package let setup: Setup?

    private enum CodingKeys: String, CodingKey {
        case service, accounts, flow, setup
        case policyLocked = "policy_locked"
    }

    package init(service: String, accounts: [Account] = [], policyLocked: Bool = false, flow: Flow? = nil, setup: Setup? = nil) {
        self.service = service
        self.accounts = accounts
        self.policyLocked = policyLocked
        self.flow = flow
        self.setup = setup
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(service, forKey: .service)
        try container.encode(accounts, forKey: .accounts)
        try container.encode(policyLocked, forKey: .policyLocked)
        try container.encode(flow, forKey: .flow)
        try container.encode(setup, forKey: .setup)
    }
}

/// One board, team or space of `choose` (Go `Choice`).
package struct ConnectChoice: Codable, Equatable, Sendable {
    package let id: String
    package let name: String
    package let selected: Bool

    package init(id: String, name: String, selected: Bool) {
        self.id = id
        self.name = name
        self.selected = selected
    }
}

/// `choose` (Go `Choices`).
package struct ConnectChoices: Codable, Equatable, Sendable {
    package let items: [ConnectChoice]
}

/// `connect_start`'s own result (Go `Started`).
package struct ConnectStarted: Codable, Equatable, Sendable {
    package let flowID: String

    private enum CodingKeys: String, CodingKey { case flowID = "flow_id" }
}

/// `connect_wait` (Go `Waited`): connected, failed, waiting or timeout.
package struct ConnectWaited: Codable, Equatable, Sendable {
    package let state: String
    package var account: String?
    package var reason: String?
}

/// `request_secret` (Go `SecretSent`): sent with the verb's result (never
/// the secret), waiting, cancelled or timeout.
package struct ConnectSecretSent: Codable, Equatable, Sendable {
    package let state: String
    package var result: RawJSON?
}

/// The result of a call that waits on the customer in place of its own
/// (Go `Pending`): waiting, declined, cancelled or timeout.
package struct ConnectPending: Codable, Equatable, Sendable {
    package let state: String
}

/// `company_draft`'s read (Go `CompanyDraft`): no secret, only whether each is set.
package struct ConnectCompanyDraft: Codable, Equatable, Sendable {
    /// One vendor: its non-secret values, whether its secret is set, whether
    /// its check passed for these values or the customer skipped it; Slack
    /// (no check) says instead whether its app is `ready` on this Mac.
    package struct Vendor: Codable, Equatable, Sendable {
        package var clientID: String?
        package var tenantID: String?
        package var site: String?
        package let clientSecretSet: Bool
        package let checked: Bool
        package let skipped: Bool
        /// Absent for every vendor but Slack (Go `*bool`).
        package var ready: Bool? // swiftlint:disable:this discouraged_optional_boolean

        private enum CodingKeys: String, CodingKey {
            case site, checked, skipped, ready
            case clientID = "client_id"
            case tenantID = "tenant_id"
            case clientSecretSet = "client_secret_set"
        }
    }

    package let company: String
    package let vendors: [String: Vendor]
}

/// `company_check`'s own result (Go `CompanyChecked`): `ok` (`account` is
/// the signed-in address, absent for a dry check), `admin_consent`
/// (`admin_consent_url` for the tenant's IT admin) or `replace_needed`
/// (check again: the panel asks the customer to replace the stored app).
package struct ConnectCompanyChecked: Codable, Equatable, Sendable {
    package let result: String
    package var account: String?
    package var adminConsentURL: String?

    private enum CodingKeys: String, CodingKey {
        case result, account
        case adminConsentURL = "admin_consent_url"
    }
}

/// `company_publish`'s own result (Go `CompanyPublished`): `ok` (the link
/// is on the Slack app's About page) or `no_slack`; `slug` names the stored
/// company. The link and code stay on the wizard's Publish page.
package struct ConnectCompanyPublished: Codable, Equatable, Sendable {
    package let result: String
    package let slug: String
}

/// The result of a call with nothing to return (Go `Done`): `{}`.
package struct ConnectDone: Codable, Equatable, Sendable {}

/// Hides a pasted secret in text that goes back to the agent (a verb's
/// stderr or result line): every driver's secret result passes through it.
package enum ConnectSecret {
    /// `text` with every copy of `secret` hidden: a verb's stderr may echo
    /// what it read (an ICS address, a key), and that text goes back to the
    /// agent.
    package static func scrub(_ text: String, _ secret: String) -> String {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        var out = text
        for value in [secret, trimmed] where !value.isEmpty {
            out = out.replacingOccurrences(of: value, with: "[hidden]")
        }
        return out
    }

    /// A verb's failure for the agent. The view models cut stderr at 200
    /// characters, so a secret can survive only in part: an error that holds
    /// any piece of the secret (`holdsPiece`) is replaced by `fallback`,
    /// which never holds a credential.
    package static func failure(_ error: String?, secret: String, fallback: String) -> ConnectDriverError {
        guard let error, !error.isEmpty else { return .failed(fallback) }
        guard !holdsPiece(of: secret, in: error) else {
            return .failed("\(fallback) (Watchtower hid the error text: it repeated part of what was pasted)")
        }
        return .failed(error)
    }

    /// Whether `text` holds any run of the secret's characters as long as
    /// `piece` (or the whole secret, when it is shorter).
    package static func holdsPiece(of secret: String, in text: String, piece: Int = 8) -> Bool {
        let chars = Array(secret.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !chars.isEmpty else { return false }
        let length = min(piece, chars.count)
        return (0...(chars.count - length)).contains { text.contains(String(chars[$0..<($0 + length)])) }
    }
}
