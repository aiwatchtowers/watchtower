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
            guard let record = try await direct.cloud.serverRecord(named: location.recordName, in: location.zone) else {
                return nil
            }
            return try await direct.secure.openKeybox(sealed: record.payload, deviceID: deviceID)
        }
    }

    /// A keybox read's outcome as the link flow takes it: the copy, or nil only when the source holds none. Any throw
    /// is `.unavailable` (a record that does not map or open, locked keys, a throttle, a CloudKit failure, a
    /// cancellation), never an absence. Logged at debug (the link flow logs a wait's first one); a cancellation not.
    static func keyboxRead(_ read: () async throws -> Keybox?) async -> KeyboxRead {
        do {
            return .read(try await read())
        } catch is CancellationError {
            return .unavailable(reason: "cancelled")
        } catch {
            let reason = String(describing: error)
            logger.debug("keybox read unavailable: \(reason, privacy: .public)")
            return .unavailable(reason: reason)
        }
    }

    /// One fetch for the link flow's replica read (`LinkHost.fetchKeybox`): true only when it brought the data zone in.
    /// On CloudKit a pull skipped by a throttle or the unlink, or cut short, returns normally and `refresh` counts it
    /// as no data, and a later zone's `zoneNotFound` unlinks the transport and returns normally too; so the data
    /// zone's completed polls are compared around it, and the transport must not be unlinked after it
    /// (`linkFetchCompleted`). A fetch that joined a pull already past the data zone (the launch's) moves no count
    /// although nothing went wrong: when the transport is neither throttled nor unlinked, one more fetch (a new pull)
    /// is judged instead (`linkFetchNeedsSecondPull`).
    func refreshForLink() async -> Bool {
        guard let cloud = directCloud?.cloud else { return await refresh(.link) }
        var outcome = await linkFetch(cloud)
        if Self.linkFetchNeedsSecondPull(
            refreshed: outcome.refreshed, pollsBefore: outcome.before, pollsAfter: outcome.after,
            unlinked: outcome.unlinked, throttled: await cloud.isThrottled
        ) {
            outcome = await linkFetch(cloud)
        }
        return Self.linkFetchCompleted(
            refreshed: outcome.refreshed, pollsBefore: outcome.before, pollsAfter: outcome.after, unlinked: outcome.unlinked)
    }

    /// One `refresh(.link)` with the data zone's completed polls around it and the unlink after it.
    private func linkFetch(_ cloud: CloudKitTransport) async -> (refreshed: Bool, before: Int, after: Int, unlinked: Bool) {
        let before = await cloud.dataZonePollsCompleted
        let refreshed = await refresh(.link)
        return (refreshed, before, await cloud.dataZonePollsCompleted, await cloud.isUnlinked)
    }

    /// A fetch that succeeded but moved no data-zone poll, on a transport neither throttled nor unlinked: it joined a
    /// pull already past the data zone, so one more fetch is worth judging.
    static func linkFetchNeedsSecondPull(
        refreshed: Bool, pollsBefore: Int, pollsAfter: Int, unlinked: Bool, throttled: Bool
    ) -> Bool {
        refreshed && pollsAfter == pollsBefore && !unlinked && !throttled
    }

    /// A fetch that succeeded, left the transport linked and, on CloudKit (the poll counts given), polled the data zone
    /// to its end during it.
    static func linkFetchCompleted(refreshed: Bool, pollsBefore: Int?, pollsAfter: Int?, unlinked: Bool) -> Bool {
        guard refreshed, !unlinked else { return false }
        guard let pollsBefore, let pollsAfter else { return true }
        return pollsAfter > pollsBefore
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
