import Foundation
import WatchtowerSync

/// The phone's iCloud identity and the zone shares the link flow accepts
/// (spec §2.3 steps 2–3). `CloudKitLinkContainer` is the live one.
protocol LinkContainer: Sendable {
    func accountStatus() async -> CloudAvailability
    /// `CKContainer.userRecordID().recordName`.
    func userRecordName() async throws -> String
    /// Fetches every URL's share metadata, then accepts them all; throws if
    /// any metadata fetch or accept fails.
    func acceptShares(_ urls: [URL]) async throws
    /// Leaves the Mac's shares: deletes the accepted zone-wide share records
    /// of `hubID`'s two zones from this phone's shared database.
    func leaveShares(ownerName: String, hubID: String) async throws
}

/// The link flow's clock: the grant wait and the expiry check run on it.
protocol LinkClock: Sendable {
    func now() -> Date
    /// Seconds on a monotonic source that a wall-clock jump cannot move.
    func uptime() -> TimeInterval
    func sleep(for duration: Duration) async throws
}

extension LinkClock {
    func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
}

struct SystemLinkClock: LinkClock {
    func now() -> Date { Date() }

    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

/// The app side of the link flow (`AppRoot`), addressed by hub: the saved
/// links (the hub registry), one session per hub, and where a link lands
/// or ends (multi-hub spec §5.7, §6).
@MainActor
protocol LinkHost: AnyObject {
    /// The saved links, in registry order (rows of both states).
    func linkedHubs() -> [HubRow]
    /// `hubID`'s transport in `scope`'s database: its session if one runs in
    /// that scope; else a new session in its own directory (a row in another
    /// scope, or frozen, is removed first with its recordings held).
    func prepare(scope: CloudDatabaseScope, hubID: String) async throws -> any CloudSyncTransport
    /// One fetch of `hubID`'s session, then this phone's grant there.
    func fetchGrant(hubID: String, deviceID: String) async -> DeviceGrant?
    /// The link completed: adds or updates the row, sets the device on the
    /// session (writes on) and activates it. Throws `HubRegistryError.full`
    /// for a new hub when every slot is taken.
    func linked(_ record: LinkRecord, device: LinkedDevice) async throws
    /// This phone's `device` record for `hubID` with that hub's Settings
    /// choices.
    func devicePayload(hubID: String, for device: LinkedDevice, linkNonce: String?, unlinked: Bool, now: Date) -> DevicePayload
    /// Writes `record` through a fresh transport on `hubID`'s zones after the
    /// session's files are gone (only the farewell is sent), sends it, stops.
    func sendFarewell(_ record: CloudRecord, scope: CloudDatabaseScope, hubID: String) async
    /// Removes `hubID`: stops its session (a running capture stopped and
    /// saved), hands its recordings to the hold (`keepRecordings`; false on
    /// an iCloud account change, when they are lost and counted), deletes
    /// its files and its row; the next hub in order becomes active. Returns
    /// what was lost. Also drops a session that never got a row (a failed
    /// link).
    func removeHub(_ hubID: String, keepRecordings: Bool) async -> LocalWipe
    /// The Mac removed this phone: the row turns `unlinked_by_mac` and the
    /// session freezes (no sync, no writes, data readable).
    func markRemovedByMac(_ hubID: String) async
    /// The removal check's first look at `hubID` (#64), kept on its row.
    func setGrantMissingSince(_ date: Date?, hubID: String)
    func requestNotificationPermission() async
    /// Selects the Now tab.
    func openNow()
}

/// What a wipe reports to the link flow.
struct LocalWipe: Equatable {
    /// Outbox items, and recordings whose audio is gone, that were still
    /// waiting for the Mac (reported "Not sent").
    var notSent = 0
    /// A capture was running: it was stopped, saved and held, and goes to
    /// its Mac after the next link to it.
    var stoppedRecording = false
    /// Why some recordings could not be handed over or restored (their
    /// audio is kept on the phone, unsent, or retried at the next boot).
    var problem: String?
}
