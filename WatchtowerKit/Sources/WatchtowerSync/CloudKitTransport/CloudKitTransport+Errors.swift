import CloudKit
import Foundation
import os

extension CloudKitTransport {
    // MARK: - Error rules (spec §9)

    /// Codes that mean the owner's zone is gone for this participant.
    static let zoneGoneCodes: Set<CKError.Code> = [.zoneNotFound, .userDeletedZone]
    private static let throttleCodes: Set<CKError.Code> = [.requestRateLimited, .zoneBusy]
    static let handledSendCodes: Set<CKError.Code> = zoneGoneCodes.union([.quotaExceeded, .limitExceeded])

    /// The per-item errors of a `.partialFailure`, each with its zone when
    /// the item key names one (a zone ID, or a record ID's zone), or the
    /// error itself with `zoneID`.
    static func flatten(_ error: CKError, zoneID: CKRecordZone.ID?) -> [(zoneID: CKRecordZone.ID?, error: CKError)] {
        guard error.code == .partialFailure, let partial = error.partialErrorsByItemID else { return [(zoneID, error)] }
        let inner: [(zoneID: CKRecordZone.ID?, error: CKError)] = partial.compactMap { key, value in
            guard let itemError = value as? CKError else { return nil }
            let itemZone = (key as? CKRecordZone.ID) ?? (key as? CKRecord.ID)?.zoneID ?? zoneID
            return (itemZone, itemError)
        }
        return inner.isEmpty ? [(zoneID, error)] : inner
    }

    /// Unlinked (phone role) and the quota pause.
    func applySendFailures(_ errors: [CKError]) {
        let codes = Set(errors.map(\.code))
        if !managesZones, !codes.isDisjoint(with: Self.zoneGoneCodes) {
            emitUnlinked(reason: "zone not found on send")
        }
        if codes.contains(.quotaExceeded) {
            pauseForQuota()
        }
    }

    /// `.limitExceeded` on a batch of `size`: halve the next batch and
    /// retry. A record that fails even alone (`rejectable`) is logged,
    /// dropped from the queue, and handed to the rejected-record handler,
    /// so it never retries forever. Applied once per built batch.
    func shrinkBatch(size: Int, rejectable: [(name: String, zone: CloudZoneID)]) throws {
        if let id = lastBuiltBatch?.id {
            guard shrunkBatchID != id else { return }
            shrunkBatchID = id
        }
        guard size <= 1 else {
            batchLimit = max(1, size / 2)
            return
        }
        for (name, zone) in rejectable {
            try store.dropPending(recordName: name, zone: zone)
            logger.error("CloudKit rejected \(name, privacy: .public) even alone (limitExceeded); dropped it from the send queue")
            recordRejectedHandler?(name, zone)
        }
        batchLimit = Self.maxBatchSize
    }

    /// Throttles on `.requestRateLimited` / `.zoneBusy`, once for all of
    /// them. Returns whether it did.
    func applyThrottle(from errors: [CKError]) -> Bool {
        let throttling = errors.filter { Self.throttleCodes.contains($0.code) }
        guard !throttling.isEmpty else { return false }
        throttle(retryAfter: throttling.compactMap(\.retryAfterSeconds).max())
        return true
    }

    /// Waits `retryAfter` (the server's `CKErrorRetryAfterKey`) or the
    /// default backoff — 5 s, doubling to a 120 s cap — then sends again.
    private func throttle(retryAfter: TimeInterval?) {
        let delay: TimeInterval
        if let retryAfter {
            delay = retryAfter
        } else {
            delay = nextBackoff
            nextBackoff = min(nextBackoff * 2, Self.maxBackoff)
        }
        let start = now()
        if throttledSince == nil { throttledSince = start }
        throttledUntil = start.addingTimeInterval(delay)
        logger.notice("CloudKit throttled sync; retrying in \(delay, privacy: .public) s")
        retryTask?.cancel()
        retryTask = Task { [weak self, sleep] in
            await sleep(delay)
            guard !Task.isCancelled else { return }
            await self?.throttleElapsed()
        }
    }

    private func throttleElapsed() async {
        throttledUntil = nil
        guard !isPaused, !isUnlinked else { return }
        let pending: (saves: [CloudRecord], deletes: [(name: String, zone: CloudZoneID)])
        do {
            pending = try store.pendingBatch(limit: 1)
        } catch {
            recordError(error)
            return
        }
        guard !pending.saves.isEmpty || !pending.deletes.isEmpty else {
            // Nothing waits to be sent (a fetch-only throttle): the stretch
            // is over. The backoff stays until a request succeeds.
            throttledSince = nil
            return
        }
        await resend()
    }

    /// A request succeeded: the throttling stretch and its backoff end.
    func clearThrottle() {
        throttledSince = nil
        throttledUntil = nil
        nextBackoff = Self.initialBackoff
    }

    private func pauseForQuota() {
        guard !isPaused else { return }
        isPaused = true
        logger.error("iCloud quota exceeded; sync paused until resume()")
        eventHandler?(.quotaExceeded)
    }

    func emitUnlinked(reason: String) {
        guard !isUnlinked else { return }
        isUnlinked = true
        logger.notice("hub zones gone (\(reason, privacy: .public)); unlinked")
        // Nothing is fetched any more: a push waiting on the engine's run
        // returns now instead of at its grace's end.
        releaseEngineRunWaiters()
        eventHandler?(.unlinked)
    }

    /// Re-schedules the pending queue and asks the engine to send now.
    func resend() async {
        guard let engine, !isUnlinked else { return }
        nudgeEngine()
        do {
            try await engine.sendChanges(scope: zones.allZoneIDs)
        } catch let error as CKError {
            handleSendError(error)
        } catch {
            recordError(error)
        }
    }

    func recordError(_ error: Error) {
        lastError = error.localizedDescription
    }
}
