import Foundation
import Observation

/// **Set up for my company** (company screens spec §2, C1): the wizard's
/// steps, rail marks, the existing-app fork per vendor (D19), field values,
/// the checks, Publish and every string (`CompanySetupWizardModel+Copy.swift`).
/// Held on `AppState.companySetup`, so a check or a Slack create keeps
/// running when the page is left; its result lands in the draft.
///
/// Writers: the draft (`company/draft.json`) only through `company draft
/// save|discard` (secrets on stdin, Go owns the 0600 file and its lock, A12);
/// a check's mark only by Go (`RecordDraftCheck`), which a later save keeps;
/// the company bundle and the accounts only by `company check` and `company
/// publish`. The Slack app is the setup record's (`SlackAppSetupModel`); the
/// draft keeps only its App ID. The Slack configuration token stays in this
/// model's memory for the Slack step and Publish and is never written.
///
/// Failures: the CLI missing or dying is a step's problem line, never a
/// silent no-op; a quit mid-check leaves the step unchecked (the draft was
/// saved before the check started), so the step resumes at its check.
@MainActor
@Observable
package final class CompanySetupWizardModel {
    package enum Step: Hashable, Sendable {
        case services, vendor(CompanyVendor), denyList, publish

        /// The draft's `step`.
        package var draftName: String {
            switch self {
            case .services: "services"
            case let .vendor(v): v.rawValue
            case .denyList: "deny_list"
            case .publish: "publish"
            }
        }

        init?(draftName: String) {
            switch draftName {
            case "services": self = .services
            case "deny_list": self = .denyList
            case "publish": self = .publish
            default:
                guard let v = CompanyVendor(rawValue: draftName) else { return nil }
                self = .vendor(v)
            }
        }
    }

    /// A rail row's mark (the current step is the selected row).
    package enum StepMark: Equatable, Sendable {
        case done, reused, skipped, waiting, notStarted
    }

    /// What a vendor step shows above its check (§2.4).
    package enum VendorPhase: Equatable, Sendable {
        /// Discovery still running.
        case looking
        /// Known apps found: the first is the default.
        case found
        /// Nothing found: **Create new** (default) or **We already have one**.
        case nothingFound
        /// The guide and the fields (Slack: the token form).
        case create
        /// The identifying fields of an app the company already has.
        case existing
        /// A found client whose secret this Mac does not hold.
        case reuseSecret
        /// Google: the project cannot be created in the organization.
        case noOrgAccess
    }

    /// A vendor check's last run (§2.6–§2.8).
    package enum CheckState: Equatable, Sendable {
        case idle
        case running
        case passed
        /// A check over a client the stored company already had (§2.12).
        case replaceNeeded
        /// Microsoft: the tenant admin has not consented yet.
        case adminConsent(url: String)
        case failed(String)
    }

    package enum PublishState: Equatable, Sendable {
        case ready
        case running
        case done(Published)
        case tokenExpired
        case failed(String)
    }

    package struct Published: Equatable, Sendable {
        package let slug: String
        package let link: String
        package let code: String
        /// The link is on the Slack app's About page (`ok`, not `no_slack`).
        package let onSlackPage: Bool
    }

    /// Unticking a service whose step holds entries asks first (§2.3).
    package struct DropWarning: Equatable, Sendable {
        package let vendor: CompanyVendor
        package let title: String
        package let body: String
        package let drop: String
        package let keep: String
    }

    /// The step's one prominent action.
    package struct Primary: Equatable, Sendable {
        package let title: String
        package let enabled: Bool
    }

    package enum Load: Equatable, Sendable {
        case notOpened, loading, ready
    }

    // MARK: State

    package private(set) var load: Load = .notOpened
    package private(set) var draft = CompanyDraft()
    package private(set) var current: Step = .services
    /// The furthest step reached: rail rows up to it are clickable.
    package private(set) var reached: Set<Step> = [.services]
    /// The customer settled the services: continued past the Services step,
    /// resumed a draft beyond it, or the connect assistant saved a services
    /// list. Until then the ticks may be discovery's pre-ticks alone.
    package private(set) var servicesConfirmed = false
    package private(set) var candidates: [CompanyCandidate] = []
    package private(set) var discovering = false
    /// `company discover` failed: the vendor steps say so (never "nothing found").
    package private(set) var discoveryFailed = false
    /// Services discovery found an app for (pre-ticked, "Found on this Mac").
    package private(set) var foundVendors: Set<CompanyVendor> = []
    package private(set) var phases: [CompanyVendor: VendorPhase] = [:]
    /// **We already have one** (true) or **Create new** on the nothing-found choice.
    package var alreadyHaveSelected: [CompanyVendor: Bool] = [:]
    package private(set) var checks: [CompanyVendor: CheckState] = [:]
    /// Steps whose check passed, with the values it passed with: an edit
    /// un-checks the step (A28), the same values keep it.
    private(set) var checkedValues: [CompanyVendor: [String]] = [:]
    /// The account a sign-in check connected ("Connected as …").
    package private(set) var connectedAs: [CompanyVendor: String] = [:]
    /// The Atlassian check's grant without Confluence (Atlassian refused it).
    package private(set) var confluenceRefused = false
    /// The check ran under an MDM bundle of this company (§2.12).
    package private(set) var forcedVendors: Set<CompanyVendor> = []
    /// The Atlassian confirm checklist (§2.7), in memory only.
    package var atlassianConfirmed = [false, false, false]
    /// An Atlassian check passed this session: Publish waits for the checklist too.
    private var atlassianNeedsConfirm = false
    /// Published, but the draft is still on disk: the line says so.
    package private(set) var publishDraftLeft: String?
    /// The dropped Google client file's project ("project acme-watchtower").
    package private(set) var googleFile: (name: String, project: String)?
    package private(set) var googleFileProblem = false
    package private(set) var dropWarning: DropWarning?
    package private(set) var draftUnreadableFile: String?
    package private(set) var resumed = false
    package private(set) var publishState: PublishState = .ready
    package private(set) var publishSteps: [SlackAppSetupModel.StepLine] = []
    /// The company name Publish sends; prefilled, editable (§2.10).
    package var publishName = ""
    /// The Publish refusal the CLI gave (e.g. `name_taken`), shown under the summary.
    package private(set) var publishRefusal: String?
    /// The draft could not be saved or discarded: the line says so.
    package private(set) var storageProblem: String?

    // Slack step
    /// The configuration token field. Memory only: never in the draft, never in argv.
    package var slackToken = ""
    /// Publish asked for the token (none held, or the last one was refused):
    /// its field stays while it is typed, though `publishNeedsToken` turns false.
    package private(set) var publishTokenAsked = false
    /// The app chosen for reuse (Found, or the App ID entered).
    package private(set) var slackReuse: (appID: String, clientID: String)?
    /// The App ID field (**We already have one**): the id, or a link to the app.
    package var slackAppIDInput = ""
    /// The app's Client ID (Basic Information), for an app no account here is on.
    package var slackClientID = ""
    /// The App ID field's error: typed, but no App ID in it.
    package var slackAppIDInvalid: Bool {
        !slackAppIDInput.trimmingCharacters(in: .whitespaces).isEmpty && Self.slackAppID(from: slackAppIDInput) == nil
    }
    /// The last Slack run was started by this wizard (its problem shows).
    private var slackAttempt = false
    /// The running adopt confirms an app whose diff was shown.
    private var slackConfirming = false
    private var slackReused = false
    /// The deny list's field and its problem.
    package var hostField = ""
    package private(set) var hostInvalid = false

    @ObservationIgnored private let makeStreamer: @MainActor () -> (any CLILineStreaming)?
    private var streamer: (any CLILineStreaming)? { makeStreamer() }
    package let slack: SlackAppSetupModel
    @ObservationIgnored private let now: () -> Date
    /// A draft file exists on disk (read or saved by this run).
    private var hasDraft = false
    /// A readable draft is on disk (read or saved by this run): an unreadable
    /// one set aside earlier no longer stands for the setup.
    package var hasActiveDraft: Bool { hasDraft }
    /// The person changed something this session (discovery's pre-ticks alone make no draft).
    private var touched = false
    /// Bumped by Discard: a check of the discarded setup lands nowhere.
    @ObservationIgnored private var generation = 0
    /// Each running check's run: Cancel ends its stream, and a run that is
    /// no longer its vendor's (cancelled, or a new check started) writes nothing.
    @ObservationIgnored private var checkRuns: [CompanyVendor: CheckRun] = [:]

    /// The draft re-read that the last `cancelCheck` started.
    @ObservationIgnored package private(set) var rereadAfterCancel: Task<Void, Never>?
    /// Per vendor, bumped by its check's start and Cancel: a re-read after
    /// Cancel lands Go's mark only while no newer check of that vendor
    /// started. Another vendor's check never drops it; the name is guarded
    /// apart (`checkActivity`).
    @ObservationIgnored private var checkEpochs: [CompanyVendor: Int] = [:]
    /// Bumped by every check start and Cancel, of any vendor: a re-read after
    /// Cancel releases the name only while nothing started or was cancelled
    /// since (a check started and cancelled meanwhile may have stored the
    /// company under it).
    @ObservationIgnored private var checkActivity = 0

    private final class CheckRun {
        let values: [String]
        var task: Task<String?, Never>?

        init(values: [String]) { self.values = values }
    }

    package convenience init(streamer: (any CLILineStreaming)?, slack: SlackAppSetupModel, now: @escaping () -> Date = Date.init) {
        self.init(makeStreamer: { streamer }, slack: slack, now: now)
    }

    package init(
        makeStreamer: @escaping @MainActor () -> (any CLILineStreaming)?,
        slack: SlackAppSetupModel,
        now: @escaping () -> Date = Date.init
    ) {
        self.makeStreamer = makeStreamer
        self.slack = slack
        self.now = now
        slack.onFinished = { [weak self] outcome in self?.slackFinished(outcome) }
    }

    // MARK: Steps and rail

    /// The services ticked on the Services step, in the bundle's order.
    package var ticked: [CompanyVendor] {
        CompanyVendor.allCases.filter { draft.services.contains($0.rawValue) }
    }

    package var steps: [Step] {
        [.services] + ticked.map(Step.vendor) + [.denyList, .publish]
    }

    package func marks() -> [Step: StepMark] {
        var out: [Step: StepMark] = [:]
        let currentIndex = steps.firstIndex(of: current) ?? 0
        for (index, step) in steps.enumerated() {
            switch step {
            case .services:
                out[step] = currentIndex > 0 ? .done : .notStarted
            case let .vendor(v):
                out[step] = vendorMark(v)
            case .denyList:
                out[step] = currentIndex > index ? .done : .notStarted
            case .publish:
                if case .done = publishState { out[step] = .done } else { out[step] = .notStarted }
            }
        }
        return out
    }

    private func vendorMark(_ v: CompanyVendor) -> StepMark {
        if isSkipped(v) { return .skipped }
        switch v {
        case .slack:
            guard slackAppReady else { return .notStarted }
            return slackReused ? .reused : .done
        case .microsoft where draft.microsoftWaiting && !isChecked(v):
            return .waiting
        default:
            return isChecked(v) ? .done : .notStarted
        }
    }

    /// The draft's Slack app has its setup record (the record owns it).
    package var slackAppReady: Bool {
        !draft.slack.appID.isEmpty && slack.record(appID: draft.slack.appID) != nil
    }

    package func isSkipped(_ v: CompanyVendor) -> Bool { draft.skipped.contains(v.rawValue) }

    /// A ticked, not skipped service: part of what Publish packs.
    package func isActive(_ v: CompanyVendor) -> Bool { ticked.contains(v) && !isSkipped(v) }

    /// The step's check passed with the values it holds now (A28).
    package func isChecked(_ v: CompanyVendor) -> Bool {
        guard let values = checkValues(v), let checked = checkedValues[v] else { return false }
        return values == checked
    }

    /// The values a vendor's check uses (Go `checkValues`); nil: none yet.
    func checkValues(_ v: CompanyVendor) -> [String]? {
        Self.checkValues(v, in: draft)
    }

    /// The values a vendor's check runs with, in a given draft.
    private static func checkValues(_ v: CompanyVendor, in draft: CompanyDraft) -> [String]? {
        switch v {
        case .slack: draft.slack.appID.isEmpty ? nil : [draft.slack.appID]
        case .google: draft.google.map { [$0.clientID, $0.clientSecret] }
        case .atlassian: draft.atlassian.map { [$0.clientID, $0.clientSecret, $0.site, String($0.confluence)] }
        case .linear: draft.linear.map { [$0.clientID] }
        case .microsoft: draft.microsoft.map { [$0.clientID, $0.tenantID] }
        }
    }

    // MARK: Opening and leaving

    /// The page opens: reads the draft (an unreadable one was set aside by
    /// Go), looks for known apps and the Slack setup records. Once per
    /// session: coming back keeps what is in memory, including running checks.
    package func open() async {
        guard load == .notOpened else {
            await slack.reloadRecords()
            applyEntry()
            return
        }
        load = .loading
        // Unread, a draft on disk must not be overwritten by a fresh one:
        // the page shows the problem and the next open reads again.
        guard let show = await readDraft() else {
            load = .notOpened
            return
        }
        storageProblem = nil
        discovering = true
        apply(show)
        await discover()
        await slack.reloadRecords()
        load = .ready
        enter(current)
        applyEntry()
    }

    // MARK: Entry points (A19)

    /// Where a Slack setup-record row opens the page (company screens spec
    /// §0, A19, A32): **Add the link to the app** at Publish. `slackStep`
    /// opens the Slack step for an app (no setup-record row uses it: A32).
    package enum Entry: Equatable, Sendable {
        case slackStep(appID: String)
        case publish(appID: String)

        /// A setup-record row's entry: **Add the link to the app** opens
        /// Publish. Nil keeps plan B's sheet: a lost create (`pending_create`,
        /// clear or attach, never a second app), and `install` / `approval`,
        /// whose admin connect and approval check the wizard's Slack step does
        /// not run (it would take the app as ready and move on).
        package init?(record: SlackSetupRecord) {
            guard record.stage == "link_missing" else { return nil }
            self = .publish(appID: record.appID)
        }
    }

    /// Asked before the draft is read, an entry waits for it.
    @ObservationIgnored private var pendingEntry: Entry?

    /// Opens the page at an entry's step: applied now when the page is
    /// loaded, else once `open()` has read the draft.
    package func request(_ entry: Entry) {
        pendingEntry = entry
        applyEntry()
    }

    private func applyEntry() {
        guard let entry = pendingEntry, load == .ready else { return }
        pendingEntry = nil
        // Publish is running: the page stays on it (the row can be pressed again).
        guard publishState != .running else { return }
        // A Slack run still going decides the draft's app (it may end on a
        // form, never on an answer): the page shows that run at the Slack
        // step; the row can be pressed again once it is done.
        if slack.isRunning, ticked.contains(.slack) {
            if let index = steps.firstIndex(of: .vendor(.slack)) { reached.formUnion(steps.prefix(index + 1)) }
            move(to: .vendor(.slack))
            return
        }
        // A finished Publish starts fresh, as Done would.
        if isPublished { reset() }
        let (asked, appID): (Step, String) = switch entry {
        case let .slackStep(appID): (.vendor(.slack), appID)
        case let .publish(appID): (.publish, appID)
        }
        // The draft already holds another app: Publish would write that one's
        // page, so the Slack step opens instead and shows which app it is.
        let otherApp = !draft.slack.appID.isEmpty && !appID.isEmpty && draft.slack.appID != appID
        let target: Step = otherApp ? .vendor(.slack) : asked
        touched = true
        if !ticked.contains(.slack) {
            draft.services = CompanyVendor.allCases.filter { ticked.contains($0) || $0 == .slack }.map(\.rawValue)
        }
        draft.skipped.removeAll { $0 == CompanyVendor.slack.rawValue }
        // The record owns the app; the draft only references it, and never
        // loses an app of its own to another record's.
        if draft.slack.appID.isEmpty, !appID.isEmpty {
            draft.slack = .init(appID: appID)
            phases[.slack] = nil
        }
        guard let index = steps.firstIndex(of: target) else { return }
        reached.formUnion(steps.prefix(index + 1))
        move(to: target)
    }

    private func readDraft() async -> CompanyDraftShow? {
        guard let line = await lastJSONLine(["company", "draft", "show", "--json"], stdin: nil) else {
            storageProblem = Self.draftReadFailed
            return nil
        }
        guard let show = try? JSONDecoder().decode(CompanyDraftShow.self, from: Data(line.utf8)) else {
            storageProblem = Self.draftReadFailed
            return nil
        }
        return show
    }

    private func apply(_ show: CompanyDraftShow) {
        switch show.state {
        case "ok":
            guard let read = show.draft else { return }
            draft = read
            hasDraft = true
            resumed = true
            for name in show.checkedVendors {
                if let v = CompanyVendor(rawValue: name), let values = checkValues(v) { checkedValues[v] = values }
            }
            current = Step(draftName: read.step).flatMap { steps.contains($0) ? $0 : nil } ?? .services
            let index = steps.firstIndex(of: current) ?? 0
            reached = Set(steps.prefix(index + 1))
            servicesConfirmed = current != .services
            publishName = read.company
            if read.microsoftWaiting, let m = read.microsoft, !m.clientID.isEmpty, !m.tenantID.isEmpty {
                // Resumed while IT has not consented: the waiting layout, not a fresh form.
                checks[.microsoft] = .adminConsent(url: Self.adminConsentURL(tenant: m.tenantID, clientID: m.clientID))
            }
        case "unreadable":
            // A third state, never "no draft" (§2.2): Go renamed the file.
            draftUnreadableFile = show.badFile
            hasDraft = false
        default:
            break
        }
    }

    private func discover() async {
        defer { discovering = false }
        guard let line = await lastJSONLine(["company", "discover", "--json"], stdin: nil),
              let found = try? JSONDecoder().decode(CompanyDiscoverResult.self, from: Data(line.utf8)) else {
            // Not "nothing found": the steps say the look failed.
            discoveryFailed = true
            return
        }
        discoveryFailed = false
        candidates = found.candidates ?? []
        foundVendors = Set(candidates.compactMap { CompanyVendor(rawValue: $0.vendor) })
        // Pre-tick only a fresh setup: a resumed draft keeps its own choice.
        // Ticks the person made while it looked win.
        if !hasDraft, !touched {
            draft.services = CompanyVendor.allCases.filter(foundVendors.contains).map(\.rawValue)
        }
    }

    /// Leaving the page (‹ Connections, another service or tab, quitting):
    /// the draft is saved at the current step. A running check goes on.
    package func leave() async {
        // A running Publish saved the draft before it began and deletes it on success:
        // a save queued behind it would bring the draft back.
        guard load == .ready, hasDraft || touched, publishState != .running else { return }
        await saveDraft()
        resumed = true
    }

    /// "Continuing the setup you started on Nov 17."
    package var resumeLine: String? {
        guard resumed, hasDraft else { return nil }
        return Self.resumeLine(started: draft.startedAt ?? now())
    }

    package var draftUnreadable: (title: String, body: String, file: String)? {
        draftUnreadableFile.map { (Self.draftUnreadableTitle, Self.draftUnreadableBody(file: $0), $0) }
    }

    /// **Discard setup** (after the system confirmation): the draft and any
    /// set-aside one go; the stored bundle and the accounts the checks made
    /// stay (§2.12).
    package func discard() async {
        // Publish deletes the draft itself; a discard under it would land on a reset setup.
        guard publishState != .running, !discarding else { return }
        // Until it ends nothing else starts (Publish would save the draft back).
        discarding = true
        defer { discarding = false }
        // A check waiting on its pre-check save is abandoned now, never started.
        generation += 1
        // After any save in flight: a save landing later would bring the draft back.
        _ = await saving?.value
        guard await run(["company", "draft", "discard"], stdin: nil) else {
            storageProblem = Self.discardFailed
            // The abandoned checks' answers land nowhere: their steps are open again.
            for (v, state) in checks where state == .running { checks[v] = nil }
            return
        }
        reset()
    }

    private func reset() {
        generation += 1
        touched = false
        draft = CompanyDraft()
        current = .services
        reached = [.services]
        servicesConfirmed = false
        phases = [:]
        checks = [:]
        checkedValues = [:]
        connectedAs = [:]
        forcedVendors = []
        confluenceRefused = false
        atlassianConfirmed = [false, false, false]
        atlassianNeedsConfirm = false
        publishDraftLeft = nil
        googleFile = nil
        draftUnreadableFile = nil
        resumed = false
        hasDraft = false
        publishState = .ready
        publishSteps = []
        publishName = ""
        publishRefusal = nil
        publishTokenAsked = false
        storageProblem = nil
        slackToken = ""
        slackReuse = nil
        slackAttempt = false
        slackReused = false
        slackAppIDInput = ""
        slackClientID = ""
        slackConfirming = false
        hostField = ""
        hostInvalid = false
        googleFileProblem = false
        alreadyHaveSelected = [:]
        dropWarning = nil
        // A fresh setup pre-ticks what this Mac knows, as on a first open.
        draft.services = CompanyVendor.allCases.filter(foundVendors.contains).map(\.rawValue)
    }

    /// **Discard setup** is deleting the draft: Publish and the steps wait.
    package private(set) var discarding = false

    /// Publish went through: Go deleted the draft, which stays deleted.
    package var isPublished: Bool {
        if case .done = publishState { return true }
        return false
    }

    /// Publish went through from the connect assistant: the page shows
    /// Publish's result (link, code, **Connect this Mac**) whatever step it was on.
    package func showPublished() {
        guard isPublished else { return }
        reached.formUnion(steps)
        move(to: .publish)
    }

    /// **Done** after Publish: the page starts fresh next time.
    package func finish() {
        guard isPublished else { return }
        reset()
    }

    /// Saves run one after another (each a `company draft save` child): a
    /// later save never lands before an earlier one, so the newest state wins.
    @ObservationIgnored private var saving: Task<Bool, Never>?

    @discardableResult
    private func saveDraft() async -> Bool {
        let previous = saving
        let next = Task { [self] in
            _ = await previous?.value
            return await writeDraft()
        }
        saving = next
        return await next.value
    }

    /// The connect assistant's save (agent connect spec §5.4): `company
    /// draft save` of the state in memory now, queued behind any save in
    /// flight like the page's own. The wizard sheet and the assistant panel
    /// share this model, so the last save of either writes the whole draft
    /// and wins. True when it went through (else `storageProblem` says why).
    @discardableResult
    package func saveNow() async -> Bool {
        touched = true
        return await saveDraft()
    }

    private func writeDraft() async -> Bool {
        // Discard is deleting the draft: a save now (leaving the page) would bring it back.
        guard load == .ready, !isPublished, !discarding else { return false }
        var out = draft
        out.step = current.draftName
        guard let data = try? Self.encoder.encode(out), await run(["company", "draft", "save"], stdin: data) else {
            storageProblem = Self.draftSaveFailed
            return false
        }
        storageProblem = nil
        hasDraft = true
        if draft.startedAt == nil { draft.startedAt = now() }
        return true
    }

    // MARK: Services step

    /// Ticks or unticks a service. Unticking a step that holds entries
    /// returns the warning instead (nothing changes until `confirmDrop`).
    @discardableResult
    package func toggle(_ v: CompanyVendor) -> DropWarning? {
        touched = true
        if ticked.contains(v) {
            if hasEntries(v) {
                let warning = Self.dropWarningFor(v)
                dropWarning = warning
                return warning
            }
            untick(v)
        } else {
            draft.services = CompanyVendor.allCases.filter { ticked.contains($0) || $0 == v }.map(\.rawValue)
        }
        return nil
    }

    /// **Drop <vendor>**: its entries leave the draft.
    package func confirmDrop(_ v: CompanyVendor) {
        dropWarning = nil
        clearEntries(v)
        untick(v)
    }

    /// **Keep**.
    package func keepService() { dropWarning = nil }

    private func untick(_ v: CompanyVendor) {
        draft.services.removeAll { $0 == v.rawValue }
        draft.skipped.removeAll { $0 == v.rawValue }
        reached.remove(.vendor(v))
    }

    package func hasEntries(_ v: CompanyVendor) -> Bool {
        (checkValues(v) ?? []).contains { !$0.isEmpty && $0 != "true" && $0 != "false" }
    }

    private func clearEntries(_ v: CompanyVendor) {
        switch v {
        case .slack: draft.slack = .init(); slackReuse = nil
        case .google: draft.google = nil; googleFile = nil
        case .atlassian: draft.atlassian = nil; atlassianConfirmed = [false, false, false]
        case .linear: draft.linear = nil
        case .microsoft: draft.microsoft = nil; draft.microsoftWaiting = false
        }
        checkedValues[v] = nil
        checks[v] = nil
        phases[v] = nil
        connectedAs[v] = nil
    }

    // MARK: Moving between steps

    package var canContinueServices: Bool { !ticked.isEmpty }

    /// The connect assistant saved the customer's services list.
    package func confirmServices() { servicesConfirmed = true }

    /// **Back**.
    package func back() {
        // A running Publish keeps its step: its link and code land there.
        guard publishState != .running else { return }
        if case .vendor(.slack) = current, !slack.isRunning, slackAttempt || phase(.slack) == .existing {
            // From the Slack step's diff or problem, or its App ID field: back
            // to its choice (a step left on the field would open on it again,
            // with no way to Create new). The confirmed App ID goes too: only
            // Update the app may confirm it.
            slackAttempt = false
            slack.resetForm()
            phases[.slack] = nil
            enter(current)
            return
        }
        guard let index = steps.firstIndex(of: current), index > 0 else { return }
        move(to: steps[index - 1])
    }

    /// A rail row: only steps already reached.
    package func goTo(_ step: Step) {
        guard reached.contains(step), steps.contains(step), publishState != .running else { return }
        if case let .vendor(v) = step, isSkipped(v) {
            // Reopening a skipped step sets it up after all.
            draft.skipped.removeAll { $0 == v.rawValue }
        }
        move(to: step)
    }

    /// **Skip this step** (vendor steps): Skipped, and on to the next.
    package func skip() async {
        guard case let .vendor(v) = current, !isRunning(v) else { return }
        if !draft.skipped.contains(v.rawValue) { draft.skipped.append(v.rawValue) }
        await advance()
    }

    private func advance() async {
        guard let index = steps.firstIndex(of: current), index + 1 < steps.count else { return }
        if current == .services { servicesConfirmed = true }
        move(to: steps[index + 1])
        await saveDraft()
    }

    private func move(to step: Step) {
        current = step
        reached.insert(step)
        enter(step)
    }

    /// Opening a vendor step picks its first screen: entries already typed
    /// → the fields; known apps → Found; else the nothing-found choice.
    private func enter(_ step: Step) {
        if step == .publish { preparePublish() }
        guard case let .vendor(v) = step, load == .ready else { return }
        if v == .slack { enterSlack(); return }
        guard phases[v] == nil else { return }
        if hasEntries(v) {
            phases[v] = .create
        } else {
            phases[v] = candidates(for: v).isEmpty ? .nothingFound : .found
        }
    }

    package func phase(_ v: CompanyVendor) -> VendorPhase {
        if discovering { return .looking }
        return phases[v] ?? .nothingFound
    }

    package func isRunning(_ v: CompanyVendor) -> Bool {
        v == .slack ? slack.isRunning : checks[v] == .running
    }

    // MARK: The existing-app fork (D19)

    /// Known apps of a vendor, the first one the default; for Slack the
    /// draft's own app comes first when its setup record exists (resume
    /// after create offers reuse, never a second create).
    package func candidates(for v: CompanyVendor) -> [CompanyCandidate] {
        var found = candidates.filter { $0.vendor == v.rawValue }
        if v == .slack, let record = slack.record(appID: draft.slack.appID) {
            found.removeAll { $0.appID == record.appID || (!record.clientID.isEmpty && $0.clientID == record.clientID) }
            found.insert(CompanyCandidate(vendor: "slack", clientID: record.clientID, appID: record.appID,
                                          label: Self.slackAppLabel(record.appID), source: "draft",
                                          sourceLabel: Self.savedSetupSource(draft.company.isEmpty ? record.teamName : draft.company)), at: 0)
        }
        return found
    }

    /// **Use <app>** / **Use the selected client**.
    package func choose(_ c: CompanyCandidate) {
        guard case let .vendor(v) = current, v.rawValue == c.vendor else { return }
        draft.skipped.removeAll { $0 == v.rawValue }
        switch v {
        case .slack:
            chooseSlack(c)
        case .google:
            draft.google = .init(clientID: c.clientID)
            phases[v] = .reuseSecret
        case .atlassian:
            var a = draft.atlassian ?? .init()
            a.clientID = c.clientID
            draft.atlassian = a
            phases[v] = .existing
        case .linear:
            draft.linear = .init(clientID: c.clientID)
            phases[v] = .existing
        case .microsoft:
            draft.microsoft = .init(clientID: c.clientID, tenantID: c.tenantID)
            phases[v] = .existing
        }
    }

    /// **Create new**.
    package func createNew() {
        guard case let .vendor(v) = current else { return }
        if v == .slack { slackReuse = nil; slackAttempt = false }
        phases[v] = .create
    }

    /// **We already have one**.
    package func alreadyHaveOne() {
        guard case let .vendor(v) = current else { return }
        phases[v] = .existing
    }

    /// **Can't create a project in your organization?** (Google).
    package func showNoOrgAccess() {
        guard current == .vendor(.google) else { return }
        phases[.google] = .noOrgAccess
    }

    // MARK: Fields

    /// A typed value. Editing a value the step's check used un-checks it at
    /// once (A28); typing the same value back checks it again.
    package func setField(_ v: CompanyVendor, _ key: CompanyFieldSpec.Key, _ value: String) {
        touched = true
        switch (v, key) {
        case (.slack, .slackAppID):
            slackAppIDInput = value
        case (.slack, .clientID):
            slackClientID = value
        case (.google, .clientID): edit(\.google, .init()) { $0.clientID = value }
        case (.google, .clientSecret): edit(\.google, .init()) { $0.clientSecret = value }
        case (.atlassian, .clientID): edit(\.atlassian, .init()) { $0.clientID = value }
        case (.atlassian, .clientSecret): edit(\.atlassian, .init()) { $0.clientSecret = value }
        case (.linear, .clientID): edit(\.linear, .init()) { $0.clientID = value }
        case (.microsoft, .clientID): edit(\.microsoft, .init()) { $0.clientID = value }
        case (.microsoft, .tenantID): edit(\.microsoft, .init()) { $0.tenantID = value }
        default: return
        }
        if checks[v] != .running { checks[v] = nil }
        if v == .microsoft { draft.microsoftWaiting = false }
    }

    /// The Atlassian site, as typed (`acme.atlassian.net` or `https://…`).
    package func setAtlassianSite(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        edit(\.atlassian, .init()) { $0.site = trimmed.isEmpty || trimmed.contains("://") ? trimmed : "https://\(trimmed)" }
        if checks[.atlassian] != .running { checks[.atlassian] = nil }
    }

    /// Confluence on or off for the company's Atlassian app (the connect
    /// assistant's `company_draft` save; the page keeps the default, on).
    package func setAtlassianConfluence(_ on: Bool) {
        touched = true
        edit(\.atlassian, .init()) { $0.confluence = on }
        if checks[.atlassian] != .running { checks[.atlassian] = nil }
    }

    /// The dropped or pasted Google client JSON.
    @discardableResult
    package func dropGoogleClient(_ data: Data, fileName: String) -> Bool {
        guard let file = GoogleClientFile(data: data) else {
            googleFileProblem = true
            return false
        }
        googleFileProblem = false
        googleFile = (fileName, file.projectID)
        edit(\.google, .init()) {
            $0.clientID = file.clientID
            $0.clientSecret = file.clientSecret
        }
        if checks[.google] != .running { checks[.google] = nil }
        return true
    }

    private func edit<T>(_ path: WritableKeyPath<CompanyDraft, T?>, _ empty: T, _ change: (inout T) -> Void) {
        var value = draft[keyPath: path] ?? empty
        change(&value)
        draft[keyPath: path] = value
    }

    /// The values a vendor's check needs are all there.
    package func valuesComplete(_ v: CompanyVendor) -> Bool {
        guard let values = checkValues(v) else { return false }
        let filled = values.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return filled
    }

    // MARK: Checks (S28, A9)

    /// Runs the vendor's check: Google and Atlassian sign in through the
    /// entered client (that sign-in is the person's connection and stores
    /// the company bundle), Linear and Microsoft a dry authorize. The draft
    /// is saved first so Go marks the step for exactly these values.
    package func check(_ v: CompanyVendor, replace: Bool = false) async {
        guard v != .slack, checks[v] != .running, valuesComplete(v), let values = checkValues(v) else { return }
        var args = ["company", "check", v.rawValue, "--json"]
        var stdin: Data?
        switch v {
        case .google, .atlassian:
            guard let name = checkCompanyName else {
                checks[v] = .failed(Self.nameNeeded)
                return
            }
            // Go marks the step only for a draft of this company: the name is
            // saved with the draft before the check (and given back if it fails).
            draft.company = name
            if publishName.isEmpty { publishName = name }
            args.append("--app-return")
            if replace { args.append("--replace") }
            stdin = signInInput(v)
        case .linear:
            args += ["--client-id", values[0]]
        case .microsoft:
            args += ["--client-id", values[0], "--tenant", values[1]]
        case .slack:
            return
        }
        checks[v] = .running
        checkEpochs[v, default: 0] += 1
        checkActivity += 1
        let run = CheckRun(values: values)
        checkRuns[v] = run
        defer { if checkRuns[v] === run { checkRuns[v] = nil } }
        let started = generation
        guard await saveDraft(), generation == started, checkRuns[v] === run else {
            if generation == started, checkRuns[v] === run { checks[v] = .failed(Self.draftSaveFailed) }
            return
        }
        let task = Task { [args, stdin] in await checkAnswer(args, stdin: stdin) }
        run.task = task
        let line = await task.value
        // Discarded or cancelled meanwhile: Go kept what the sign-in stored
        // (the bundle, the account); this run's state is gone, so nothing lands here.
        guard generation == started, checkRuns[v] === run else { return }
        guard let line, let result = try? JSONDecoder().decode(CompanyCheckResult.self, from: Data(line.utf8)) else {
            checks[v] = .failed(Self.checkStopped)
            releaseUnstoredName()
            return
        }
        await finishCheck(v, result, values: values)
        if checks[v] != .passed { releaseUnstoredName() }
    }

    /// **Cancel** on a sign-in check's waiting line (#2132 C2): ends the run
    /// (its stream's task is cancelled, and `CLILineStream` kills the process
    /// group) and puts the step back to not-run, with no failed line. A run
    /// killed while Go saved may have stored the company, or even marked the
    /// step: the draft is re-read once (refresh only, silent on failure) and
    /// what landed is kept — the slug, and Go's check mark while the values
    /// are the ones the run checked. The name is released only when nothing
    /// was stored. A check of the same vendor started before the re-read
    /// answers wins: the answer then changes nothing. Another vendor's
    /// check only keeps the name (it signs in under it).
    package func cancelCheck(_ v: CompanyVendor) {
        guard checks[v] == .running, let run = checkRuns.removeValue(forKey: v) else { return }
        run.task?.cancel()
        checks[v] = nil
        checkEpochs[v, default: 0] += 1
        checkActivity += 1
        let epoch = checkEpochs[v]
        let activity = checkActivity
        let started = generation
        // A newer check of this vendor (started, or cancelled again) owns its step.
        let current = { [self] in generation == started && checkEpochs[v] == epoch }
        rereadAfterCancel = Task { [self] in
            // Only once the killed child has exited: Go may still be writing the draft.
            _ = await run.task?.value
            guard current() else { return }
            let line = await lastJSONLine(["company", "draft", "show", "--json"], stdin: nil)
            guard current() else { return }
            // An unanswered or unreadable re-read leaves open whether Go stored
            // the company: the name stays (released only on a read that says).
            guard let line, let show = try? JSONDecoder().decode(CompanyDraftShow.self, from: Data(line.utf8)),
                  show.state == "ok" || show.state == "none" else { return }
            if let read = show.draft {
                landed(v, read: read, checked: show.checkedVendors.contains(v.rawValue), values: run.values)
            }
            // Another vendor's check may still sign in under the name, or one
            // started (and maybe cancelled) since may have stored it.
            if checkRuns.isEmpty, checkActivity == activity { releaseUnstoredName() }
        }
    }

    /// What a cancelled sign-in stored before it was killed.
    private func landed(_ v: CompanyVendor, read: CompanyDraft, checked: Bool, values: [String]) {
        if draft.slug.isEmpty, !read.slug.isEmpty { draft.slug = read.slug }
        // As `apply(_:)` takes Go's marks on open, and only for the values the
        // run checked: on disk (Go saved them before it marked) and in the form.
        guard checked, Self.checkValues(v, in: read) == values, checkValues(v) == values, ticked.contains(v) else {
            return
        }
        checkedValues[v] = values
        // This session's sign-in, as a finished check: its checklist is still to tick.
        if v == .atlassian { atlassianNeedsConfirm = true }
    }

    /// The waiting line of a running check that signs in through the
    /// browser (Google, Atlassian); nil for the dry checks and when idle.
    package func checkWait(_ v: CompanyVendor) -> SignInWaitCopy? {
        guard checks[v] == .running, v == .google || v == .atlassian else { return nil }
        return SignInWaitCopy(vendor: v)
    }

    /// The name a check stores the company under: the draft's (a check ran
    /// before), else the one typed in Company name, else the derived one (A2).
    private var checkCompanyName: String? {
        let typed = publishName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = !draft.company.isEmpty ? draft.company : !typed.isEmpty ? typed : derivedName().name
        return name.isEmpty ? nil : name
    }

    /// The step asks for the company name (nothing to derive it from yet).
    package func needsCompanyName(_ v: CompanyVendor) -> Bool {
        checks[v] == .failed(Self.nameNeeded)
    }

    /// No check stored the company yet (no slug): its name is not fixed, so
    /// a failed check leaves Company name to what the person types (A2).
    private func releaseUnstoredName() {
        guard draft.slug.isEmpty else { return }
        draft.company = ""
    }

    private func signInInput(_ v: CompanyVendor) -> Data? {
        struct Input: Encodable {
            var company: String
            var slug: String?
            var google: CompanyDraft.Google?
            var atlassian: CompanyDraft.Atlassian?
        }
        let input = Input(company: draft.company, slug: draft.slug.isEmpty ? nil : draft.slug,
                          google: v == .google ? draft.google : nil, atlassian: v == .atlassian ? draft.atlassian : nil)
        return try? Self.encoder.encode(input)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private func finishCheck(_ v: CompanyVendor, _ result: CompanyCheckResult, values: [String]) async {
        let signedIn = result.result == "ok" || result.result == "forced"
        // A sign-in stored the company under the slug; replace_needed found it stored there.
        if !result.slug.isEmpty, signedIn || result.result == "replace_needed" { draft.slug = result.slug }
        if signedIn, !result.email.isEmpty { connectedAs[v] = result.email }
        // Values edited (or the service dropped) while it ran: the answer is
        // about values the step no longer holds. Go kept what the sign-in
        // connected; the step itself is left to a new check.
        guard checkValues(v) == values, ticked.contains(v) else {
            checks[v] = nil
            return
        }
        switch result.result {
        case "ok", "forced":
            if result.result == "forced" { forcedVendors.insert(v) } else { forcedVendors.remove(v) }
            // Go marks the draft's step; without that mark Publish refuses it,
            // so the step is not checked here either.
            guard result.checked else {
                checks[v] = .failed(Self.notRecorded(result.draftError))
                return
            }
            checkedValues[v] = values
            if v == .google, !result.domain.isEmpty { draft.google?.domain = result.domain }
            if v == .atlassian {
                confluenceRefused = result.confluenceRefused
                // This session's check: its settings checklist is still to tick.
                atlassianNeedsConfirm = true
            }
            if v == .microsoft { draft.microsoftWaiting = false }
            checks[v] = .passed
            // Dry checks move on; a sign-in moves on unless the confirm checklist follows.
            if current == .vendor(v), v != .atlassian {
                await advance()
            } else {
                await saveDraft()
            }
        case "admin_consent":
            draft.microsoftWaiting = true
            checks[v] = .adminConsent(url: result.adminConsentURL)
            await saveDraft()
        case "replace_needed":
            checks[v] = .replaceNeeded
        case "network":
            checks[v] = .failed(Self.networkLine(v, result.message))
        case "cancelled":
            checks[v] = .failed(Self.cancelledLine(result.message))
        default:
            checks[v] = .failed(Self.rejectedLine(v, code: result.code.isEmpty ? result.message : result.code,
                                                  tenant: draft.microsoft?.tenantID ?? ""))
        }
    }

    // MARK: Slack step (§2.5, through SlackAppSetupModel)

    private func enterSlack() {
        if !draft.slack.appID.isEmpty, slack.recordsRead, slack.record(appID: draft.slack.appID) == nil {
            // The record owns the app: none for this App ID → start at Look again.
            draft.slack = .init()
            slackReuse = nil
            phases[.slack] = nil
        }
        guard phases[.slack] == nil else { return }
        phases[.slack] = candidates(for: .slack).isEmpty ? .nothingFound : .found
    }

    private func chooseSlack(_ c: CompanyCandidate) {
        let appID = c.appID.isEmpty ? (slack.records.first { !c.clientID.isEmpty && $0.clientID == c.clientID }?.appID ?? "") : c.appID
        if !appID.isEmpty, appID == draft.slack.appID, slack.record(appID: appID) != nil {
            // The draft's own app (a create that ran before): nothing to redo.
            Task { await advance() }
            return
        }
        guard !appID.isEmpty else {
            // A client id with no App ID known here: the App ID field names it.
            slackReuse = nil
            slackClientID = c.clientID
            phases[.slack] = .existing
            return
        }
        slackReuse = (appID, c.clientID)
        slackAttempt = false
        phases[.slack] = .create
    }

    /// **Continue** on **We already have one**: the App ID field names the app.
    private func useEnteredAppID() {
        guard let appID = Self.slackAppID(from: slackAppIDInput) else { return }
        // An app no account here is on is adopted by its Client ID too (Go AdoptWith).
        let known = candidates.first { $0.vendor == "slack" && $0.appID == appID }?.clientID
            ?? slack.records.first { $0.appID == appID }?.clientID ?? ""
        let typed = slackClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        slackReuse = (appID, typed.isEmpty ? known : typed)
        slackAttempt = false
        phases[.slack] = .create
    }

    /// The App ID in what was entered for the app (Go `slackapp.ParseSlackAppID`,
    /// shared fixture `internal/slackapp/testdata/app_id_inputs.json`): the bare
    /// id in any case, or a link to the app (`api.slack.com/apps/A…`,
    /// `app.slack.com/app/A…`, `app.slack.com/apps/A…`, the scheme optional, any
    /// sub-page, query or fragment after it); upper-cased. Nil for anything
    /// else, and for anything but printable ASCII inside.
    package static func slackAppID(from input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else { return nil }
        if isSlackAppID(Substring(text)) { return text.uppercased() }
        let lower = text.lowercased()
        let scheme = ["https://", "http://"].first(where: lower.hasPrefix)?.count ?? 0
        let paths = ["api.slack.com/apps/", "app.slack.com/apps/", "app.slack.com/app/"]
        guard let path = paths.first(where: { lower.dropFirst(scheme).hasPrefix($0) }) else { return nil }
        let id = text.dropFirst(scheme + path.count).prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        return isSlackAppID(id) ? id.uppercased() : nil
    }

    /// `A` then letters and digits (any case), ASCII only.
    private static func isSlackAppID(_ s: Substring) -> Bool {
        s.count > 1 && s.first?.uppercased() == "A" && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    // MARK: The connect assistant's Slack step (agent connect spec §5.4, F3 relaxed)

    /// The Slack step's first run with the token in `slackToken`: a create,
    /// or the read of the app the App ID named. Only on the Slack
    /// step's token form; false when nothing started.
    package func startSlackStep() -> Bool {
        guard current == .vendor(.slack), phase(.slack) == .create, slackDiff == nil, slackProblem == nil,
              !slack.isRunning else { return false }
        startSlackRun()
        return slack.isRunning
    }

    /// **Update the app** for exactly the app and changes the customer
    /// confirmed in the panel; false (nothing runs) when the Slack step no
    /// longer shows that diff (the page moved on, or another run replaced it).
    package func updateSlackApp(appID: String, lines: [String]) -> Bool {
        guard current == .vendor(.slack), let diff = slackDiff, diff.appID == appID, diff.lines == lines,
              !slack.isRunning else { return false }
        startSlackRun()
        return slack.isRunning
    }

    /// The assistant's Slack step ended without an update (declined, or the
    /// card dropped): the token goes, and a shown diff with it; the step
    /// opens at its choice again. A running Slack run keeps its own copy.
    package func abandonSlackStep() {
        slackToken = ""
        guard slackAttempt, !slack.isRunning else { return }
        slackAttempt = false
        slackConfirming = false
        slack.resetForm()
        phases[.slack] = nil
        if current == .vendor(.slack) { enter(current) }
    }

    /// The company name from the connect assistant, kept in the draft like
    /// a check's: before any check stored the company (no slug) it becomes
    /// the draft's name; once stored, the name is fixed and the new one is
    /// only Publish's display name (as the page's Company name field).
    package func setCompanyName(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        touched = true
        publishName = name
        if draft.slug.isEmpty { draft.company = name }
    }

    private func startSlackRun() {
        let token = slackToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !slack.isRunning else { return }
        let confirming = slackDiff != nil
        // Only Update the app on the diff confirms an App ID: any other run
        // starts from a fresh form, so a stale confirmation never applies.
        if !confirming { slack.resetForm() }
        slackAttempt = true
        if let reuse = slackReuse {
            slackConfirming = confirming
            // The first run only reads the app (the diff); Update the app changes it.
            slack.startAdopt(token: token, appID: reuse.appID, clientID: reuse.clientID, dryRun: !confirming)
        } else {
            slackConfirming = false
            slack.startCreate(token: token)
        }
    }

    private func slackFinished(_ outcome: SlackSetupOutcome) {
        // A run of a discarded setup (or not this wizard's) changes nothing here.
        guard slackAttempt else { return }
        switch outcome {
        case let .created(appID), let .reused(appID):
            if case .reused = outcome { slackReused = true } else { slackReused = false }
            draft.slack = .init(appID: appID)
            draft.skipped.removeAll { $0 == "slack" }
            checkedValues[.slack] = [appID]
            slackAttempt = false
            phases[.slack] = .found
            Task {
                if current == .vendor(.slack) { await advance() } else { await saveDraft() }
            }
        case .failed:
            break
        }
    }

    /// The reused app's settings differ: what **Update the app** changes.
    /// The reused app's diff; `lines` is empty when its settings already match.
    package var slackDiff: (appID: String, lines: [String])? {
        guard slackAttempt, !slack.isRunning, case .editing = slack.phase, case let .adopt(adopt) = slack.form,
              let confirm = adopt.confirm else { return nil }
        return (confirm.appID, Self.diffLines(adopt.changes))
    }

    /// The Slack run's problem line (the wizard words not-collaborator and
    /// wrong-workspace itself, naming the app).
    package var slackProblem: String? {
        guard slackAttempt, !slack.isRunning else { return nil }
        if case .editing = slack.phase, case let .adopt(adopt) = slack.form, let problem = adopt.appIDProblem {
            return Self.appIDProblemLine(problem, appID: slackReuse?.appID ?? "")
        }
        guard case let .finished(.problem(problem)) = slack.phase else { return nil }
        switch problem {
        case .notCollaborator:
            return Self.notCollaborator(appID: slackReuse?.appID ?? "")
        default:
            return slack.problemLine(problem)
        }
    }

    /// The problem is about the app, not the token (not a collaborator,
    /// another workspace, an App ID Slack does not know): the step shows the
    /// problem alone, and **Try again** keeps the token in memory.
    package var slackProblemNamesTheApp: Bool {
        guard slackProblem != nil else { return false }
        if case .editing = slack.phase, case let .adopt(adopt) = slack.form, adopt.appIDProblem != nil { return true }
        guard case let .finished(.problem(problem)) = slack.phase else { return false }
        switch problem {
        case .notCollaborator, .wrongWorkspace: return true
        default: return false
        }
    }

    /// The Slack run's marks, in the wizard's words.
    package var slackProgress: [SlackAppSetupModel.StepLine] {
        guard slackAttempt else { return [] }
        let appID = slackReuse?.appID ?? ""
        return slack.steps.map { line in
            let label = switch line.id {
            case "read_app": Self.readingApp(appID)
            case "update_app": slackConfirming ? Self.updatingApp : Self.comparingApp
            default: line.label
            }
            return SlackAppSetupModel.StepLine(id: line.id, label: label, mark: line.mark)
        }
    }

    // MARK: Deny list (§2.9)

    /// **Add**: a host name only (no scheme, path, port or wildcard).
    package func addHost() {
        let host = hostField.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard Self.isHostName(host) else {
            hostInvalid = true
            return
        }
        hostInvalid = false
        hostField = ""
        if !draft.denyHosts.contains(host) { draft.denyHosts.append(host) }
    }

    package func removeHost(_ host: String) {
        draft.denyHosts.removeAll { $0 == host }
    }

    static func isHostName(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, host.count <= 253, let top = labels.last, !top.allSatisfy(\.isNumber) else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    // MARK: The primary action

    /// **Continue** and its variants, for the current step.
    package var primary: Primary {
        switch current {
        case .services:
            return Primary(title: Self.continueTitle, enabled: canContinueServices)
        case let .vendor(v):
            return vendorPrimary(v)
        case .denyList:
            return Primary(title: Self.continueTitle, enabled: true)
        case .publish:
            switch publishState {
            case .running: return Primary(title: Self.publishTitle, enabled: false)
            case .tokenExpired, .failed: return Primary(title: Self.tryAgainTitle, enabled: canPublish)
            case .done: return Primary(title: Self.connectThisMacTitle, enabled: !connectThisMacVendors.isEmpty)
            case .ready: return Primary(title: Self.publishTitle, enabled: canPublish)
            }
        }
    }

    private func vendorPrimary(_ v: CompanyVendor) -> Primary {
        if v == .slack { return slackPrimary }
        let running = checks[v] == .running
        switch phase(v) {
        case .looking:
            return Primary(title: Self.continueTitle, enabled: false)
        case .found:
            return Primary(title: candidates(for: v).count > 1 ? Self.useSelected : Self.useThisClient, enabled: true)
        case .nothingFound:
            return Primary(title: Self.continueTitle, enabled: true)
        case .create, .existing, .reuseSecret, .noOrgAccess:
            break
        }
        if isChecked(v) || checks[v].map(Self.isWaiting) == true {
            let ready = v != .atlassian || atlassianConfirmed.allSatisfy(\.self)
            return Primary(title: Self.continueTitle, enabled: ready && !running)
        }
        let title = switch (v, checks[v]) {
        case (_, .replaceNeeded?): Self.replaceAndCheck
        case (_, .failed?): Self.tryAgainTitle
        case (.atlassian, _): Self.checkBySignin
        default: Self.continueTitle
        }
        return Primary(title: title, enabled: !running && valuesComplete(v))
    }

    private static func isWaiting(_ state: CheckState) -> Bool {
        if case .adminConsent = state { return true }
        return false
    }

    private var slackPrimary: Primary {
        if slack.isRunning { return Primary(title: Self.continueTitle, enabled: false) }
        if slackDiff != nil { return Primary(title: Self.updateApp, enabled: !slackToken.isEmpty) }
        if slackProblem != nil { return Primary(title: Self.tryAgainTitle, enabled: true) }
        switch phase(.slack) {
        case .looking:
            return Primary(title: Self.continueTitle, enabled: false)
        case .found:
            let first = candidates(for: .slack).first
            return Primary(title: Self.useApp(first?.label ?? ""), enabled: true)
        case .nothingFound:
            return Primary(title: Self.continueTitle, enabled: true)
        case .existing:
            return Primary(title: Self.continueTitle, enabled: Self.slackAppID(from: slackAppIDInput) != nil)
        case .create, .reuseSecret, .noOrgAccess:
            let token = !slackToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return Primary(title: slackReuse == nil ? Self.createApp : Self.continueTitle, enabled: token)
        }
    }

    /// The primary button's press.
    package func next() async {
        guard primary.enabled else { return }
        switch current {
        case .services, .denyList:
            await advance()
        case let .vendor(v):
            await vendorNext(v)
        case .publish:
            switch publishState {
            case .done: return // Connect this Mac: the view opens the connect flow (Task 23).
            default: await publish(token: slackToken)
            }
        }
    }

    private func vendorNext(_ v: CompanyVendor) async {
        if v == .slack {
            await slackNext()
            return
        }
        switch phase(v) {
        case .looking:
            return
        case .found:
            if let first = candidates(for: v).first { choose(first) }
            return
        case .nothingFound:
            if alreadyHaveSelected[v] == true { alreadyHaveOne() } else { createNew() }
            return
        case .create, .existing, .reuseSecret, .noOrgAccess:
            break
        }
        if isChecked(v) || checks[v].map(Self.isWaiting) == true {
            await advance()
        } else {
            await check(v, replace: checks[v] == .replaceNeeded)
        }
    }

    private func slackNext() async {
        if case .editing = slack.phase, slackProblem != nil {
            // The App ID named no usable app: back to its field.
            slackAttempt = false
            slack.resetForm()
            phases[.slack] = .existing
            return
        }
        if slackDiff != nil || slackProblem != nil {
            if slackProblem != nil { slack.tryAgain() }
            startSlackRun()
            return
        }
        switch phase(.slack) {
        case .found:
            if let first = candidates(for: .slack).first { chooseSlack(first) }
        case .nothingFound:
            if alreadyHaveSelected[.slack] == true { alreadyHaveOne() } else { createNew() }
        case .existing:
            useEnteredAppID()
        case .create, .reuseSecret, .noOrgAccess:
            startSlackRun()
        case .looking:
            break
        }
    }

    // MARK: Publish (§2.10)

    /// Why Publish cannot run yet (Atlassian's spec line; any other ticked
    /// step without what Publish packs), nil when it can.
    package var publishBlockedReason: String? {
        if isActive(.atlassian), !isChecked(.atlassian) { return Self.publishWaitsAtlassian }
        if isActive(.atlassian), atlassianNeedsConfirm, !atlassianConfirmed.allSatisfy(\.self) {
            return Self.publishWaitsAtlassianConfirm
        }
        if isActive(.google), !isChecked(.google) { return Self.publishWaits(.google) }
        if isActive(.slack), !slackAppReady { return Self.publishWaits(.slack) }
        for v in [CompanyVendor.linear, .microsoft] where isActive(v) && !valuesComplete(v) {
            return Self.publishWaits(v)
        }
        if publishName.trimmingCharacters(in: .whitespaces).isEmpty { return Self.nameNeeded }
        return nil
    }

    /// Slack is part of the setup and the token is gone (a resumed draft or
    /// an expired token): the token field shows on Publish.
    package var publishNeedsToken: Bool {
        isActive(.slack) && slackToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canPublish: Bool {
        publishBlockedReason == nil && !publishNeedsToken && publishState != .running && !discarding
    }

    /// Packs the bundle and writes the link to the Slack app's About page.
    /// The token goes on stdin only. Failures keep the setup (Go keeps the
    /// draft and the stored bundle).
    /// `approved` (the connect assistant's Publish card): checked right
    /// after the draft is saved, with no suspension before the verb starts;
    /// false publishes nothing and leaves `publishRefusal` set.
    package func publish(token: String?, approved: (@MainActor () -> Bool)? = nil) async {
        guard publishBlockedReason == nil, publishState != .running, !discarding else { return }
        let token = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if isActive(.slack), token.isEmpty { return }
        publishRefusal = nil
        publishState = .running
        publishSteps = Self.publishStepLines(slack: isActive(.slack))
        guard await saveDraft() else {
            publishState = .failed(Self.draftSaveFailed)
            return
        }
        // The saved draft is what Go publishes: it must be the approved one.
        if let approved, !approved() {
            publishState = .ready
            publishRefusal = Self.publishChangedLine
            return
        }
        struct Input: Encodable {
            var company: String
            var config_token: String?
        }
        let name = publishName.trimmingCharacters(in: .whitespacesAndNewlines)
        let stdin = try? Self.encoder.encode(Input(company: name, config_token: isActive(.slack) ? token : nil))
        var final: CompanyPublishResult?
        let ended = await stream(["company", "publish", "--json"], stdin: stdin) { [self] line in
            if let step = try? JSONDecoder().decode(CompanyStepLine.self, from: Data(line.utf8)) {
                markPublishStep(step)
            } else if let result = try? JSONDecoder().decode(CompanyPublishResult.self, from: Data(line.utf8)) {
                final = result
            }
        }
        finishPublish(final, stopped: ended, name: name)
    }

    private func markPublishStep(_ line: CompanyStepLine) {
        guard let index = publishSteps.firstIndex(where: { $0.id == line.step }) else { return }
        publishSteps[index].mark = switch line.state {
        case "running": .running
        case "done": .done
        default: .failed
        }
    }

    private func finishPublish(_ result: CompanyPublishResult?, stopped: String?, name: String) {
        guard let result else {
            publishState = .failed(Self.publishStopped(stopped ?? Self.noAnswer))
            return
        }
        // A slug comes back once Go stored the bundle under the name sent (a
        // rename only changes the display name, ask #1613), and Go named the
        // draft so first: the next save and check use it too.
        if !result.slug.isEmpty { draft.company = name }
        switch result.result {
        case "ok", "no_slack":
            publishState = .done(Published(slug: result.slug, link: result.link, code: result.code,
                                           onSlackPage: result.result == "ok"))
            slackToken = ""
            // Go deleted the draft: nothing writes it back (leave, Done). One it
            // could not delete (or a newer one it kept) stays for Discard.
            hasDraft = !result.draftError.isEmpty
            publishDraftLeft = result.draftError.isEmpty ? nil : Self.publishDraftLeft(result.draftError)
            touched = false
            draftUnreadableFile = nil
        case "token_expired":
            slackToken = ""
            publishTokenAsked = true
            publishState = .tokenExpired
        case "network":
            publishState = .failed(result.message.isEmpty ? Self.publishNetworkFallback : result.message)
        case "atlassian_unchecked":
            publishState = .ready
            publishRefusal = Self.publishWaitsAtlassian
        default:
            publishState = .ready
            publishRefusal = refusalLine(result)
        }
    }

    private func refusalLine(_ result: CompanyPublishResult) -> String {
        switch result.reason {
        case "name_taken":
            return Self.publishNameTaken(publishName.trimmingCharacters(in: .whitespacesAndNewlines))
        case "company_forced":
            return Self.publishNameForced
        case "token_missing":
            slackToken = ""
            publishTokenAsked = true
            return Self.publishNeedsTokenLine
        case "wrong_workspace":
            // That token cannot write this app's page: the field asks for another.
            slackToken = ""
            publishTokenAsked = true
            return Self.publishWrongWorkspace
        default:
            return Self.publishRefused(result.message.isEmpty ? result.reason : result.message)
        }
    }

    /// **Connect this Mac** offers only what this setup did not connect:
    /// the sign-in checks connected Google and Atlassian already.
    package var connectThisMacVendors: [CompanyVendor] {
        ticked.filter { isActive($0) && !(($0 == .google || $0 == .atlassian) && isChecked($0)) }
    }

    /// The `.mobileconfig` for IT (`company profile --slug`); nil when it
    /// could not be made.
    package func profile() async -> Data? {
        guard case let .done(published) = publishState else { return nil }
        var data = Data()
        let failure = await stream(["company", "profile", "--slug", published.slug], stdin: nil) { line in
            data.append(Data((line + "\n").utf8))
        }
        return failure == nil && !data.isEmpty ? data : nil
    }

    // MARK: Company name (A2)

    /// Slack workspace name, else the Google Workspace domain's first label,
    /// else the Atlassian site's; `source` names where it came from.
    package func derivedName() -> (name: String, source: CompanyVendor?) {
        if let team = slack.record(appID: draft.slack.appID)?.teamName, !team.isEmpty { return (team, .slack) }
        if let domain = draft.google?.domain, let label = Self.firstLabel(domain) { return (label, .google) }
        if let site = draft.atlassian?.site, let host = URL(string: site)?.host, let label = Self.firstLabel(host) {
            return (label, .atlassian)
        }
        return ("", nil)
    }

    private static func firstLabel(_ host: String) -> String? {
        guard let first = host.split(separator: ".").first, !first.isEmpty else { return nil }
        return first.prefix(1).uppercased() + first.dropFirst()
    }

    /// The name field's prefill on entering Publish.
    package func preparePublish() {
        if publishName.isEmpty { publishName = draft.company.isEmpty ? derivedName().name : draft.company }
        if publishNeedsToken { publishTokenAsked = true }
    }

    /// Publish shows the token field: Slack is part of it and the token was asked for.
    package var publishShowsToken: Bool {
        isActive(.slack) && (publishTokenAsked || publishNeedsToken)
    }

    // MARK: The CLI

    /// Runs one verb; true when it exited 0.
    private func run(_ args: [String], stdin: Data?) async -> Bool {
        await stream(args, stdin: stdin) { _ in } == nil
    }

    /// The last line that is a JSON object (a sign-in also prints its
    /// browser lines); nil when the run failed before one.
    private func lastJSONLine(_ args: [String], stdin: Data?) async -> String? {
        var last: String?
        _ = await stream(args, stdin: stdin) { line in
            if line.hasPrefix("{") { last = line }
        }
        return last
    }

    /// A check's last JSON line (`lastJSONLine`), as a run that ends only
    /// when its child has exited — also when Cancel ended its stream early.
    private func checkAnswer(_ args: [String], stdin: Data?) async -> String? {
        guard let streamer else { return nil }
        let session = streamer.oneShot(args: args, stdin: stdin)
        var last: String?
        do {
            for try await line in session.lines {
                let text = line.trimmingCharacters(in: .whitespaces)
                if text.hasPrefix("{") { last = text }
            }
        } catch {
            // A failed run is "no answer", as in `lastJSONLine`.
        }
        await session.waitForExit()
        return last
    }

    /// Feeds each stdout line to `onLine`; returns nil on exit 0, else why it failed.
    private func stream(_ args: [String], stdin: Data?, onLine: (String) -> Void) async -> String? {
        guard let streamer else { return CLIRunnerError.binaryNotFound.localizedDescription }
        do {
            for try await line in streamer.lines(args: args, stdin: stdin) {
                onLine(line.trimmingCharacters(in: .whitespaces))
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
