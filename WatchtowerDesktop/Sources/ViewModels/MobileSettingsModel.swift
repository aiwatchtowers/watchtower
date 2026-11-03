import AppKit
import Foundation
import WatchtowerCore

/// Where Settings → Mobile reads the one-time hand-over of Mobile to the Go
/// hub (go hub plan 3 Task 22): `HubAdoptionDriver`'s state through the app
/// (`AppState`). While it is shown the tab shows it instead of the hub.
@MainActor
protocol MobileAdoptionSource: AnyObject {
    var adoptionState: HubAdoptionState { get }
    func retryHandOver() async
    /// **Set up Mobile again** after a hand-over that cannot finish, once the owner confirmed.
    func setUpHandOverAgain() async
}

/// Settings → Mobile over `watchtower hub …` (go hub plan 3 Task 23, spec
/// §12.4): the hub's on/off with its reason, the Mac name, the recordings
/// switch, the transport and who switched it, the linked phones with their
/// transport and grants, the recordings the update kept and the failed
/// phone recordings (Retry, Discard). Every read is `hub … --json`, every
/// write a `hub …` verb; the hub's database is never opened here.
///
/// It reloads every `refreshInterval` while the window is on screen
/// (`windowVisibility`, run by the view's `.task`), after each write, and
/// when the tab is told the hub changed (`HubCenter`'s status and its
/// `switched` / linked pairing events).
@MainActor
@Observable
final class MobileSettingsModel {
    enum State: Equatable {
        case loading
        case off(reason: String)
        case noPhones
        case phones([PhoneRow])
        case adoption(HubAdoptionState)
        case error(String)
    }

    struct PhoneRow: Equatable, Identifiable {
        let id: String
        let name: String
        /// "iCloud" | "Relay" | "Waiting for Relay".
        let transportLabel: String
        let transport: String
        let scope: String
        /// "Linked 12 Oct · Relay", plus who switched when the phone is on the hub's current transport.
        let detailLine: String
        let switchedLine: String?
        let typing, permissions, startSessions: Bool
        let typingRequested, permissionsRequested, startSessionsGranted: Bool
        /// What the phone asks for and the owner has not allowed yet.
        let requests: [String]
    }

    struct KeptRecordings: Equatable {
        let count: Int
        let removeAt: Date
        let dir: URL
    }

    /// A phone recording Desktop failed; its audio is kept until the prune.
    struct FailedRecording: Equatable, Identifiable {
        let id: String
        let line: String
        let retryable: Bool
    }

    /// The control a write in flight belongs to: its row shows a spinner and
    /// its control is disabled; the rest stays usable.
    enum Busy: Hashable {
        case toggle, recordings, name
        case phone(String)
        case recording(String)
    }

    /// The grants `hub allow` takes.
    nonisolated static let typingGrant = "typing"
    nonisolated static let permissionsGrant = "permissions"
    nonisolated static let startSessionsGrant = "start_sessions"
    /// The `Tone.status` name of the iCloud pill.
    nonisolated static let iCloudStatusColor = "blue"

    /// A transport's kind, for its pill: `cloudkit`, `relay`, else waiting (`pending`).
    enum TransportKind: Equatable {
        case iCloud, relay, pending

        init(_ transport: String) {
            switch transport {
            case "cloudkit": self = .iCloud
            case "relay": self = .relay
            default: self = .pending
            }
        }
    }

    nonisolated static let refreshInterval: Duration = .seconds(30)
    nonisolated static let startingRefreshInterval: Duration = .seconds(5)

