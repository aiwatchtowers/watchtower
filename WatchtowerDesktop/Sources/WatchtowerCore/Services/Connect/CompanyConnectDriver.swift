import CryptoKit
import Foundation

/// The company setup's connect driver (agent connect spec §5.4): the
/// "Set up for my company" playbooks run on the wizard's own model, so the
/// panel and the wizard sheet share one state (`AppState.companySetup`).
///
/// Writers of the draft: everything goes through `CompanySetupWizardModel`,
/// whose `company draft save` writes the whole in-memory draft; the page's
/// own saves (leaving it, Continue, a check, Publish, Discard) and this
/// driver's `saveNow()` queue behind each other, so the last save of either
/// wins and carries both sides' edits. Go alone marks a check and stores the
/// bundle (`company check`, `company publish`). The Slack app belongs to its
/// setup record (`SlackAppSetupModel`): the draft keeps only the App ID.
///
/// Secrets: a company client secret (`google_client_secret`,
/// `atlassian_client_secret`) goes into the draft through `setField` and a
/// save, as typed in the page, and never comes back (`draftView()` says only
/// whether it is set). The Slack configuration token reaches the wizard's
/// token field for one Slack step (create, or the update of an app whose
/// settings link was saved) and is cleared when the step ends; Publish gets
/// its own token from the controller's card. Every failure line that goes
/// back with a secret's result passes `ConnectSecret.failure` first.
@MainActor
package final class CompanyConnectDriver: ConnectCompanyDriving, ConnectSecretConfirming {
    package let service = "company"
    package let secretKinds: Set<String> = [CompanyConnectDriver.googleSecret, CompanyConnectDriver.atlassianSecret,
                                            CompanyConnectDriver.slackToken]

    package static let googleSecret = "google_client_secret"
    package static let atlassianSecret = "atlassian_client_secret"
    package static let slackToken = "slack_config_token"

    private let wizard: CompanySetupWizardModel
    private let allowed: @MainActor () -> Bool
    /// The app and changes the Slack step read and the update card shows.
    private var shownUpdate: (appID: String, lines: [String])?

    /// `policyAllowed`: the organization lets this Mac set up a company.
    package init(wizard: CompanySetupWizardModel, policyAllowed: @escaping @MainActor () -> Bool = { true }) {
        self.wizard = wizard
        self.allowed = policyAllowed
    }

    /// The vendor pages' order: the wizard's.
    package func order() -> [CompanyVendor] { CompanyVendor.allCases }

    package func policyAllows() -> Bool { allowed() }

    package func status() async -> ConnectStatus {
        await ensureOpen()
        let setup = wizard.load == .ready ? ConnectStatus.Setup(stage: wizard.current.draftName) : nil
        return ConnectStatus(service: service, policyLocked: !policyAllows(), setup: setup)
    }

    // MARK: - The draft

    package func draftView() async -> Result<Data, ConnectDriverError> {
        // The stored draft first: an unread one would read as "nothing set up".
        guard await ensureOpen() else { return .failure(.failed(openFailed)) }
        // Go set an unreadable draft aside and nothing replaced it yet: say so,
        // never "nothing set up yet".
        if let unreadable = wizard.draftUnreadable, !wizard.hasActiveDraft {
            return .failure(.failed("\(unreadable.title). \(unreadable.body)"))
        }
        let draft = wizard.draft
        var vendors: [String: ConnectCompanyDraft.Vendor] = [:]
        for v in wizard.ticked {
            let checked = wizard.isChecked(v)
            let skipped = wizard.isSkipped(v)
            vendors[v.rawValue] = switch v {
            case .slack:
                .init(clientID: Self.nonEmpty(wizard.slack.record(appID: draft.slack.appID)?.clientID), clientSecretSet: false,
                      checked: checked, skipped: skipped, ready: wizard.slackAppReady)
            case .google:
                .init(clientID: Self.nonEmpty(draft.google?.clientID), clientSecretSet: !(draft.google?.clientSecret ?? "").isEmpty,
                      checked: checked, skipped: skipped)
            case .atlassian:
                .init(clientID: Self.nonEmpty(draft.atlassian?.clientID), site: Self.nonEmpty(draft.atlassian?.site),
                      clientSecretSet: !(draft.atlassian?.clientSecret ?? "").isEmpty, checked: checked, skipped: skipped)
            case .linear:
                .init(clientID: Self.nonEmpty(draft.linear?.clientID), clientSecretSet: false, checked: checked, skipped: skipped)
            case .microsoft:
                .init(clientID: Self.nonEmpty(draft.microsoft?.clientID), tenantID: Self.nonEmpty(draft.microsoft?.tenantID),
                      clientSecretSet: false, checked: checked, skipped: skipped)
            }
        }
        let company = draft.company.isEmpty ? wizard.publishName.trimmingCharacters(in: .whitespacesAndNewlines) : draft.company
        return .success(Self.json(ConnectCompanyDraft(company: company, vendors: vendors)))
    }

    /// The keys a `company_draft` save takes: any vendor's call carries the
    /// company name, the services and the deny list; the rest are the vendor's.
    package static let commonKeys: Set<String> = ["company", "services", "deny_hosts"]
    package static func vendorKeys(_ v: CompanyVendor) -> Set<String> {
        switch v {
        case .slack: ["settings_link", "client_id"]
        case .google, .linear: ["client_id"]
        case .atlassian: ["client_id", "site", "confluence"]
        case .microsoft: ["client_id", "tenant_id"]
        }
    }

    /// Checks the whole save first (its shape, then the wizard's state), and
    /// only then applies it: a refused save changes nothing.
    package func saveDraft(vendor: String, fields: [String: String]) async -> Result<Void, ConnectDriverError> {
        guard let v = CompanyVendor(rawValue: vendor) else { return .failure(.badArgs("unknown vendor \(vendor)")) }
        if let error = Self.refusal(v, fields) { return .failure(error) }
        guard await ensureOpen() else { return .failure(.failed(openFailed)) }
        if let error = stateRefusal(v, fields) { return .failure(error) }
        // The vendor's values first: the Slack step's handoff is the only part
        // that can still fail, and then nothing else has landed.
        let own = fields.filter { Self.vendorKeys(v).contains($0.key) }
        if !own.isEmpty {
            if let error = await applyVendor(v, own) { return .failure(error) }
            // Values for a service mean the company uses it.
            if !wizard.ticked.contains(v) { wizard.toggle(v) }
        }
        if let services = fields["services"] { applyServices(Self.list(services)) }
        if let name = fields["company"] { wizard.setCompanyName(name) }
        if let hosts = fields["deny_hosts"] { applyDenyHosts(Self.list(hosts).map { $0.lowercased() }) }
        guard await wizard.saveNow() else { return .failure(.failed(wizard.storageProblem ?? openFailed)) }
        return .success(())
    }

    /// Everything wrong with a save's shape.
    private static func refusal(_ v: CompanyVendor, _ fields: [String: String]) -> ConnectDriverError? {
        let allowed = commonKeys.union(vendorKeys(v))
        if let key = fields.keys.sorted().first(where: { !allowed.contains($0) }) {
            return .badArgs("\(key) is not a \(v.rawValue) draft field (\(allowed.sorted().joined(separator: ", ")))")
        }
        if let services = fields["services"], let bad = list(services).first(where: { CompanyVendor(rawValue: $0) == nil }) {
            return .badArgs("\(bad) is not a service (\(CompanyVendor.allCases.map(\.rawValue).joined(separator: ", ")))")
        }
        // Values for a vendor mean the company uses it: a services list without it contradicts them.
        if let services = fields["services"], !list(services).contains(v.rawValue), fields.keys.contains(where: vendorKeys(v).contains) {
            return .badArgs("\(v.rawValue) values come with a services list that leaves \(v.rawValue) out")
        }
        if let hosts = fields["deny_hosts"], list(hosts).contains(where: { !CompanySetupWizardModel.isHostName($0.lowercased()) }) {
            return .badArgs(CompanySetupWizardModel.denyInvalid)
        }
        if let on = fields["confluence"], on != "true", on != "false" { return .badArgs("confluence is true or false") }
        if let link = fields["settings_link"], CompanySetupWizardModel.appID(fromSettingsLink: link) == nil {
            return .badArgs(CompanySetupWizardModel.slackSettingsInvalid)
        }
        return nil
    }

    /// What the wizard's state refuses: a running step, dropping a service
    /// that holds entries (the customer's call on the page), a settings link
    /// of another app while the setup's Slack app is ready.
    private func stateRefusal(_ v: CompanyVendor, _ fields: [String: String]) -> ConnectDriverError? {
        let own = fields.keys.contains { Self.vendorKeys(v).contains($0) }
        if own, v == .slack ? wizard.slack.isRunning : wizard.isRunning(v) { return .busy }
        if let services = fields["services"] {
            let wanted = Set(Self.list(services).compactMap(CompanyVendor.init(rawValue:)))
            if let held = wizard.ticked.first(where: { !wanted.contains($0) && wizard.hasEntries($0) }) {
                return .failed("\(CompanyVendorGuide.name(held)) holds entries in the draft; the customer drops it on the "
                    + "setup wizard's Services step")
            }
        }
        if let link = fields["settings_link"], let appID = CompanySetupWizardModel.appID(fromSettingsLink: link),
           wizard.slackAppReady, wizard.draft.slack.appID != appID {
            return .failed(Self.otherSlackApp(wizard.draft.slack.appID))
        }
        if fields["settings_link"] != nil, wizard.publishState == .running { return .failed(Self.publishRunning) }
        if fields["settings_link"] != nil, wizard.discarding { return .failed(Self.discarding) }
        return nil
    }

    private func applyServices(_ names: [String]) {
        let wanted = Set(names.compactMap(CompanyVendor.init(rawValue:)))
        for v in CompanyVendor.allCases where wanted.contains(v) != wizard.ticked.contains(v) {
            wizard.toggle(v)
        }
    }

    /// The deny list becomes exactly `hosts` (each already a host name).
    private func applyDenyHosts(_ hosts: [String]) {
        for host in wizard.draft.denyHosts where !hosts.contains(host) {
            wizard.removeHost(host)
        }
        for host in hosts where !wizard.draft.denyHosts.contains(host) {
            wizard.hostField = host
            wizard.addHost()
        }
    }

    private func applyVendor(_ v: CompanyVendor, _ fields: [String: String]) async -> ConnectDriverError? {
        if v == .slack { return await applySlack(fields) }
        if let id = fields["client_id"] { wizard.setField(v, .clientID, id.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if let tenant = fields["tenant_id"] { wizard.setField(v, .tenantID, tenant.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if let site = fields["site"] { wizard.setAtlassianSite(site) }
        if let on = fields["confluence"] { wizard.setAtlassianConfluence(on == "true") }
        return nil
    }

    /// The Slack app's settings link: the wizard's Slack-step handoff
    /// (`request(.slackStep(appID:))`), then **We already have one** with
    /// the link. Its Client ID comes from the setup record or what the wizard
    /// found on this Mac; the agent's `client_id` is used when it gave one.
    private func applySlack(_ fields: [String: String]) async -> ConnectDriverError? {
        guard let link = fields["settings_link"] else {
            if let id = fields["client_id"] { wizard.setField(.slack, .clientID, id.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return nil
        }
        let appID = CompanySetupWizardModel.appID(fromSettingsLink: link) ?? ""
        // The setup's own app, ready on this Mac: nothing to adopt.
        if wizard.slackAppReady, wizard.draft.slack.appID == appID { return nil }
        guard await openSlackStep(appID: appID) else { return .failed(Self.slackDidNotStart) }
        wizard.abandonSlackStep()  // an earlier attempt starts over for this app
        shownUpdate = nil
        wizard.alreadyHaveOne()
        wizard.setField(.slack, .slackSettingsLink, link.trimmingCharacters(in: .whitespacesAndNewlines))
        if let id = fields["client_id"] { wizard.setField(.slack, .clientID, id.trimmingCharacters(in: .whitespacesAndNewlines)) }
        await wizard.next()  // Continue: the link names the app to update
        return nil
    }

    // MARK: - Secrets

    package func submitSecret(kind: String, value: String) async -> Result<Data, ConnectDriverError> {
        switch kind {
        case Self.googleSecret: return await saveSecret(.google, value)
        case Self.atlassianSecret: return await saveSecret(.atlassian, value)
        case Self.slackToken: return await runSlackStep(token: value)
        default: return .failure(.badArgs("kind \(kind) is not a company secret"))
        }
    }

    /// The client secret lands in the draft as if typed on the vendor's step.
    private func saveSecret(_ v: CompanyVendor, _ value: String) async -> Result<Data, ConnectDriverError> {
        let secret = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else { return .failure(.badArgs("the secret is empty")) }
        guard await ensureOpen() else { return .failure(.failed(openFailed)) }
        if wizard.isRunning(v) { return .failure(.busy) }
        if !wizard.ticked.contains(v) { wizard.toggle(v) }
        wizard.setField(v, .clientSecret, secret)
        guard await wizard.saveNow() else {
            return .failure(ConnectSecret.failure(wizard.storageProblem, secret: secret, fallback: openFailed))
        }
        return .success(Self.json(["result": "saved", "vendor": v.rawValue]))
    }

    /// The wizard's Slack step with the token: an update of the app whose
    /// settings link was saved (its changes then wait on the confirm card),
    /// else a new app from Watchtower's manifest.
    private func runSlackStep(token: String) async -> Result<Data, ConnectDriverError> {
        shownUpdate = nil
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failure(.badArgs("the token is empty")) }
        guard await ensureOpen() else { return .failure(.failed(openFailed)) }
        if wizard.slack.isRunning { return .failure(.busy) }
        if wizard.publishState == .running { return .failure(.failed(Self.publishRunning)) }
        let linked = CompanySetupWizardModel.appID(fromSettingsLink: wizard.slackSettingsLink)
        guard await openSlackStep(appID: linked ?? "") else { return .failure(.failed(Self.slackDidNotStart)) }
        if wizard.slackAppReady { return .success(Self.json(["result": "exists", "app_id": wizard.draft.slack.appID])) }
        wizard.abandonSlackStep()  // an earlier attempt's problem or diff starts over
        if let linked {
            if wizard.slackReuse?.appID != linked || wizard.phase(.slack) != .create {
                wizard.alreadyHaveOne()
                await wizard.next()  // the saved link names the app
            }
        } else {
            wizard.createNew()
        }
        wizard.slackToken = token
        guard wizard.startSlackStep() else {
            wizard.slackToken = ""
            return .failure(ConnectSecret.failure(wizard.slackProblem, secret: token, fallback: Self.slackDidNotStart))
        }
        await wizard.slack.runTask?.value
        if let diff = wizard.slackDiff {
            // The app was only read: its changes wait on the customer's card.
            shownUpdate = diff
            return .success(Self.json(["result": "confirm_update"]))
        }
        return slackAnswer()
    }

    /// How the Slack step's last run ended; the token goes either way.
    private func slackAnswer() -> Result<Data, ConnectDriverError> {
        shownUpdate = nil
        let token = wizard.slackToken
        wizard.slackToken = ""
        if let problem = wizard.slackProblem {
            return .failure(ConnectSecret.failure(problem, secret: token, fallback: Self.slackStopped))
        }
        guard wizard.slackAppReady else { return .failure(.failed(Self.slackStopped)) }
        return .success(Self.json(["result": "ok", "app_id": wizard.draft.slack.appID]))
    }

    package func secretConfirm(kind: String) -> ConnectAssistantConfirm? {
        guard kind == Self.slackToken, let shown = shownUpdate else { return nil }
        var pkce = false
        if case let .adopt(adopt) = wizard.slack.form { pkce = adopt.changes?.enablePKCE ?? false }
        return .slackUpdate(changes: shown.lines, pkce: pkce)
    }

    /// Yes updates exactly the app and changes the card showed, on the
    /// wizard's Slack step (never the step's primary action); a page that
    /// moved on, or a diff that changed, updates nothing.
    package func answerSecretConfirm(kind: String, yes: Bool) async -> Result<Data, ConnectDriverError> {
        guard kind == Self.slackToken, let shown = shownUpdate else { return .failure(.failed(Self.updateGone)) }
        guard yes else {
            dropUpdate()
            return .success(Self.json(["result": "declined"]))
        }
        guard wizard.updateSlackApp(appID: shown.appID, lines: shown.lines) else {
            dropUpdate()
            return .failure(.failed(Self.updateGone))
        }
        shownUpdate = nil
        await wizard.slack.runTask?.value
        if wizard.slackDiff != nil {
            // Slack answered with another diff: nothing more runs without a new card.
            dropUpdate()
            return .failure(.failed(Self.slackStopped))
        }
        return slackAnswer()
    }

    package func secretConfirmDropped(kind: String) {
        // Only this driver's own update waits on the card: a token or diff the
        // customer has on the page is theirs, and stays.
        guard kind == Self.slackToken, shownUpdate != nil else { return }
        dropUpdate()
    }

    /// The update is not going ahead: the token and the shown diff go.
    private func dropUpdate() {
        shownUpdate = nil
        wizard.abandonSlackStep()
    }

    // MARK: - Checks and Publish

    package func confirmNeeded(tool: String, options: [String: String]) -> ConnectAssistantConfirm? {
        guard wizard.load == .ready else { return nil }
        switch tool {
        case "company_publish":
            // Side effect, as entering the Publish step: `preparePublish()` prefills the
            // company name and makes the sheet show its token field.
            wizard.preparePublish()
            guard publishBlockedReason == nil else { return nil }
            return .companyPublish(company: publishName,
                                   services: wizard.ticked.filter(wizard.isActive).map(CompanyVendorGuide.name))
        case "company_check":
            // A check found the company stored with another app: replacing it needs the customer (§2.12).
            guard let v = options["vendor"].flatMap(CompanyVendor.init(rawValue:)), wizard.checks[v] == .replaceNeeded else {
                return nil
            }
            return .companyReplace(company: publishName)
        default:
            return nil
        }
    }

    private var publishName: String {
        let typed = wizard.publishName.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? wizard.draft.company : typed
    }

    package func check(vendor: String) async -> Result<Data, ConnectDriverError> {
        guard let v = CompanyVendor(rawValue: vendor), v != .slack else {
            return .failure(.badArgs("\(vendor) has no check: Google, Atlassian, Linear and Microsoft 365 do"))
        }
        guard await ensureOpen() else { return .failure(.failed(openFailed)) }
        guard wizard.ticked.contains(v) else { return .failure(.badArgs("\(vendor) is not among the company's services")) }
        if wizard.isRunning(v) { return .failure(.busy) }
        guard wizard.valuesComplete(v) else {
            return .failure(.failed("The draft has no complete \(CompanyVendorGuide.name(v)) values yet."))
        }
        // Only after the Replace card (`confirmNeeded`) does a check replace the stored app.
        await wizard.check(v, replace: wizard.checks[v] == .replaceNeeded)
        switch wizard.checks[v] {
        case .passed?:
            return .success(Self.json(ConnectCompanyChecked(result: "ok", account: wizard.connectedAs[v])))
        case let .adminConsent(url)?:
            return .success(Self.json(ConnectCompanyChecked(result: "admin_consent", adminConsentURL: url)))
        case .replaceNeeded?:
            return .success(Self.json(ConnectCompanyChecked(result: "replace_needed")))
        case let .failed(line)?:
            return .failure(.failed(line))
        case .idle?, .running?, nil:
            return .failure(.failed(Self.checkLeft))
        }
    }

    package var publishNeedsToken: Bool { wizard.isActive(.slack) }

    /// The name Publish uses and every draft value, without where the
    /// wizard's page stands (`step`, `startedAt`): moving between pages is
    /// no change to what gets published; any edit, here or on the page, is.
    /// Only its SHA-256 leaves: the draft holds client secrets.
    package var publishRevision: String {
        var draft = wizard.draft
        draft.step = ""
        draft.startedAt = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var values = Data(publishName.utf8)
        values.append(0x0A)
        values.append((try? encoder.encode(draft)) ?? Data())
        return SHA256.hash(data: values).map { String(format: "%02x", $0) }.joined()
    }

    package var publishBlockedReason: String? {
        guard wizard.load == .ready else { return Self.notOpen }
        if wizard.publishState == .running { return Self.publishRunning }
        if wizard.discarding { return Self.discarding }
        return wizard.publishBlockedReason
    }

    package func publish(token: String, approvedRevision: String) async -> Result<Data, ConnectDriverError> {
        guard await ensureOpen() else { return .failure(.failed(openFailed)) }
        if let reason = publishBlockedReason { return .failure(.failed(reason)) }
        guard publishRevision == approvedRevision else {
            return .failure(.failed(CompanySetupWizardModel.publishChangedLine))
        }
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if publishNeedsToken, token.isEmpty { return .failure(.failed(CompanySetupWizardModel.publishNeedsTokenLine)) }
        // Checked again once the draft Go publishes is saved, before the verb.
        await wizard.publish(token: publishNeedsToken ? token : nil) { [weak self] in
            self?.publishRevision == approvedRevision
        }
        switch wizard.publishState {
        case let .done(published):
            wizard.showPublished()
            return .success(Self.json(ConnectCompanyPublished(result: published.onSlackPage ? "ok" : "no_slack", slug: published.slug)))
        case .tokenExpired:
            return .failure(.failed(CompanySetupWizardModel.publishTokenExpiredLine))
        case let .failed(line):
            return .failure(ConnectSecret.failure(line, secret: token, fallback: Self.publishStopped))
        case .ready, .running:
            let line = wizard.publishRefusal ?? wizard.publishBlockedReason ?? Self.publishStopped
            return .failure(ConnectSecret.failure(line, secret: token, fallback: Self.publishStopped))
        }
    }

    // MARK: - No flows here

    package func start(options: [String: String]) async -> Result<String, ConnectDriverError> {
        .failure(.badArgs("the company setup has no connect_start: company_check signs in"))
    }

    package func wait(flowID: String) async -> ConnectWaitOutcome { .failed(reason: "the company setup runs no sign-in flow") }

    package func cancel(flowID: String) async {}

    package func setFields(_ fields: [String: String]) async -> Result<Void, ConnectDriverError> {
        .failure(.badArgs("the company setup saves its fields with company_draft"))
    }

    package func choose(kind: String, select: [String]?) async -> Result<[ConnectChoice], ConnectDriverError> {
        .failure(.badArgs("the company setup has nothing to choose"))
    }

    // MARK: - Helpers

    /// Reads the draft once per app run, as the page's first open does.
    @discardableResult
    private func ensureOpen() async -> Bool {
        if wizard.load == .notOpened { await wizard.open() }
        return wizard.load == .ready
    }

    private var openFailed: String { wizard.storageProblem ?? Self.notOpen }

    /// The wizard's Slack step, through the Slack-step handoff.
    private func openSlackStep(appID: String) async -> Bool {
        if wizard.current != .vendor(.slack) || !wizard.ticked.contains(.slack) {
            wizard.request(.slackStep(appID: appID))
        }
        return wizard.current == .vendor(.slack)
    }

    private static func list(_ text: String) -> [String] {
        text.split { $0 == "," || $0.isWhitespace }.map(String.init)
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    private static func json(_ value: some Encodable) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)) ?? Data("{}".utf8)
    }

    // MARK: - Copy (errors the agent reads to the customer)

    package static let notOpen = "The company setup could not be opened. Open it in Connections and try again."
    package static let publishRunning = "Publish is already running."
    package static let discarding = "The setup is being discarded."
    package static let publishStopped = "Publish did not go through."
    package static let checkLeft = "The check's values changed while it ran. Check again."
    package static let slackDidNotStart = "The Slack step did not start. Open the setup wizard's Slack step."
    package static let slackStopped = "The Slack step stopped before the app was ready. Finish it in the setup wizard."
    package static let updateGone = "The Slack update is no longer waiting. Run the Slack step again."
    package static func otherSlackApp(_ appID: String) -> String {
        "The setup already has Slack app \(appID) ready. The customer changes it on the setup wizard's Slack step."
    }
}
