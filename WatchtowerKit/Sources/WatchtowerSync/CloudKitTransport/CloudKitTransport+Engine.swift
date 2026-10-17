import CloudKit
import Foundation
import os

extension CloudKitTransport {
    // MARK: - Engine plumbing

    /// Schedules the store's pending rows on the engine so it calls
    /// nextRecordZoneChangeBatch. No-op while the engine is nil (CloudKit
    /// unavailable) — records simply wait in the store until start() succeeds.
    func nudgeEngine() {
        guard let engine, !isUnlinked else { return }
        do {
            // Names only: the engine reads the records (payload BLOBs, assets)
            // when it asks for a batch.
            let pending = try store.pendingNames(limit: Self.maxBatchSize)
            var changes: [CKSyncEngine.PendingRecordZoneChange] = pending.saves.map {
                .saveRecord(CKRecord.ID(recordName: $0.name, zoneID: zones.zoneID(for: $0.zone)))
            }
            changes += pending.deletes.map {
                .deleteRecord(CKRecord.ID(recordName: $0.name, zoneID: zones.zoneID(for: $0.zone)))
            }
            guard !changes.isEmpty else { return }
            engine.add(pendingRecordZoneChanges: changes)
        } catch {
            recordError(error)
        }
    }

    /// An event of the engine `box` belongs to. One from an engine that was
    /// stopped or replaced is dropped: its state update could save a token
    /// past a batch it failed to buffer, and the current engine resumes
    /// from the stored state anyway.
    func handleEngineEvent(_ event: CKSyncEngine.Event, from box: DelegateBox) {
        guard isCurrentEngine(box) else { return }
        switch event {
        case .stateUpdate(let stateUpdate):
            persistEngineState(stateUpdate.stateSerialization)
        case .fetchedRecordZoneChanges(let changes):
            bufferFetchedChanges(changes)
        case .sentRecordZoneChanges(let sent):
            handleSentChanges(
                saved: sent.savedRecords,
                deleted: sent.deletedRecordIDs,
                failedSaves: sent.failedRecordSaves.map { ($0.record, $0.error) },
                failedDeletes: sent.failedRecordDeletes
            )
        case .fetchedDatabaseChanges(let changes):
            handleDeletedZones(changes.deletions.map(\.zoneID))
        case .didFetchRecordZoneChanges(let fetched):
            // Not awaited here: a re-fetch from inside the engine's own
            // event delivery would wait on the fetch that is delivering.
            // Parked right here while a pull's fetch is awaiting the engine:
            // the engine awaits this delivery inside that fetch, so the park
            // happens before `fetchChanges(scope:)` returns — no Task hop that
            // could lose the race with the pull's resume. Phone role only
            // (the hub role ignores event-path errors, as before roles).
            if let error = fetched.error {
                if manualFetchInFlight, !managesZones, !isUnlinked {
                    parkedEventErrors.append((error, fetched.zoneID))
                } else {
                    Task { await self.handleFetchEventError(error, zoneID: fetched.zoneID) }
                }
            }
        case .accountChange(let change):
            handleAccountChange(change.changeType)
        case .willFetchChanges:
            engineWillFetch()
        case .didFetchChanges:
            engineDidFetch()
        default:
            break
        }
    }

    /// Whether `box` is the delegate of the running engine (each engine
    /// start makes its own). Internal for tests.
    func isCurrentEngine(_ box: DelegateBox) -> Bool {
        engine != nil && delegateBox === box
    }

