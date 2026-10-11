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
/// the linked phones (Allow… / Revoke typing, Remove).
///
/// The hub and its link center are the app's (`AppState.mobileHub`); this
/// model reads them and refreshes the polled parts (iCloud account, last
/// publish, backlog, throttling) every `refreshInterval` while the tab is
/// on screen.
@MainActor
@Observable
final class MobileSettingsViewModel {
    nonisolated static let corpNotice = "Work data from this Mac will be stored in your personal iCloud account."
    nonisolated static let needsSignedBuild = "Needs a signed build"
    nonisolated static let slowingLine = "iCloud is slowing sync down"
    nonisolated static let removedSameAppleID =
        "Removed. It is signed into your Apple ID, so it can still read synced data until you sign it out of iCloud"
    /// Throttling this long shows `slowingLine` (spec §9).
    nonisolated static let slowingAfter: TimeInterval = 60
    nonisolated static let refreshInterval: Duration = .seconds(5)

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
    /// The QR sheet while it is up.
    private(set) var linkSheet: MobileLinkSheetViewModel?

    @ObservationIgnored private let host: any MobileSettingsHost
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let sleep: @Sendable (Duration) async -> Void
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

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

    /// Take over is offered while another Mac holds the hub.
    var offersTakeOver: Bool {
        switch hub?.status {
        case .otherHub, .tookOver: return isOn
        default: return false
        }
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
        case .otherHub(let macName): return "\(macName) is your hub. Turn it off there, or Take over"
        case .tookOver: return "Another Mac took over"
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

    /// The tab appeared: refresh now and every `refreshInterval`.
    func appeared() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self, sleep] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                await sleep(Self.refreshInterval)
            }
        }
    }

    /// The tab left the screen: the polling stops and an open QR closes.
    func disappeared() async {
        refreshTask?.cancel()
        refreshTask = nil
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

    // MARK: - The toggle and Take over

    /// The opt-in toggle; turning on needs a signed build. Turning off
    /// closes an open QR sheet and its link first.
    func setEnabled(_ enabled: Bool) async {
        guard !enabled || entitlementPresent else { return }
        if !enabled { await linkSheetDismissed() }
        host.setMobileSyncEnabled(enabled)
        isOn = enabled
        await refresh()
    }

    func takeOver() async {
        guard let hub else { return }
        await hub.takeOver()
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

    /// Remove (spec §2.3). A same-Apple-ID phone still reads the private
    /// database, and the notice says so.
    func remove(_ device: HubSyncState.LinkedDevice) async {
        guard let center = hub?.linkCenter else { return }
        do {
            try await center.remove(deviceID: device.deviceID)
            notice = device.scope == .private ? Self.removedSameAppleID : "Removed \(device.name)."
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
