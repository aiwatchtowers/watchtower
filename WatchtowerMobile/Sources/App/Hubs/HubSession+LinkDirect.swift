import Foundation
import WatchtowerSync

/// The link flow's direct CloudKit calls (#2189): its keybox read by name and its hello saved at once, so neither
/// waits behind the full download of the Mac's zones a fresh replica starts with. Both go through
/// `CloudKitTransport`'s direct calls, which honour its throttle and its unlink and count each request that goes out.
extension HubSession {
    /// Where this phone's keybox lives on the server: `keybox-<DEVICE_ID>` (the uppercase UUID, as the hub writes it
    /// and `SecureTransport.openKeybox` binds it) in the data zone.
    static func keyboxLocation(deviceID: UUID) -> (recordName: String, zone: CloudZoneID) {
        (Keybox.recordName(deviceID: deviceID.uuidString), .data)
    }

    /// This phone's keybox as the server holds it now: one read of its record by name (`keyboxLocation`,
    /// `CloudKitTransport.serverRecord`), opened as the replica opens it, with nothing stored. The link flow's
    /// baseline and its grant polls take it; a link still completes from the replica. Off CloudKit: `.unavailable`.
    func serverKeybox(deviceID: UUID) async -> KeyboxRead {
        guard let direct = directCloud else { return .unavailable(reason: "no direct read on this route") }
        let location = Self.keyboxLocation(deviceID: deviceID)
        return await Self.keyboxRead {
            try await direct.cloud.serverRecord(named: location.recordName, in: location.zone)?.payload
        } open: { sealed in
            try await direct.secure.openKeybox(sealed: sealed, deviceID: deviceID)
        }
    }

    /// This phone's keybox as the replica holds it, without a fetch: as `serverKeybox` reads the server's.
    func replicaKeybox(deviceID: UUID) async -> KeyboxRead {
        let store = store
        return await Self.keyboxRead {
            try store.reader.read { db in try store.keyboxEnvelope(deviceID: deviceID, from: db) }
        } open: { _ in
            try self.keybox(deviceID: deviceID)
        }
    }

    /// A keybox read's outcome as the link flow takes it (#2189), three ways apart:
    /// - absent (`fetch` returned nil): `.read(nil)`;
    /// - present and opened: `.read(keybox)`;
    /// - present but not opening (`EnvelopeError`: sealed to a key this phone no longer has, signed by a reset hub's
    ///   old key, a newer format): `.opaque` with a fingerprint of the sealed bytes, never the grant, so a re-pair over
    ///   an old keybox still has a baseline;
    /// - a failed request or any other throw (a throttle, the unlink, a record that does not map, locked keys, a
    ///   cancellation): `.unavailable`. Logged at debug (the link flow logs a wait's first one); a cancellation not.
    static func keyboxRead(
        fetch: () async throws -> Data?, open: (Data) async throws -> Keybox?
    ) async -> KeyboxRead {
        do {
            guard let sealed = try await fetch() else { return .read(nil) }
            do {
                return .read(try await open(sealed))
            } catch is EnvelopeError {
                return .opaque(fingerprint: KeyboxRead.fingerprint(sealed))
            }
        } catch is CancellationError {
            return .unavailable(reason: "cancelled")
        } catch {
            let reason = String(describing: error)
            logger.debug("keybox read unavailable: \(reason, privacy: .public)")
            return .unavailable(reason: reason)
        }
    }

    /// One fetch for the link flow's replica read (`LinkHost.fetchKeybox`, `LinkHost.completionKeybox`): true only
    /// when it brought the data zone in (and, with `mailbox`, the relay zone too: the R4 `hub_on_relay` check of a
    /// completing link reads the mailbox). On CloudKit a pull skipped by a throttle or the unlink, or cut short,
    /// returns normally and `refresh` counts it as no data, and a later zone's `zoneNotFound` unlinks the transport
    /// and returns normally too; so the zones' completed polls are compared around it, and the transport must not be
    /// unlinked after it (`linkFetchCompleted`). A fetch that joined a pull already past a zone (the launch's) moves no
    /// count although nothing went wrong: when the transport is neither throttled nor unlinked, one more fetch (a new
    /// pull) is judged instead (`linkFetchNeedsSecondPull`).
    func refreshForLink(mailbox: Bool) async -> Bool {
        guard let cloud = directCloud?.cloud else { return await refresh(.link) }
        var outcome = await linkFetch(cloud, mailbox: mailbox)
        if Self.linkFetchNeedsSecondPull(
            refreshed: outcome.refreshed, moved: outcome.moved, unlinked: outcome.unlinked, throttled: await cloud.isThrottled
        ) {
            outcome = await linkFetch(cloud, mailbox: mailbox)
        }
        return Self.linkFetchCompleted(refreshed: outcome.refreshed, moved: outcome.moved, unlinked: outcome.unlinked)
    }

    /// One `refresh(.link)` with the zones' completed polls around it and the unlink after it.
    private func linkFetch(_ cloud: CloudKitTransport, mailbox: Bool) async -> (refreshed: Bool, moved: Bool, unlinked: Bool) {
        let before = LinkFetchCounts(data: await cloud.dataZonePollsCompleted, relay: await cloud.relayZonePollsCompleted)
        let refreshed = await refresh(.link)
        let after = LinkFetchCounts(data: await cloud.dataZonePollsCompleted, relay: await cloud.relayZonePollsCompleted)
        return (refreshed, Self.linkFetchMoved(before: before, after: after, mailbox: mailbox), await cloud.isUnlinked)
    }

    /// The zones' completed polls (`CloudKitTransport.dataZonePollsCompleted`, `relayZonePollsCompleted`).
    struct LinkFetchCounts: Equatable {
        var data: Int
        var relay: Int
    }

    /// The fetch polled the data zone to its end, and with `mailbox` the relay zone too.
    static func linkFetchMoved(before: LinkFetchCounts, after: LinkFetchCounts, mailbox: Bool) -> Bool {
        after.data > before.data && (!mailbox || after.relay > before.relay)
    }

    /// A fetch that succeeded but did not move the zones it needed, on a transport neither throttled nor unlinked: it
    /// joined a pull already past them, so one more fetch is worth judging.
    static func linkFetchNeedsSecondPull(refreshed: Bool, moved: Bool, unlinked: Bool, throttled: Bool) -> Bool {
        refreshed && !moved && !unlinked && !throttled
    }

    /// A CloudKit fetch that succeeded, left the transport linked and polled the zones it needed.
    static func linkFetchCompleted(refreshed: Bool, moved: Bool, unlinked: Bool) -> Bool {
        refreshed && !unlinked && moved
    }

    /// Saves `record` sealed with this session's keys straight to CloudKit (`CloudKitTransport.saveDirectly`, outside
    /// the engine's queue): the link flow's hello, which must not wait behind a fresh replica's launch fetch. false off
    /// CloudKit, or when the seal or the save failed (logged; a cancellation at debug).
    func sendDirectly(_ record: CloudRecord) async -> Bool {
        guard let direct = directCloud else { return false }
        do {
            try await direct.cloud.saveDirectly(try await direct.secure.seal(record))
            return true
        } catch is CancellationError {
            Self.logger.debug("direct save cancelled")
            return false
        } catch {
            Self.logger.error("direct save failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }
}
