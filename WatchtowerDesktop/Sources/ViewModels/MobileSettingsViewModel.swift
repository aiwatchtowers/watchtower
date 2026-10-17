import Foundation
import WatchtowerSync

/// What Settings → Mobile reads and drives on the app: the opt-in toggle
/// and the hub it builds (`AppState` conforms; tests use a fake).
@MainActor
protocol MobileSettingsHost: AnyObject {
    var isMobileSyncEnabled: Bool { get }
    var mobileHub: MobileHubService? { get }
    var mobileHubInitError: String? { get }
    func setMobileSyncEnabled(_ enabled: Bool)
}

/// Settings → Mobile on the Mac (mobile POC spec §2.3, §8 I-1, §9, §10):
/// the "Sync with iPhone" opt-in, the hub status, the QR sheet and
/// the linked phones (Allow… / Revoke typing, Allow… / Revoke starting
/// sessions, Allow… / Revoke answering permission prompts, Remove).
///
/// The hub and its link center are the app's (`AppState.mobileHub`); this
/// model reads them and refreshes the polled parts (iCloud account, last
/// publish, backlog, throttling) every `refreshInterval` while the tab is
/// on screen (`windowVisibility`, run by the view's `.task`).
@MainActor
@Observable
final class MobileSettingsViewModel {
    nonisolated static let corpNotice = "Work data from this Mac will be stored in your personal iCloud account."
    nonisolated static let needsSignedBuild = "Needs a signed build"
    nonisolated static let slowingLine = "iCloud is slowing sync down"
    /// D9/F18: a removed same-Apple-ID phone keeps what it already holds but gets no newer keys.
    nonisolated static func removedSameAppleID(_ name: String) -> String {
        "Removed \(name). It can no longer read anything new from this Mac."
    }
    /// Throttling this long shows `slowingLine` (spec §9).
    nonisolated static let slowingAfter: TimeInterval = 60
    nonisolated static let refreshInterval: Duration = .seconds(30)
    /// While the hub starts and until its first publish, so the tab does not
    /// look stalled right after Sync with iPhone is turned on.
    nonisolated static let startingRefreshInterval: Duration = .seconds(5)

    /// The wait before the next refresh: `startingRefreshInterval` while
    /// the hub is starting or running with no publish yet, else
    /// `refreshInterval` (an unavailable hub waits the long one).
    nonisolated static func nextRefresh(isOn: Bool, status: HubStatus?, lastPublishAt: Date?) -> Duration {
        guard isOn else { return refreshInterval }
        switch status {
        case .starting: return startingRefreshInterval
        case .running: return lastPublishAt == nil ? startingRefreshInterval : refreshInterval
        default: return refreshInterval
        }
    }

    /// The one-time confirmation of a phone's typing request (spec §10),
    /// the dialog's and the macOS notice's.
    nonisolated static func allowQuestion(name: String) -> String {
        "Allow \"\(name)\" to type into Claude Code sessions?"
    }

    /// The confirmation of answering permission prompts (#517, spec §5.1),
    /// the dialog's title.
    nonisolated static func permissionsQuestion(name: String) -> String {
        "Allow \"\(name)\" to approve commands in Claude Code sessions?"
    }

    /// The confirmation of starting sessions from the phone (#565), the
    /// dialog's title.
    nonisolated static func startSessionsQuestion(name: String) -> String {
        "Allow \"\(name)\" to start Claude Code sessions on this Mac?"
    }

    /// Remove's confirmation (spec §2.3), the dialog's title.
    nonisolated static func removeQuestion(name: String) -> String {
        "Remove \"\(name)\"?"
    }

    /// What Remove does to that phone, under the question: a shared phone
    /// loses the Mac's data at once; a same-Apple-ID one keeps what it
    /// already synced, but the Mac changes its keys (D9), so it reads
    /// nothing new.
    nonisolated static func removeConsequence(_ scope: DeviceScope) -> String {
        switch scope {
        case .private:
            "It stops syncing with this Mac and can no longer read anything new: this Mac changes its keys. "
                + "Linking it again needs a new code."
        default:
            "It leaves this Mac's iCloud sharing at once and loses its data. Linking it again needs a new code."
        }
    }

