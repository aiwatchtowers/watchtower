import CryptoKit
import Foundation
import WatchtowerHostedRelay
import WatchtowerSync

/// The phone's account identity and the access a hub's route needs before
/// it can be read (spec §2.3 steps 2–3). `CloudKitLinkAccess` is the live one.
protocol LinkAccess: Sendable {
    func availability() async -> CloudAvailability
    /// `CKContainer.userRecordID().recordName`.
    func identity() async throws -> String
    /// CloudKit shared route: fetches both share URLs' metadata, then accepts
    /// them; throws if any fetch or accept fails, or if the shares are not
    /// exactly `hubID`'s two zone-wide shares owned by the route's owner
    /// (nothing accepted). Private route: nothing. Hosted relay:
    /// `UnsupportedRouteError`.
    func join(_ invitation: LinkInvitation, route: HubRoute, hubID: String) async throws
    /// CloudKit shared route: deletes the accepted zone-wide share records of
    /// `hubID`'s two zones from this phone's shared database. Private route:
    /// nothing. Hosted relay: `UnsupportedRouteError`.
    func leave(route: HubRoute, hubID: String) async throws
}

/// The phone's account ops of linking over the relay (`HostedRelayPairing` on the process's one relay session;
/// relay client Phase 3 Task 10). The live one is `HostedRelayLinkOps`; while the relay is off it is
/// `OffRelayLinkOps`, which builds nothing and is never asked (the route rule checks `availability` first).
protocol RelayLinkOps: Sendable {
    var availability: RelayAvailability { get }
    /// This phone's relay device id (the session client's): the hello's `relay_device_id`.
    func phoneDeviceID() throws -> String
    /// `get_account_state`: paying, and the Macs in this account's slots.
    func accountState() async throws -> (paying: Bool, macs: [String])
    /// `open_pairing` after the slot pre-check; `HostedRelayPairing.Refusal` for the answers a screen acts on.
    func open(mac: String) async throws -> (slot: String, expiresAt: Date)
    /// `vouch_hub`; `HostedRelayPairing.VouchRefusal` for the answers a screen acts on.
    func vouch(hubDeviceID: String, authPub: Data) async throws
    /// `promote_pairing`; `HostedRelayPairing.Refusal`, or the client's error (`HUB_NOT_VOUCHED`, `NOT_FOUND`).
    func promote(slot: String) async throws
    /// `close_pairing`, best effort.
    func close(slot: String) async
    /// `remove_slot` (`NOT_FOUND` counts as done).
    func removeSlot(mac: String) async throws
    /// `add_slot` (an iCloud link upgraded to the relay, Phase 3b Task 19); `HostedRelayPairing.Refusal`, or the
    /// client's error (`HUB_NOT_VOUCHED`, `NOT_FOUND`).
    func addSlot(mac: String) async throws
    /// The three relay fields of this phone's `device` record for `hubID` (`RelayIDProof`, R22): its relay id, its
    /// `relay_auth` key and that key's signature, by the phone's relay identity.
    func relayIDProof(hubID: UUID, deviceID: UUID) throws -> RelayIDClaim
    /// Whether this device holds a current Relay entitlement (StoreKit), read without an App Store sync: the route
    /// rule's tie-breaker when the paying check gets no answer on an iCloud Mac's code.
    func holdsRelayEntitlement() async -> Bool
}

/// A phone's claim of its relay id in its `device` record (`RelayIDProof.sign`).
struct RelayIDClaim: Equatable, Sendable {
    let relayDeviceID: String
    let authPub: String
    let sig: String

    /// The three fields as `DeviceHello(device:signingKey:agreementKey:relayIDProof:)` takes them.
    var proof: (relayDeviceID: String, authPub: String, sig: String) { (relayDeviceID, authPub, sig) }
}

