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

/// The app side of the link flow (`AppRoot`): the sync stack per database,
/// the replica's view of this phone's grant, and the one place the link
/// lands.
@MainActor
protocol LinkHost: AnyObject {
    /// The transport of `scope`'s database for `hubID`'s zones; what is
    /// saved through it is sealed with the phone's keys for that hub. Another
    /// scope or hub, or `fresh` (a new pairing: the replica must not keep
    /// the old link's rollback marks, outbox or sealed recordings), restarts
    /// the sync stack with an empty replica.
    func prepare(scope: CloudDatabaseScope, hubID: String, fresh: Bool) async throws -> any CloudSyncTransport
    /// One fetch, then this phone's keybox (`device_grant-<device_id>`, the
    /// epoch keys included) as the replica holds it.
    func fetchKeybox(deviceID: String) async -> Keybox?
    /// The keybox as the replica holds it, without a fetch (after one).
    func storedKeybox(deviceID: String) async -> Keybox?
    /// `AppEnvironment.setLinkedDevice`: nil unlinks; `writesAllowed: false`
    /// keeps the link but sends nothing (the hub moved).
    func setLink(_ device: LinkedDevice?, writesAllowed: Bool) async
    /// This phone's `device` record with the current Settings choices.
    func devicePayload(for device: LinkedDevice, linkNonce: String?, unlinked: Bool, now: Date) -> DevicePayload
    /// Asks the transport to send what is queued now (before a stop).
    func flushSends() async
    /// The running environment's link has ended and it syncs nothing more
    /// (a `shared` link whose shares were left): it stays until the next
    /// launch, and the next `prepare` restarts even on its database and hub.
    func retireEnvironment()
    /// Stops sync, wipes the replica, the outbox and the transport's store
    /// (buffer, send queue, engine state), and restarts unlinked on
    /// `hubID`'s zones in `scope`'s database. A running capture is stopped
    /// and saved first, and recordings still on their way to the Mac are
    /// held for their hub (`keepRecordings`; false on an iCloud account
    /// change, when they are lost and counted). Returns what the wipe lost.
    func wipeLocalData(restartingOn scope: CloudDatabaseScope, hubID: String, keepRecordings: Bool) async -> LocalWipe
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