    /// A phone row's typing state.
    nonisolated static func typingLabel(_ device: HubSyncState.LinkedDevice) -> String {
        if device.typingAllowed { return "Typing allowed" }
        return device.typingRequested ? "Asks to type into sessions" : "Typing off"
    }

    /// A phone row's start-sessions state (#565): it needs typing too,
    /// because a started agent reads the target text the phone wrote.
    nonisolated static func startSessionsLabel(_ device: HubSyncState.LinkedDevice) -> String {
        if !device.typingAllowed { return "Starting sessions needs typing" }
        if !device.startSessionsGranted { return "Starting sessions off" }
        return device.startSessionsAllowed ? "Starting sessions allowed" : "Starting sessions allowed on the Mac — off on the phone"
    }

    /// The typing confirmation's message; a start grant stored from before
    /// comes back with typing (#565), so it says so.
    nonisolated static func allowMessage(_ device: HubSyncState.LinkedDevice?) -> String {
        let base = "The phone can then send text to sessions running on this Mac. Revoke turns it off again."
        guard device?.startSessionsGranted == true else { return base }
        return base + " Starting sessions, allowed earlier for this phone, comes back with it."
    }

    /// A phone row's permission-prompt state (#517).
    nonisolated static func permissionsLabel(_ device: HubSyncState.LinkedDevice) -> String {
        if device.permissionsAllowed { return "Permission prompts allowed" }
        return device.permissionsRequested ? "Asks to answer permission prompts" : "Permission prompts off"
    }

    /// `CloudKitTransport.entitlementPresent()`: false on an ad-hoc build,
    /// which cannot turn the toggle on (an inherited on can be turned off).
    let entitlementPresent: Bool
    let flavor: HubFlavor

    private(set) var isOn: Bool
    /// The Mac's iCloud account from the link center; nil until probed or
    /// while the hub is off.
    private(set) var account: CloudAvailability?
    private(set) var lastPublishAt: Date?
    private(set) var relayBacklog = 0
    private(set) var throttledSince: Date?
    /// When the polled parts were last read.
    private(set) var checkedAt: Date
    /// The outcome of the last phone action (Remove, a failed grant change).
    private(set) var notice: String?
    /// The phone whose Allow… waits for confirmation.
    var pendingAllow: HubSyncState.LinkedDevice?
    /// The phone whose start-sessions Allow… waits for confirmation.
    var pendingStartSessionsAllow: HubSyncState.LinkedDevice?
    /// The phone whose permission-prompts Allow… waits for confirmation.
    var pendingPermissionsAllow: HubSyncState.LinkedDevice?
    /// The phone whose Remove waits for confirmation; drives the dialog.
    var pendingRemove: HubSyncState.LinkedDevice?
    /// The phone the Remove dialog is about, kept while it dismisses (when
    /// `pendingRemove` is already nil), so its title and message never fall
    /// back to another phone's or a generic text.
    private(set) var removeSubject: HubSyncState.LinkedDevice?
    /// The QR sheet while it is up.
    private(set) var linkSheet: MobileLinkSheetViewModel?

    @ObservationIgnored private let host: any MobileSettingsHost
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let sleep: @Sendable (Duration) async -> Void

    init(
        host: any MobileSettingsHost,
        entitlementPresent: Bool = CloudKitTransport.entitlementPresent(),
        flavor: HubFlavor = HubIdentity.bundleFlavor(),
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.host = host
        self.entitlementPresent = entitlementPresent
        self.flavor = flavor
        self.now = now
        self.sleep = sleep
        isOn = host.isMobileSyncEnabled
        checkedAt = now()
    }