    private(set) var state: State = .loading
    private(set) var recordingsOn = false
    /// False once the hub refused `on` for want of a transcriber: the switch is off-only.
    private(set) var recordingsAvailable = true
    private(set) var recordingsError: String?
    private(set) var macName = ""
    /// The hub's transport as `hub status` names it (`cloudkit`, `relay`).
    private(set) var hubTransport: String?
    private(set) var hubSwitchedLine: String?
    private(set) var hubLine: HubLine?
    /// Today's off-delete line while the owner's switch is off.
    private(set) var offDeleteLine: String?
    /// Today's iCloud lines (the Swift hub's tab): the build cannot use
    /// iCloud, the account's sentence, CloudKit slowing sync down.
    private(set) var showsNeedsSignedBuild = false
    private(set) var accountLine: String?
    private(set) var throttledSince: Date?
    private(set) var canLink = false
    private(set) var keptRecordings: KeptRecordings?
    private(set) var failedRecordings: [FailedRecording] = []
    /// Set by the writes; settable for the design shots of a write in flight.
    var busy: Set<Busy> = []
    /// The outcome of the last write that needs saying (a Remove, a refusal).
    private(set) var notice: String?
    private(set) var keepAwake: Bool
    let showsCorpNotice: Bool

    var pendingAllow: PhoneRow?
    var pendingStartSessionsAllow: PhoneRow?
    var pendingPermissionsAllow: PhoneRow?
    var pendingRemove: PhoneRow?
    /// The phone the Remove dialog is about, kept while it dismisses.
    private(set) var removeSubject: PhoneRow?
    var pendingDiscard: FailedRecording?
    /// The rename field while it is up.
    var renaming: String?
    /// The pairing sheet while it is up.
    private(set) var pairing: MobilePairingModel?

    @ObservationIgnored private let cli: MobileHubCLI
    @ObservationIgnored private weak var adoption: (any MobileAdoptionSource)?
    @ObservationIgnored private let pairStreamer: (any HubPairStreaming)?
    /// Retry through Desktop's phone recording queue (it claims and transcribes).
    @ObservationIgnored private let retryInQueue: (@MainActor (String) -> Void)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let openInFinder: @MainActor (URL) -> Void
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let sleep: @Sendable (Duration) async -> Void
    @ObservationIgnored private var hubState = ""
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var loadAgain = false

