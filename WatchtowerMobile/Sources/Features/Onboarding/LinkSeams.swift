import Foundation
import WatchtowerSync

/// The phone's iCloud identity and the zone shares the link flow accepts
/// (spec §2.3 steps 2–3). `CloudKitLinkContainer` is the live one.
protocol LinkContainer: Sendable {
    func accountStatus() async -> CloudAvailability
    /// `CKContainer.userRecordID().recordName`.
    func userRecordName() async throws -> String
    /// Fetches every URL's share metadata, then accepts them all; throws if
    /// any metadata fetch or accept fails, or if the shares are not exactly
    /// `hubID`'s two zone-wide shares owned by `ownerName` (nothing accepted).
    func acceptShares(_ urls: [URL], ownerName: String, hubID: String) async throws
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
    /// The hub ids of the registry rows that cannot be read, in order
    /// (`HubRegistry.unreadableHubIDs`): listed for Forget only (#222).
    func unreadableHubIDs() -> [String]
    /// Settings → Macs: `hubID` moves to `index` in the registry's order.
    func moveHub(_ hubID: String, to index: Int)
    /// `hubID`'s transport in `scope`'s database, sealing with the phone's
    /// keys for that hub: its session if one runs in that scope; else a new
    /// session in its own directory (a row in another scope, or frozen, is
    /// removed first with its recordings held). `fresh` (a new pairing:
    /// the replica must not keep an old link's rollback marks, outbox or
    /// sealed recordings) removes a running session of the hub first too.
    /// A new session's seqs start above the ceiling a removal of the same
    /// hub left in this process (F29).
    func prepare(scope: CloudDatabaseScope, hubID: String, fresh: Bool) async throws -> any CloudSyncTransport
    /// One fetch of `hubID`'s session, then this phone's keybox there
    /// (`device_grant-<device_id>`, the epoch keys included).
    func fetchKeybox(hubID: String, deviceID: String) async -> Keybox?
    /// `hubID`'s keybox as its replica holds it, without a fetch.
    func storedKeybox(hubID: String, deviceID: String) async -> Keybox?
    /// Epoch keys of `hubID` joined the Keychain: the rows its replica
    /// stored but could not open yet are opened now.
    func keysMerged(hubID: String)
    /// The link completed: adds or updates the row, sets the device on the
    /// session (writes on) and activates it. Throws `HubRegistryError.full`
    /// for a new hub when every slot is taken.
    func linked(_ record: LinkRecord, device: LinkedDevice) async throws
    /// This phone's `device` record for `hubID` with that hub's Settings
    /// choices.
    func devicePayload(hubID: String, for device: LinkedDevice, linkNonce: String?, unlinked: Bool, now: Date) -> DevicePayload
    /// Removes `hubID`: deletes its row, then sends `farewell` (the
    /// `unlinked` device record of an unlink; nil sends nothing) through
    /// the hub's own transport (sealed) and waits, bounded, for it to leave
    /// the send queue (still queued at the cap, it is kept for
    /// `resendFarewell`: `LocalWipe.farewellKept`); then stops its session (a running capture stopped
    /// and saved), hands its recordings to the hold (`keepRecordings`;
    /// false on an iCloud account change, when they are lost and counted)
    /// and deletes its files; the next hub in order becomes active. Returns
    /// what was lost. Also drops a session that never got a row (a failed
    /// link). The hub's keys stay: the link flow removes them.
    func removeHub(_ hubID: String, keepRecordings: Bool, farewell: CloudRecord?) async -> LocalWipe
    /// The unlink farewells a removal kept because they had not gone out
    /// (#143), sealed.
    func pendingFarewells() -> [PendingFarewell]
    /// Sends a kept farewell again; true once it went out, and then it is
    /// no longer kept. A scan of the same hub waits for it.
    func resendFarewell(_ farewell: PendingFarewell) async -> Bool
    /// Stops keeping `hubID`'s farewell unsent.
    func dropFarewell(_ hubID: String)
    /// The Mac removed this phone: the row turns `unlinked_by_mac` and the
    /// session freezes (no sync, no writes, data readable with the hub's
    /// keys, which stay until Forget).
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
    /// The unlink's farewell had not left the send queue: it is kept and
    /// sent again later (`LinkHost.resendFarewell`), so a `shared` link
    /// keeps its shares until then.
    var farewellKept = false
}