    var hub: MobileHubService? { host.mobileHub }
    var hubInitError: String? { host.mobileHubInitError }
    var devices: [HubSyncState.LinkedDevice] { hub?.linkCenter?.devices ?? [] }
    var showsCorpNotice: Bool { flavor == .corp }
    var toggleDisabled: Bool { !entitlementPresent && !isOn }

    /// The spec's sentence for an iCloud account the Mac can't use.
    var accountMessage: String? {
        guard let account, account != .available else { return nil }
        return MobileLinkError.account(account).errorDescription
    }

    /// The hub's status line; nil while off-toggle, or when the account
    /// sentence already says why the hub is unavailable.
    var statusLine: String? {
        guard isOn, let hub else { return nil }
        if case .unavailable = hub.status, accountMessage != nil { return nil }
        return Self.statusLine(hub.status)
    }

    /// Why turning the hub off did not fully go through (the zones kept or
    /// partly deleted); shown while the toggle is off.
    var hubOffLine: String? {
        guard !isOn else { return nil }
        return hub?.hubOffProblem
    }

    var showsSlowingLine: Bool {
        guard isOn, let throttledSince else { return false }
        return checkedAt.timeIntervalSince(throttledSince) >= Self.slowingAfter
    }

    /// Use Watchtower on iPhone: a signed build, the hub on and running, and
    /// iCloud available.
    var canShowCode: Bool {
        entitlementPresent && isOn && account == .available && hub?.status == .running && hub?.linkCenter != nil
    }

    nonisolated static func statusLine(_ status: HubStatus) -> String {
        switch status {
        case .off: return "Off"
        case .starting: return "Starting…"
        case .running: return "On"
        case .unavailable(let reason): return "Unavailable: \(reason)"
        }
    }

    nonisolated static func scopeLabel(_ scope: DeviceScope) -> String {
        switch scope {
        case .private: return "Same Apple ID"
        case .shared: return "Shared"
        default: return scope.rawValue
        }
    }

    // MARK: - Lifecycle

    /// The view's `.task`, keyed on its window being on screen: while it
    /// is, refreshes now and then every `nextRefresh` until the task is
    /// cancelled, so the polling ends when the tab goes away or its window
    /// closes or hides, even where SwiftUI sends no `onDisappear`. A hidden
    /// or closed window also closes an open QR and its link, as leaving the
    /// tab does, instead of leaving the link open until it expires.
    func windowVisibility(_ visible: Bool) async {
        guard visible else {
            await linkSheetDismissed()
            return
        }
        while !Task.isCancelled {
            await refresh()
            guard !Task.isCancelled else { return }
            await sleep(Self.nextRefresh(isOn: isOn, status: hub?.status, lastPublishAt: lastPublishAt))
        }
    }

    /// The tab left the screen: an open QR closes.
    func disappeared() async {
        await linkSheetDismissed()
    }

    /// Reads the polled parts of the hub and the iCloud account.
    func refresh() async {
        isOn = host.isMobileSyncEnabled
        guard isOn, let hub else {
            account = nil
            lastPublishAt = nil
            relayBacklog = 0
            throttledSince = nil
            checkedAt = now()
            return
        }
        lastPublishAt = hub.lastPublishAt
        relayBacklog = hub.relayBacklog
        throttledSince = await hub.throttledSince()
        if let center = hub.linkCenter {
            account = await center.accountAvailability()
        } else {
            account = nil
        }
        checkedAt = now()
    }

    // MARK: - The toggle

    /// The opt-in toggle; turning on needs a signed build. Turning off
    /// closes an open QR sheet and its link first.
    func setEnabled(_ enabled: Bool) async {
        guard !enabled || entitlementPresent else { return }
        if !enabled { await linkSheetDismissed() }
        host.setMobileSyncEnabled(enabled)
        isOn = enabled
        await refresh()
    }

    // MARK: - The QR sheet

    func showCode() {
        guard canShowCode, linkSheet == nil, let center = hub?.linkCenter else { return }
        linkSheet = MobileLinkSheetViewModel(center: center, now: now, sleep: sleep)
    }