    /// A server-side zone deletion evicts that zone's buffered events and
    /// archived system fields. In the hub role it then re-registers the
    /// zone so the surviving pending rows re-create it and re-send on the
    /// next batch, and a deleted DataZone fires the data-zone reset handler
    /// once. In the phone role the hub removed its zones (unlinked or
    /// removed this phone): the phone is unlinked, and it must never
    /// re-create the hub's zone. Another hub's zones are not ours.
    func handleDeletedZones(_ zoneIDs: [CKRecordZone.ID]) {
        let deletedZones = zoneIDs.compactMap(zones.cloudZone(for:))
        guard !deletedZones.isEmpty else { return }
        do {
            for zone in deletedZones {
                try store.evictZone(zone)
                if managesZones {
                    engine?.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zones.zoneID(for: zone)))])
                }
            }
            lastError = nil
        } catch {
            recordError(error)
        }
        if managesZones {
            // A deleted DataZone (`.encryptedDataReset`, the owner deleting
            // iCloud data) took every published slice record with it: the
            // owner's record of what is published is stale. Tell it once per
            // deletion batch, evicted or not (the server zone is gone).
            if deletedZones.contains(.data) {
                dataZoneResetHandler?()
            }
            nudgeEngine()
        } else {
            emitUnlinked(reason: "zone deleted")
        }
    }

    /// Acts on a fetch error, `zoneID` being the zone it is about when
    /// known (the event path). Per-zone errors of a `.partialFailure` carry
    /// their own zone. Only this hub's zones count: an error about another
    /// hub's (or, in `shared` scope, another owner's) zone never touches
    /// this link.
    /// - Phone role: `.zoneNotFound` / `.userDeletedZone` → unlinked.
    /// - Both roles: an expired change token re-fetches once (unless, in
    ///   the phone role, a zone is gone: unlinked); throttling waits.
    /// - Anything else is rethrown (phone role: unless it is only about
    ///   zones that are not this hub's).
    func handleFetchError(_ error: CKError, zoneID: CKRecordZone.ID?, engine: any SyncEngineDriving) async throws {
        try await handleFetchItems(Self.flatten(error, zoneID: zoneID), original: error, engine: engine)
    }

    /// `handleFetchError` over already-flattened items (one server failure
    /// may arrive as several parked events); `original` is what is rethrown.
    func handleFetchItems(
        _ items: [(zoneID: CKRecordZone.ID?, error: CKError)],
        original error: CKError,
        engine: any SyncEngineDriving
    ) async throws {
        let mine = items.filter { ownsZone($0.zoneID) }.map(\.error)
        if !managesZones, mine.contains(where: { Self.zoneGoneCodes.contains($0.code) }) {
            emitUnlinked(reason: "zone not found on fetch")
            return
        }
        if mine.contains(where: { $0.code == .changeTokenExpired }) {
            try await refetchAfterExpiredToken(engine: engine)
            return
        }
        if applyThrottle(from: mine) { return }
        if !managesZones, mine.isEmpty { return }
        throw error
    }

    /// The engine's report that fetching one zone failed. Hub role:
    /// ignored, exactly as before roles (the engine retries its own
    /// automatic fetches; `pull()` handles manual ones). Phone role: acts
    /// only on "zone gone" and an expired token for this hub's zones.
    /// While a `pull()` is awaiting the engine the error is parked for it.
    func handleFetchEventError(_ error: CKError, zoneID: CKRecordZone.ID) async {
        guard !managesZones, let engine, !isUnlinked else { return }
        if manualFetchInFlight {
            parkedEventErrors.append((error, zoneID))
            return
        }
        let mine = Self.flatten(error, zoneID: zoneID).filter { ownsZone($0.zoneID) }.map(\.error)
        if mine.contains(where: { Self.zoneGoneCodes.contains($0.code) }) {
            emitUnlinked(reason: "zone not found on an engine fetch")
        } else if mine.contains(where: { $0.code == .changeTokenExpired }) {
            do {
                try await refetchAfterExpiredToken(engine: engine)
            } catch where !isUnlinked {
                recordError(error)
            } catch {
                // Unlinked meanwhile: the event already said so.
            }
        }
    }

    /// One zone check and re-fetch after `.changeTokenExpired`; a second
    /// failure surfaces to the caller. A throttle on the zone check waits
    /// like any throttle.
    private func refetchAfterExpiredToken(engine: any SyncEngineDriving) async throws {
        guard !refetchInFlight else { return }
        refetchInFlight = true
        defer { refetchInFlight = false }
        if !managesZones {
            let exists: Bool
            do {
                energy?.record(.zoneCheck)
                exists = try await ownersZonesExist(engine: engine)
            } catch let error as CKError {
                if applyThrottle(from: Self.flatten(error, zoneID: nil).map(\.error)) { return }
                throw error
            }
            guard exists else {
                emitUnlinked(reason: "change token expired on a missing zone")
                return
            }
        }
        energy?.record(.engineFetch)
        refetchFetchInFlight = true
        defer { refetchFetchInFlight = false }
        try await engine.fetchChanges(scope: zones.allZoneIDs)
        clearThrottle()
    }

    /// nil (no zone context) counts as ours: the error may be about any zone.
    func ownsZone(_ zoneID: CKRecordZone.ID?) -> Bool {
        guard let zoneID else { return true }
        return zones.cloudZone(for: zoneID) != nil
    }

    private func ownersZonesExist(engine: any SyncEngineDriving) async throws -> Bool {
        let existing = try await engine.existingZoneNames()
        return CloudZoneID.allCases.allSatisfy { existing.contains($0.rawValue) }
    }

    /// A CloudKit account sign-out or switch makes all local state belong to
    /// the wrong account: wipe and relaunch with fresh engine state. A plain
    /// sign-in has nothing local to discard (the reconcile fetch handles it).
    func handleAccountChange(_ changeType: CKSyncEngine.Event.AccountChange.ChangeType) {
        switch changeType {
        case .signIn:
            return
        case .signOut, .switchAccounts:
            resetForAccountChange()
        @unknown default:
            resetForAccountChange()
        }
    }

    /// Wipes the store, drops the engine, and relaunches it fresh, recording
    /// the reset and notifying the owner. Internal so it is exercisable
    /// without fabricating a CKSyncEngine account event.
    func resetForAccountChange() {
        do {
            try store.wipe()
        } catch {
            // Wipe failed: the store may contain stale old-account state.
            // Drop the engine so the transport is inert (.unavailable via lastError)
            // until the operator restarts — relaunching against a partially-wiped
            // store would reload old-account engine state/system_fields into the
            // new account context, and clearing lastError would make availability()
            // lie. The reset handler is intentionally NOT fired: the hub must not
            // wipe its own derived state when the transport's store is in an
            // unknown state.
            recordError(error)
            engine = nil
            delegateBox = nil
            releaseEngineRunWaiters()
            return
        }
        engine = nil
        delegateBox = nil
        releaseEngineRunWaiters()
        // The old account's throttle and quota say nothing about the new one.
        retryTask?.cancel()
        throttledSince = nil
        throttledUntil = nil
        nextBackoff = Self.initialBackoff
        isPaused = false
        batchLimit = Self.maxBatchSize
        lastBuiltBatch = nil
        shrunkBatchID = nil
        accountResetCount += 1
        accountResetHandler?()
        // Relaunch with fresh state (loadEngineState is now empty). No-op on
        // unsigned dev builds — start() re-checks the entitlement and returns.
        restartTask = Task {
            guard !Task.isCancelled else { return }
            await startEngine()
        }
    }

    func nextEngineBatch() -> CKSyncEngine.RecordZoneChangeBatch? {
        guard !isPaused, !isUnlinked else { return nil }
        if let throttledUntil, now() < throttledUntil { return nil }
        do {
            let pending = try store.pendingBatch(limit: batchLimit)
            guard !pending.saves.isEmpty || !pending.deletes.isEmpty else {
                // Queue drained: the next backlog starts at full size again.
                batchLimit = Self.maxBatchSize
                return nil
            }
            let recordsToSave = try pending.saves.map {
                Self.ckRecord(
                    from: $0,
                    in: zones.zoneID(for: $0.zone),
                    systemFields: try store.systemFields(recordName: $0.recordName, zone: $0.zone)
                )
            }
            batchSerial += 1
            lastBuiltBatch = (
                id: batchSerial,
                size: pending.saves.count + pending.deletes.count,
                saves: pending.saves.map { (name: $0.recordName, zone: $0.zone) }
            )
            let recordIDsToDelete = pending.deletes.map {
                CKRecord.ID(recordName: $0.name, zoneID: zones.zoneID(for: $0.zone))
            }
            energy?.record(.sendBatch)
            return CKSyncEngine.RecordZoneChangeBatch(
                recordsToSave: recordsToSave,
                recordIDsToDelete: recordIDsToDelete,
                atomicByZone: false
            )
        } catch {
            recordError(error)
            return nil
        }
    }

    private func persistEngineState(_ serialization: CKSyncEngine.State.Serialization) {
        do {
            saveEngineState(try JSONEncoder().encode(serialization))
        } catch {
            recordError(error)
        }
    }

    /// Saves the engine's state (its change tokens) unless a batch this
    /// engine fetched failed to reach the buffer: CKSyncEngine counts a
    /// delivered batch as done, so a token saved past it would lose it for
    /// good. The engine keeps running on its in-memory state; nothing is
    /// saved until a `pull()`'s zone poll has buffered every zone up to
    /// date after the failure (see `pollZones`), or the next engine start,
    /// which resumes from the last good token and fetches the batch again.
    /// Internal so tests drive it without a CKSyncEngine state.
    func saveEngineState(_ data: Data) {
        guard !engineBatchUnbuffered else { return }
        do {
            try store.saveEngineState(data)
            lastError = nil
        } catch {
            recordError(error)
        }
    }

    private func bufferFetchedChanges(_ event: CKSyncEngine.Event.FetchedRecordZoneChanges) {
        bufferEngineFetched(modifications: event.modifications.map(\.record), deletions: event.deletions.map(\.recordID))
    }

    /// The engine's fetched batch; a failed buffer write stops the engine
    /// state from being saved (see `saveEngineState`). Internal so tests
    /// feed it without fabricating an engine event.
    func bufferEngineFetched(modifications: [CKRecord], deletions: [CKRecord.ID]) {
        if !bufferFetched(modifications: modifications, deletions: deletions) {
            engineBatchUnbuffered = true
            engineBufferFailures += 1
        }
    }

    /// Buffers fetched records and deletions of this hub's zones (the
    /// engine's fetched-changes events and the transport's own zone poll).
    /// Returns false when the store write failed (recorded in `lastError`):
    /// the caller must not move its change token past this batch.
    /// Internal so tests feed it without fabricating an engine event.
    func bufferFetched(modifications fetched: [CKRecord], deletions: [CKRecord.ID]) -> Bool {
        let modifications = fetched.filter { zones.cloudZone(for: $0.recordID.zoneID) != nil }
        let changed = modifications.compactMap { modification -> CloudRecord? in
            guard let record = zones.cloudZone(for: modification.recordID.zoneID)
                .flatMap({ Self.cloudRecord(from: modification, zone: $0) }) else { return nil }
            // CKAsset downloads land in a temporary staging area that may be
            // purged after this callback; the buffered event outlives it, so
            // stash a durable copy and point the event at that. A failed
            // stash keeps the temporary URL — best-effort, the consumer's
            // validation surfaces a vanished file as a failed ingest. An
            // asset over the stash cap is not copied either: the event keeps
            // CloudKit's temporary URL, so the hub refuses it by size only
            // while that file is still there; once CloudKit purged it, the
            // hub reports the audio as missing, not as too large (the phone's
            // own uploader cap keeps a real recording under the stash cap).
            guard let assetURL = record.assetFileURL,
                  let stashed = store.stashAsset(from: assetURL, recordName: record.recordName, zone: record.zone) else {
                return record
            }
            return CloudRecord(
                recordName: record.recordName,
                zone: record.zone,
                kind: record.kind,
                modifiedAt: record.modifiedAt,
                payload: record.payload,
                notifyLevel: record.notifyLevel,
                assetFileURL: stashed,
                creatorUserRecordName: record.creatorUserRecordName,
                serverModifiedAt: record.serverModifiedAt
            )
        }
        var deletedByZone: [CloudZoneID: [String]] = [:]
        for deletion in deletions {
            guard let zone = zones.cloudZone(for: deletion.zoneID) else { continue }
            deletedByZone[zone, default: []].append(deletion.recordName)
        }
        // Persist the fetched records' system fields so a later local save
        // of the same recordName goes out with the server's change tag
        // (e.g. desktop status write-backs onto mobile-created records).
        let systemFields = modifications.compactMap { modification -> (name: String, zone: CloudZoneID, data: Data)? in
            guard let zone = zones.cloudZone(for: modification.recordID.zoneID) else { return nil }
            return (name: modification.recordID.recordName, zone: zone, data: Self.archivedSystemFields(of: modification))
        }
        do {
            try store.bufferFetched(changed: changed, systemFields: systemFields, deleted: deletedByZone)
            lastError = nil
            return true
        } catch {
            recordError(error)
            return false
        }
    }

    /// The outcome of one sent batch: clears what landed, persists fresh
    /// system fields, and applies the spec §9 error rules to what failed.
    /// Internal (plain arrays, not the engine's event type) so it is
    /// exercisable without fabricating a CKSyncEngine event.
    func handleSentChanges(
        saved: [CKRecord],
        deleted: [CKRecord.ID],
        failedSaves: [(record: CKRecord, error: CKError)],
        failedDeletes: [CKRecord.ID: CKError]
    ) {
        var saves: [(name: String, zone: CloudZoneID, sentModifiedAt: Date)] = []
        var savedFields: [(name: String, zone: CloudZoneID, data: Data)] = []
        for record in saved {
            guard let zone = zones.cloudZone(for: record.recordID.zoneID) else { continue }
            // Use the record's own modifiedAt as the stamp so that a newer
            // local re-enqueue (modified_at > stamp) is not silently lost.
            // Missing field → .distantFuture → clears unconditionally (old behaviour).
            let stamp = (record["modifiedAt"] as? Date) ?? .distantFuture
            saves.append((name: record.recordID.recordName, zone: zone, sentModifiedAt: stamp))
            // The saved record carries the fresh server change tag — persist it
            // so the NEXT save of this record (heartbeat re-save, status flip)
            // doesn't hit .serverRecordChanged.
            savedFields.append((
                name: record.recordID.recordName,
                zone: zone,
                data: Self.archivedSystemFields(of: record)
            ))
        }
        var deletes: [(name: String, zone: CloudZoneID)] = []
        for recordID in deleted {
            guard let zone = zones.cloudZone(for: recordID.zoneID) else { continue }
            deletes.append((name: recordID.recordName, zone: zone))
        }
        // Failed saves stay pending — the engine retries them. Failed deletes
        // for records the server never saw count as success under the seam's
        // idempotent-delete contract, so clear those too.
        for (recordID, error) in failedDeletes where error.code == .unknownItem {
            guard let zone = zones.cloudZone(for: recordID.zoneID) else { continue }
            deletes.append((name: recordID.recordName, zone: zone))
        }

        let failures = failedSaves.map(\.error) + Array(failedDeletes.values)
        applySendFailures(failures)
        let throttled = applyThrottle(from: failures)
        if !saved.isEmpty || !deleted.isEmpty, !throttled {
            clearThrottle()
        }

        // re-nudge: pendingBatch is capped at 200; without this a large offline
        // backlog stalls — and it is also what reschedules the still-pending
        // failed saves with their corrected system fields. Deferred so a store
        // error mid-block cannot skip the reschedule (Task 1 review Minor 1).
        defer { nudgeEngine() }
        do {
            try store.clearPending(saves: saves, deletes: deletes)
            for entry in savedFields {
                try store.saveSystemFields(entry.data, recordName: entry.name, zone: entry.zone)
            }
            for entry in deletes {
                try store.deleteSystemFields(recordNames: [entry.name], zone: entry.zone)
            }
            try fixSystemFieldsForFailedSaves(failedSaves)
            try dropSavesWithMissingAssets(failedSaves)
            let batchSize = saved.count + deleted.count + failedSaves.count + failedDeletes.count
            let tooLarge = failedSaves.filter { $0.error.code == .limitExceeded }.compactMap { failure in
                zones.cloudZone(for: failure.record.recordID.zoneID).map { (name: failure.record.recordID.recordName, zone: $0) }
            }
            if !tooLarge.isEmpty {
                try shrinkBatch(size: batchSize, rejectable: tooLarge)
            }
            lastError = nil
        } catch {
            recordError(error)
        }
    }

    /// An error from an engine send call itself rather than per record.
    func handleSendError(_ error: CKError) {
        let errors = Self.flatten(error, zoneID: nil).map(\.error)
        applySendFailures(errors)
        if errors.contains(where: { $0.code == .limitExceeded }) {
            // A request-level rejection names no record: it is about the
            // batch last handed out.
            if let batch = lastBuiltBatch {
                do {
                    try shrinkBatch(size: batch.size, rejectable: batch.saves)
                } catch {
                    recordError(error)
                }
            } else {
                batchLimit = max(1, batchLimit / 2)
            }
        }
        if !applyThrottle(from: errors), !errors.contains(where: { Self.handledSendCodes.contains($0.code) }) {
            recordError(error)
        }
    }

    /// Failed saves stay pending and the trailing re-nudge reschedules them,
    /// but two error codes need system-field surgery first or the retry fails
    /// identically forever.
    private func fixSystemFieldsForFailedSaves(_ failures: [(record: CKRecord, error: CKError)]) throws {
        for failure in failures {
            guard let zone = zones.cloudZone(for: failure.record.recordID.zoneID) else { continue }
            let name = failure.record.recordID.recordName
            switch failure.error.code {
            case .serverRecordChanged:
                // Conflict policy: this device's payload wins — desktop is the
                // source of truth for DataZone, and for RelayZone the
                // write-back/chunk author wins by protocol design. Persist the
                // SERVER record's system fields (userInfo's
                // CKRecordChangedErrorServerRecordKey, surfaced as
                // CKError.serverRecord) so the retry carries the server change
                // tag and succeeds instead of looping.
                if let server = failure.error.serverRecord {
                    try store.saveSystemFields(
                        Self.archivedSystemFields(of: server),
                        recordName: name,
                        zone: zone
                    )
                }
            case .unknownItem:
                // The server-side record vanished while we held its change tag
                // (deleted by another device). Drop the stale system fields so
                // the retry goes out as a fresh record instead of wedging on a
                // tag the server no longer knows.
                try store.deleteSystemFields(recordNames: [name], zone: zone)
            default:
                break
            }
        }
    }

    /// A save whose asset file is gone (`.assetFileNotFound`) fails the
    /// same way on every retry — e.g. a recording upload whose audio the
    /// phone deleted on the hub's `received` echo while the save was still
    /// queued. It is rejected like a record too large alone: dropped from
    /// the queue, logged, and handed to the rejected-record handler.
    /// `dropPending` ignores the stamp, so a newer version re-enqueued after
    /// the failed batch was built goes too — this heals only where the
    /// rejected handler republishes (the hub's `.data` slices); a caller
    /// without such a handler loses that newer save.
    private func dropSavesWithMissingAssets(_ failures: [(record: CKRecord, error: CKError)]) throws {
        for failure in failures where failure.error.code == .assetFileNotFound {
            guard let zone = zones.cloudZone(for: failure.record.recordID.zoneID) else { continue }
            let name = failure.record.recordID.recordName
            try store.dropPending(recordName: name, zone: zone)
            logger.error("the asset file of \(name, privacy: .public) is gone (assetFileNotFound); dropped it from the send queue")
            recordRejectedHandler?(name, zone)
        }
    }
}