    init(
        cli: (any CLIRunnerProtocol)?,
        adoption: (any MobileAdoptionSource)? = nil,
        retryRecording: (@MainActor (String) -> Void)? = nil,
        pairStreamer: (any HubPairStreaming)? = nil,
        showsCorpNotice: Bool = false,
        defaults: UserDefaults = .standard,
        openInFinder: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) },
        now: @escaping () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.cli = MobileHubCLI(runner: cli)
        self.adoption = adoption
        self.pairStreamer = pairStreamer
        self.retryInQueue = retryRecording
        self.showsCorpNotice = showsCorpNotice
        self.defaults = defaults
        self.openInFinder = openInFinder
        self.now = now
        self.sleep = sleep
        keepAwake = defaults.object(forKey: Constants.mobileKeepAwakeKey) as? Bool ?? true
    }

    /// The owner's switch: off for `disabled`, on for any other state but a policy's.
    var isOn: Bool {
        if case .off(let reason) = state { return Self.offCopy(reason).toggleOn }
        return true
    }

    // MARK: - Reading

    /// Reads the hub (status, phones, failed recordings); one read at a time,
    /// one more queued. Only the first read shows `.loading`; a failed read
    /// shows the error with Retry.
    func load() async {
        guard !loading else {
            loadAgain = true
            return
        }
        loading = true
        defer { loading = false }
        repeat {
            loadAgain = false
            await readOnce()
        } while loadAgain
    }

    private func readOnce() async {
        if let adopting = adoption?.adoptionState, adopting.isShown {
            state = .adoption(adopting)
            canLink = false
            return
        }
        do {
            let status = try await cli.status()
            guard status.state != "off" else {
                present(status: status, phones: [], jobs: nil)
                return
            }
            let phones = try await cli.phones()
            // A failed read (a hub with no queue yet, an older CLI) hides the
            // failed recordings and changes nothing else.
            let jobs = try? await cli.recordingJobs()
            present(status: status, phones: phones, jobs: jobs)
        } catch is CancellationError {
            // The tab went away mid-read: what it shows stays.
        } catch {
            guard !Task.isCancelled else { return }
            present(failure: MobileHubCLI.reason(error))
        }
    }

    /// Shows one read of the hub: its status, its phones and its recording
    /// queue (nil when unread).
    func present(status: MobileHubCLI.Status, phones: [MobileHubCLI.Phone], jobs: MobileHubCLI.RecordingJobs?) {
        apply(status)
        guard status.state != "off" else {
            state = .off(reason: status.reason ?? "")
            failedRecordings = []
            return
        }
        let rows = rowsFor(phones, status: status)
        state = rows.isEmpty ? .noPhones : .phones(rows)
        failedRecordings = Self.failedRecordings(jobs)
    }

    /// Shows a read that failed, with its reason.
    func present(failure: String) {
        state = .error(Self.loadFailed(failure))
        canLink = false
    }

    private func apply(_ status: MobileHubCLI.Status) {
        hubState = status.state
        macName = status.name ?? macName
        recordingsOn = status.recordings == "on"
        canLink = status.state == "running"
            && Self.accountAllowsLinking(transport: status.transport, account: status.cloudKit?.account)
        hubLine = status.state == "off" ? nil : Self.hubLine(state: status.state, reason: status.reason)
        offDeleteLine = status.state == "off" ? Self.offDeleteLine(status.offDelete) : nil
        // Only on a known fact: a hub with no status file says neither.
        showsNeedsSignedBuild = status.bridge == "unavailable" || status.cloudKit?.account == "no_entitlement"
        recordingsAvailable = status.transcriber
        let running = status.state != "off"
        accountLine = running ? status.cloudKit.flatMap { Self.accountLine($0.account) } : nil
        throttledSince = running ? status.cloudKit?.throttledSince : nil
        hubTransport = status.transport
        keptRecordings = status.keptRecordings.flatMap { kept in
            kept.count >= 1 ? KeptRecordings(count: kept.count, removeAt: kept.removeAt, dir: URL(fileURLWithPath: kept.dir)) : nil
        }
    }

    private func rowsFor(_ phones: [MobileHubCLI.Phone], status: MobileHubCLI.Status) -> [PhoneRow] {
        let names = Dictionary(phones.map { ($0.deviceID.uppercased(), $0.name) }) { first, _ in first }
        let switched = status.switchedAt.flatMap { at in status.switchedBy.map { (at, $0) } }
        hubSwitchedLine = switched.flatMap { at, by in
            status.transport.map { Self.hubSwitchedLine(to: $0, by: by, at: at, now: now(), names: names) }
        }
        return phones.map { phone in
            let label = Self.transportLabel(phone.transport)
            let switchedLine = switched.flatMap { at, by in
                phone.transport == status.transport ? Self.phoneSwitchedLine(by: by, at: at, now: now(), names: names) : nil
            }
            var requests: [String] = []
            if phone.typingRequested, !phone.typingAllowed { requests.append(Self.typingGrant) }
            if phone.permissionsRequested, !phone.permissionsAllowed { requests.append(Self.permissionsGrant) }
            return PhoneRow(
                id: phone.deviceID, name: phone.name, transportLabel: label, transport: phone.transport, scope: phone.scope,
                detailLine: ([Self.scopeLabel(phone.scope), Self.linkedText(phone.linkedAt), label, switchedLine])
                    .compactMap { $0 }.joined(separator: " · "),
                switchedLine: switchedLine,
                typing: phone.typingAllowed, permissions: phone.permissionsAllowed, startSessions: phone.startSessionsAllowed,
                typingRequested: phone.typingRequested, permissionsRequested: phone.permissionsRequested,
                startSessionsGranted: phone.startSessionsGranted, requests: requests
            )
        }
    }

    /// The failed phone recordings Desktop can act on: those it failed itself.
    nonisolated static func failedRecordings(_ listing: MobileHubCLI.RecordingJobs?) -> [FailedRecording] {
        guard let listing, listing.ready else { return [] }
        return listing.jobs.compactMap { job in
            guard job.status == "failed", let failure = job.errorClass.flatMap(PhoneRecordingQueue.FailureClass.init(rawValue:)) else {
                return nil
            }
            return FailedRecording(id: job.uploadID, line: failedRecordingLine(failure), retryable: failure != .missingAudio)
        }
    }

    /// The view's `.task`, keyed on its window being on screen: reads now and
    /// then every `refreshInterval` (5 s while the hub starts) until the task
    /// is cancelled. A hidden or closed window closes an open pairing.
    func windowVisibility(_ visible: Bool) async {
        guard visible else {
            pairingDismissed()
            return
        }
        while !Task.isCancelled {
            await load()
            guard !Task.isCancelled else { return }
            await sleep(hubState == "starting" ? Self.startingRefreshInterval : Self.refreshInterval)
        }
    }

    /// The tab left the screen: an open pairing closes.
    func disappeared() {
        pairingDismissed()
    }

    // MARK: - Writes

    func setEnabled(_ on: Bool) async {
        if !on { pairingDismissed() }
        await write(.toggle, MobileHubCLI.enabledArgs(on)) { Self.couldNotSwitch(on, why: $0) }
    }

    /// The recordings switch; an `on` the hub refuses (no transcriber) is
    /// said inline under the switch, which then stays off.
    func setRecordings(_ on: Bool) async {
        busy.insert(.recordings)
        defer { busy.remove(.recordings) }
        do {
            let answer = try await cli.setRecordings(on)
            recordingsOn = answer.recordings == "on"
            if answer.error == "no_transcriber" {
                recordingsAvailable = false
                recordingsError = Self.noTranscriber
            } else {
                recordingsError = nil
            }
        } catch {
            recordingsError = MobileHubCLI.reason(error)
        }
        await load()
    }

    func allow(_ id: String, _ grant: String, _ on: Bool) async {
        let name = phone(id)?.name ?? Self.thisPhone
        await write(.phone(id), MobileHubCLI.allowArgs(id, grant, on)) { Self.couldNotChange(grant, name: name, why: $0) }
    }

    func unlink(_ id: String) async {
        guard let phone = phone(id) else { return }
        if await write(.phone(id), MobileHubCLI.unlinkArgs(id), failure: { Self.couldNotRemove(phone.name, why: $0) }) {
            notice = Self.removed(phone)
        }
    }

    /// The rename field's text while it is up.
    var renameText: String {
        get { renaming ?? "" }
        set { renaming = newValue }
    }

    /// Save in the rename field: it closes and the name is written.
    func saveRename() async {
        let name = renameText
        renaming = nil
        await rename(name)
    }

    /// What Remove does to the phone the dialog is about.
    var removeConsequence: String { Self.removeConsequence(scope: removeSubject?.scope ?? "") }

    func rename(_ name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != macName else { return }
        await write(.name, MobileHubCLI.nameArgs(trimmed)) { Self.couldNotRename($0) }
    }

    /// Runs one `hub …` write with its control busy, then reads again. Its
    /// refusal is the notice; true when it went through.
    @discardableResult
    private func write(_ item: Busy, _ args: [String], failure: (String) -> String) async -> Bool {
        busy.insert(item)
        defer { busy.remove(item) }
        let ok: Bool
        do {
            try await cli.run(args)
            notice = nil
            ok = true
        } catch {
            notice = failure(MobileHubCLI.reason(error))
            ok = false
        }
        await load()
        return ok
    }

    private func phone(_ id: String) -> PhoneRow? {
        guard case .phones(let rows) = state else { return nil }
        return rows.first { $0.id == id }
    }

    // MARK: - Confirmations (today's flow: Allow… asks first, Revoke at once)

    func requestAllow(_ phone: PhoneRow) { pendingAllow = phone }
    func requestStartSessionsAllow(_ phone: PhoneRow) { pendingStartSessionsAllow = phone }
    func requestPermissionsAllow(_ phone: PhoneRow) { pendingPermissionsAllow = phone }

    func confirmAllow() async {
        guard let phone = pendingAllow else { return }
        pendingAllow = nil
        await allow(phone.id, Self.typingGrant, true)
    }

    func confirmStartSessionsAllow() async {
        guard let phone = pendingStartSessionsAllow else { return }
        pendingStartSessionsAllow = nil
        await allow(phone.id, Self.startSessionsGrant, true)
    }

    func confirmPermissionsAllow() async {
        guard let phone = pendingPermissionsAllow else { return }
        pendingPermissionsAllow = nil
        await allow(phone.id, Self.permissionsGrant, true)
    }

    func requestRemove(_ phone: PhoneRow) {
        removeSubject = phone
        pendingRemove = phone
    }

    /// The confirmed Remove: nothing is removed without it.
    func confirmRemove() async {
        guard let phone = pendingRemove else { return }
        pendingRemove = nil
        await unlink(phone.id)
    }

    // MARK: - Pairing

    func linkPhone() {
        guard canLink, pairing == nil else { return }
        pairing = MobilePairingModel(streamer: pairStreamer, now: now, sleep: sleep)
    }

    /// The sheet closed (Done, Esc, the tab or window went away): the
    /// pairing stream stops and the phone list is read again.
    func pairingDismissed() {
        guard let sheet = pairing else { return }
        pairing = nil
        sheet.cancel()
        Task { await self.load() }
    }

    // MARK: - Recordings

    func showKeptRecordingsInFinder() {
        guard let kept = keptRecordings else { return }
        openInFinder(kept.dir)
    }

    /// Retry: Desktop's phone recording queue claims the job again over the
    /// control socket and transcribes it (without a queue: `hub recording claim`).
    func retryRecording(_ id: String) async {
        guard let retryInQueue else {
            await recordingWrite(id, MobileHubCLI.claimArgs(id), failure: Self.couldNotRetry)
            return
        }
        busy.insert(.recording(id))
        defer { busy.remove(.recording(id)) }
        retryInQueue(id)
        await load()
    }

    /// Link a phone needs a usable iCloud account while CloudKit carries the
    /// hub (today: no account or a restricted one hides it); an account not
    /// read yet does not hide it, and a Relay hub links without iCloud.
    nonisolated static func accountAllowsLinking(transport: String?, account: String?) -> Bool {
        guard transport == "cloudkit", let account, !account.isEmpty else { return true }
        return account == "available"
    }

    /// "iCloud is slowing sync down": CloudKit has rate-limited the hub for
    /// `slowingAfter` or longer (today's rule).
    var showsSlowingLine: Bool {
        guard let throttledSince else { return false }
        return now().timeIntervalSince(throttledSince) >= Self.slowingAfter
    }

    func requestDiscard(_ recording: FailedRecording) { pendingDiscard = recording }

    /// The confirmed Discard: the audio and the job go (`hub recording discard`).
    func confirmDiscard() async {
        guard let recording = pendingDiscard else { return }
        pendingDiscard = nil
        await recordingWrite(recording.id, MobileHubCLI.discardArgs(recording.id), failure: Self.couldNotDiscard)
    }

    private func recordingWrite(_ id: String, _ args: [String], failure: (String) -> String) async {
        await write(.recording(id), args, failure: failure)
    }

    // MARK: - Keep awake and adoption

    /// "Keep this Mac awake for the iPhone" (ask #614), the app's default.
    func setKeepAwake(_ enabled: Bool) {
        defaults.set(enabled, forKey: Constants.mobileKeepAwakeKey)
        keepAwake = enabled
    }

    func retryAdoption() async {
        await adoption?.retryHandOver()
        await load()
    }

    func setUpMobileAgain() async {
        await adoption?.setUpHandOverAgain()
        await load()
    }
}