    /// The sheet closed (Done, Esc, or the tab went away): the link closes.
    func linkSheetDismissed() async {
        guard let sheet = linkSheet else { return }
        linkSheet = nil
        await sheet.close()
    }

    // MARK: - The phone list

    func requestAllow(_ device: HubSyncState.LinkedDevice) {
        pendingAllow = device
    }

    func confirmAllow() {
        guard let device = pendingAllow else { return }
        pendingAllow = nil
        setTyping(true, device)
    }

    func revoke(_ device: HubSyncState.LinkedDevice) {
        setTyping(false, device)
    }

    private func setTyping(_ allowed: Bool, _ device: HubSyncState.LinkedDevice) {
        guard let center = hub?.linkCenter else { return }
        do {
            try center.setTypingAllowed(allowed, deviceID: device.deviceID)
            notice = nil
        } catch {
            notice = "Couldn't change typing for \(device.name): \(error.localizedDescription)"
        }
    }

    func requestStartSessionsAllow(_ device: HubSyncState.LinkedDevice) {
        pendingStartSessionsAllow = device
    }

    func confirmStartSessionsAllow() {
        guard let device = pendingStartSessionsAllow else { return }
        pendingStartSessionsAllow = nil
        setStartSessions(true, device)
    }

    func revokeStartSessions(_ device: HubSyncState.LinkedDevice) {
        setStartSessions(false, device)
    }

    private func setStartSessions(_ allowed: Bool, _ device: HubSyncState.LinkedDevice) {
        guard let center = hub?.linkCenter else { return }
        do {
            try center.setStartSessionsGranted(allowed, deviceID: device.deviceID)
            notice = nil
        } catch {
            notice = "Couldn't change starting sessions for \(device.name): \(error.localizedDescription)"
        }
    }

    func requestPermissionsAllow(_ device: HubSyncState.LinkedDevice) {
        pendingPermissionsAllow = device
    }

    func confirmPermissionsAllow() {
        guard let device = pendingPermissionsAllow else { return }
        pendingPermissionsAllow = nil
        setPermissions(true, device)
    }

    func revokePermissions(_ device: HubSyncState.LinkedDevice) {
        setPermissions(false, device)
    }

    private func setPermissions(_ allowed: Bool, _ device: HubSyncState.LinkedDevice) {
        guard let center = hub?.linkCenter else { return }
        do {
            try center.setPermissionsAllowed(allowed, deviceID: device.deviceID)
            notice = nil
        } catch {
            notice = "Couldn't change permission prompts for \(device.name): \(error.localizedDescription)"
        }
    }

    func requestRemove(_ device: HubSyncState.LinkedDevice) {
        removeSubject = device
        pendingRemove = device
    }

    /// The confirmed Remove: for a shared phone it is at once and cannot be
    /// undone, so nothing is removed without it.
    func confirmRemove() async {
        guard let device = pendingRemove else { return }
        pendingRemove = nil
        await remove(device)
    }

    /// Remove (spec §2.3). The epoch rotates with it (D9): a same-Apple-ID
    /// phone still reaches the private database but no longer has the keys
    /// to read anything new, and the notice says so.
    func remove(_ device: HubSyncState.LinkedDevice) async {
        guard let center = hub?.linkCenter else { return }
        do {
            try await center.remove(deviceID: device.deviceID)
            notice = device.scope == .private ? Self.removedSameAppleID(device.name) : "Removed \(device.name)."
        } catch {
            let why = error.localizedDescription
            if center.devices.contains(where: { $0.deviceID == device.deviceID }) {
                notice = "Couldn't remove \(device.name): \(why)"
            } else {
                // The row is gone (the gate refuses the phone); the share
                // participant is swept by the next close.
                notice = "Removed \(device.name). iCloud sharing is cleaned up at the next code (\(why))."
            }
        }
    }
}