extension RelayLinkOps {
    /// `relayIDProof` for the hub a link record names: the claim a slot hello carries (#2387), so the Mac marks the
    /// link as one over Relay. A hub id that is not a UUID throws.
    func relayIDProof(hubID: String, deviceID: UUID) throws -> RelayIDClaim {
        try relayIDProof(hubID: try WireBytes.hubUUID(hubID), deviceID: deviceID)
    }
}

/// The relay while it is off: never asked, since nothing routes to it.
struct OffRelayLinkOps: RelayLinkOps {
    var availability: RelayAvailability = .off(.notConfigured)

    func phoneDeviceID() throws -> String { throw HostedRelayPairing.Refusal.unreachable }
    func accountState() async throws -> (paying: Bool, macs: [String]) { throw HostedRelayPairing.Refusal.unreachable }
    func open(mac: String) async throws -> (slot: String, expiresAt: Date) { throw HostedRelayPairing.Refusal.unreachable }
    func vouch(hubDeviceID: String, authPub: Data) async throws { throw HostedRelayPairing.VouchRefusal.unreachable }
    func promote(slot: String) async throws { throw HostedRelayPairing.Refusal.unreachable }
    func close(slot: String) async {}
    func removeSlot(mac: String) async throws { throw HostedRelayPairing.Refusal.unreachable }
    func addSlot(mac: String) async throws { throw HostedRelayPairing.Refusal.unreachable }
    func relayIDProof(hubID: UUID, deviceID: UUID) throws -> RelayIDClaim { throw HostedRelayPairing.Refusal.unreachable }
    func holdsRelayEntitlement() async -> Bool { false }
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
    /// The hub on screen; nil when none is.
    var activeHubID: String? { get }
    /// The hub ids of the registry rows that cannot be read, in order
    /// (`HubRegistry.unreadableHubIDs`): listed for Forget only (#222).
    func unreadableHubIDs() -> [String]
    /// Settings → Macs: `hubID` moves to `index` in the registry's order.
    func moveHub(_ hubID: String, to index: Int)
    /// `hubID`'s transport on `route`, sealing with the phone's
    /// keys for that hub: its session if one runs on that route; else a new
    /// session in its own directory (a row on another route, or frozen, is
    /// removed first with its recordings held). `fresh` (a new pairing:
    /// the replica must not keep an old link's rollback marks, outbox or
    /// sealed recordings) removes a running session of the hub first too.
    /// A new session's seqs start above the ceiling a removal of the same
    /// hub left in this process (F29).
    func prepare(route: HubRoute, hubID: String, fresh: Bool) async throws -> any CloudSyncTransport
    /// A Relay link's pairing transport (relay client Phase 3 Task 10): a new session for `hubID` on the relay
    /// store of the Mac `macDeviceID`, whose transport reads and writes the pairing slot's zone (`pair/<slot>`),
    /// sealing with the phone's keys for that hub. A running session of the hub is removed first, as a fresh
    /// `prepare`. After `promote_pairing`, `prepare(route: .hostedRelay(mac), fresh: false)` moves the hub to its
    /// data zone and mailbox on the same store.
    func preparePairing(macDeviceID: String, slot: String, hubID: String) async throws -> any CloudSyncTransport
    /// One fetch of `hubID`'s session, then this phone's keybox in its replica
    /// (`device_grant-<device_id>`, the epoch keys included). `.unavailable` when no session runs, the fetch failed
    /// (`HubSession.refresh` false) or the replica's copy did not open: never a guessed absence.
    func fetchKeybox(hubID: String, deviceID: String) async -> KeyboxRead
    /// `fetchKeybox`, and whether its fetch also read the relay zone (the mailbox): a link completes only from a read
    /// that did, so the R4 `hub_on_relay` check sees a waiting control (#2189); a waiting keybox or a refusal needs
    /// the data zone only.
    func completionKeybox(hubID: String, deviceID: String) async -> (read: KeyboxRead, mailboxCovered: Bool)
    /// `hubID`'s keybox as its replica holds it, without a fetch.
    func storedKeybox(hubID: String, deviceID: String) async -> Keybox?
    /// `hubID`'s keybox as the server holds it now (#2189): one read of `keybox-<DEVICE_ID>` by its fixed name,
    /// outside the replica and its zone fetch (`HubSession.serverKeybox`). `.unavailable` for a hub without a
    /// session, off CloudKit (the relay, the demo), throttled, or when the read failed or the record did not map
    /// or open.
    func serverKeybox(hubID: String, deviceID: String) async -> KeyboxRead
    /// Saves `record` (plain; sealed here with `hubID`'s session) at once, outside the engine's queue (#2189: the
    /// hello must not wait behind a fresh replica's full download). false, logged, when the hub's session is not on
    /// CloudKit or the save failed: the caller queues it on the session's transport instead.
    func sendDirectly(_ record: CloudRecord, hubID: String) async -> Bool
    /// Merges a keybox's `keys` into `hubID`'s stored link through its session (`HubSession.mergeKeybox`: one
    /// `updateHubLink`, and on a link that reseals across epochs the outbox's merge, which keeps this phone's own rows
    /// readable). nil when no link is stored or no session runs: nothing written. Throws as the merge does (a locked
    /// keychain, a refused keybox), with nothing written. `now` stamps the epoch it supersedes. `reseal`: a fetched
    /// keybox moves every own row below the newest, a switch's only the rows of an epoch it drops (sim rule 13).
    func mergeKeybox(_ keys: KeyboxKeys, hubID: String, now: Date, reseal: KeyboxMergeReseal) async throws -> KeyboxMerge?
    /// Epoch keys of `hubID` joined the Keychain: the rows its replica
    /// stored but could not open yet are opened now, and a parked relay feed reads again. `newestEpochRaised`:
    /// the newest epoch went up, so an ordered hub gets `epoch_ack`. `droppedNewestPair`: the hub cleared this
    /// phone's relay keys, so the offer goes out again.
    func keysMerged(hubID: String, newestEpochRaised: Bool, droppedNewestPair: Bool) async
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
    /// Keeps `farewell` for a later resend (#143); false when it could not be kept (logged).
    func keepFarewell(_ farewell: PendingFarewell) -> Bool
    /// `record` sealed with the phone's keys for `hubID` (its session's, or a stopped session built on its files
    /// for the seal alone); nil when it cannot be sealed (logged). Nothing is sent.
    func sealFarewell(hubID: String, route: HubRoute, record: CloudRecord) async -> CloudRecord?
    /// The relay Macs whose slot removal is kept for a retry.
    func pendingSlotRemovals() -> [String]
    /// Keeps the slot removal of the relay Mac `macDeviceID` for a retry at launch.
    func keepSlotRemoval(_ macDeviceID: String)
    /// Stops keeping it (done, or a new link to that Mac).
    func forgetSlotRemoval(_ macDeviceID: String)
    /// `hubID`'s session has seen that its hub runs over Relay: the newest transport marker in its data zone says
    /// `relay`, or a `hub_on_relay` control came to its mailbox.
    func hubRunsOnRelay(_ hubID: String) -> Bool
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

/// One read of this phone's keybox (`LinkHost.serverKeybox`, `LinkHost.fetchKeybox`): what the source holds, or
/// that it could not say. An absence is only ever `.read(nil)`.
enum KeyboxRead: Equatable {
    /// The source's copy; nil when it holds none.
    case read(Keybox?)
    /// The source holds a keybox this phone cannot open (sealed to a key it no longer has, signed by a reset hub's old
    /// key): only a fingerprint of its sealed bytes, never a grant. A re-pair's baseline, never an answer.
    case opaque(fingerprint: String)
    /// No such read here, or it failed (`reason` is for the log).
    case unavailable(reason: String)

    /// A keybox envelope's fingerprint: SHA-256 of its sealed bytes, base64url.
    static func fingerprint(_ sealed: Data) -> String {
        WireBytes.base64URL(Data(SHA256.hash(data: sealed)))
    }
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
    /// The unlink's farewell left the send queue: the hub can read it now.
    var farewellOut = false
}
