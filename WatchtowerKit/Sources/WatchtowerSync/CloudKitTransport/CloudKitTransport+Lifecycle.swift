import CloudKit
import Foundation
import os

extension CloudKitTransport {
    // MARK: - Lifecycle

    /// Builds the CKSyncEngine on the scope's database with the stored
    /// engine state and, in the hub role, registers this hub's two zones as
    /// pending database changes (a phone never creates zones).
    /// Failures are recorded and surfaced via availability() — never thrown,
    /// never fatal: unsigned dev builds routinely lack the iCloud entitlement
    /// and must degrade to store-only operation (records wait in the pending
    /// queue).
    /// A `deleteHubZones` still running is awaited first: the engine is
    /// built only on the store its wipe left.
    public func start() async {
        isStopped = false
        await settleHubZoneDelete()
        await startEngine()
    }

    func startEngine() async {
        guard engine == nil, !isStopped, hubZoneDelete == nil else { return }
        guard entitlementCheck() else {
            lastError = "missing iCloud entitlement (unsigned dev build?)"
            return
        }
        do {
            if try store.adoptScope(scope, hubID: zones.hubID) {
                logger.notice("transport store held another database's or hub's state; wiped it")
            }
        } catch {
            // The store's scope is unknown: starting could drive this
            // database with the other database's engine state.
            recordError(error)
            return
        }

        var stateSerialization: CKSyncEngine.State.Serialization?
        do {
            if let data = try store.loadEngineState() {
                stateSerialization = try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
            }
        } catch {
            // Unreadable state blob: start the engine fresh (it re-fetches
            // everything and re-emits a .stateUpdate) rather than failing.
            stateSerialization = nil
        }

        let box = DelegateBox(ownZoneIDs: zones.allZoneIDs)
        box.transport = self
        let engine = engineFactory(stateSerialization, box)
        self.engine = engine
        delegateBox = box
        // The new engine resumes from the stored state, which is from
        // before any batch a previous engine failed to buffer.
        engineBatchUnbuffered = false

        if managesZones {
            engine.add(pendingDatabaseChanges: CloudZoneID.allCases.map {
                .saveZone(CKRecordZone(zoneID: zones.zoneID(for: $0)))
            })
        }
        lastError = nil
        nudgeEngine()
    }

    /// Stops syncing until the next `start()` (the Mac owner turned the hub
    /// off): cancels the engine's operations and drops it, so nothing is
    /// fetched or sent on pushes any more. Saves made meanwhile wait in the
    /// store; the engine state stays in the store for the next start.
    public func stop() async {
        isStopped = true
        retryTask?.cancel()
        retryTask = nil
        restartTask?.cancel()
        restartTask = nil
        // The throttle dies with its retry task: a restart must not wait out
        // a deadline nothing is armed to end.
        throttledUntil = nil
        throttledSince = nil
        nextBackoff = Self.initialBackoff
        // Actor re-entrancy: an engine built while cancelOperations() was
        // awaited is dropped too, unless a start() meanwhile un-stopped us.
        releaseEngineRunWaiters()
        while isStopped, let live = engine {
            engine = nil
            delegateBox = nil
            await live.cancelOperations()
        }
    }

    /// Manual fetch with the forced zone poll — the poll loops call this
    /// (a silent push takes the light `fetchForPush`). No-op while the engine is unavailable, the
    /// server asked us to wait, or the link is gone. Fetch errors the
    /// transport can act on (unlinked, an expired token, throttling) are
    /// handled, not thrown. A successful fetch ends a throttling stretch.
    public func pull() async throws {
        // One manual fetch at a time: a push fetch running its own fetch
        // ends first (its outcome is the push's), then this pull polls as
        // usual. One still waiting on the engine's run stops waiting and
        // takes this pull as its fetch, so a pull never waits on the engine.
        while let pushFetchTask, pushFetchFetching {
            _ = try? await pushFetchTask.value
        }
        if pushFetchTask != nil {
            abandonEngineRunWaits()
        }
        if let pullTask {
            pullJoins += 1
            return try await pullTask.value
        }
        guard let engine, !isUnlinked else { return }
        if let throttledUntil, now() < throttledUntil { return }
        // Actor-isolated: the body runs after this job suspends below, so
        // `pullTask` is set before it can clear it.
        let task = Task {
            defer { self.pullTask = nil }
            try await self.performPull(engine: engine, poll: true)
        }
        pullTask = task
        try await task.value
    }

    /// `poll`: the forced zone poll after the engine fetch (`pull()`);
    /// false for a push's light fetch.
    func performPull(engine: any SyncEngineDriving, poll: Bool) async throws {
        manualFetchInFlight = true
        parkedEventErrors = []
        do {
            try await fetchAndHandle(engine: engine, poll: poll)
        } catch where isUnlinked {
            // The link ended while this pull ran (the event path or the
            // handling unlinked): `.unlinked` already told the owner, so a
            // leftover zone error is not a new outage.
            return
        }
    }

    private func fetchAndHandle(engine: any SyncEngineDriving, poll: Bool) async throws {
        var thrown: CKError?
        energy?.record(.engineFetch)
        do {
            try await engine.fetchChanges(scope: zones.allZoneIDs)
        } catch let error as CKError {
            thrown = error
        } catch {
            manualFetchInFlight = false
            parkedEventErrors = []
            throw error
        }
        let parked = parkedEventErrors
        manualFetchInFlight = false
        parkedEventErrors = []
        if let thrown {
            // The thrown error supersedes the event copies of it, but keeps
            // their zones: a bare error is ours when nothing was parked or
            // any parked zone is ours, and otherwise is about a foreign zone.
            let zoneID = parked.isEmpty ? nil : (parked.first { ownsZone($0.zoneID) } ?? parked[0]).zoneID
            try await handleFetchError(thrown, zoneID: zoneID, engine: engine)
        } else if !parked.isEmpty {
            // The engine reported this fetch's failures as events only.
            let items = parked.flatMap { Self.flatten($0.error, zoneID: $0.zoneID) }
            try await handleFetchItems(items, original: parked[0].error, engine: engine)
        } else {
            clearThrottle()
        }
        if poll {
            try await pollZones(engine: engine)
        }
    }

    /// The poll half of `pull()`: each zone's changes straight from the
    /// server since the transport's own per-zone token, buffered like the
    /// engine's fetched changes. The engine fetches only the zones a
    /// delivered push told it about, so without this a manual pull sends no
    /// request (seen on a hub whose pushes never arrived: the phone's
    /// records sat unread until an engine restart). Skipped once unlinked,
    /// stopped or throttled, and when the engine was replaced meanwhile (an
    /// account reset wiped the store this page would land in).
    ///
    /// A pass that buffers every zone up to date also covers an engine
    /// batch that failed to buffer before it started, so it lets the
    /// engine state be saved again (`saveEngineState`).
    private func pollZones(engine: any SyncEngineDriving) async throws {
        let failuresBefore = engineBufferFailures
        var allZonesUpToDate = true
        for zone in CloudZoneID.allCases {
            var moreComing = true
            while moreComing {
                guard self.engine === engine, !isUnlinked, !isStopped else { return }
                if let throttledUntil, now() < throttledUntil { return }
                let zoneID = zones.zoneID(for: zone)
                let page: PolledZoneChanges
                energy?.record(zone == .data ? .dataZonePoll : .relayZonePoll)
                do {
                    page = try await engine.fetchZoneChanges(zoneID, since: try store.pollToken(zone: zone))
                } catch let error as CKError {
                    allZonesUpToDate = false
                    try await handlePollError(error, zone: zone, zoneID: zoneID, engine: engine)
                    break
                }
                guard self.engine === engine, !isStopped else { return }
                // A page that did not reach the buffer keeps the zone's
                // token (the next pull reads it again); the other zones
                // are still polled.
                guard bufferPolledChanges(page) else {
                    allZonesUpToDate = false
                    break
                }
                try store.setPollToken(page.changeToken, zone: zone)
                moreComing = page.moreComing
            }
        }
        if allZonesUpToDate, engineBufferFailures == failuresBefore {
            engineBatchUnbuffered = false
        }
    }

    /// A poll error. An expired token restarts that zone's poll from the
    /// beginning on the next pull (known records are skipped by change tag).
    /// A missing zone in the hub role is one the engine has not created
    /// yet; in the phone role it unlinks, through the usual fetch-error
    /// rules, which also wait out throttling and rethrow anything else.
    private func handlePollError(
        _ error: CKError,
        zone: CloudZoneID,
        zoneID: CKRecordZone.ID,
        engine: any SyncEngineDriving
    ) async throws {
        if error.code == .changeTokenExpired {
            try store.setPollToken(nil, zone: zone)
            return
        }
        if managesZones, Self.zoneGoneCodes.contains(error.code) { return }
        try await handleFetchError(error, zoneID: zoneID, engine: engine)
    }

    /// Buffers a poll page minus what the store already holds: a record
    /// whose change tag matches its archived system fields (fetched by the
    /// engine, or sent from here), and a deletion of a record it has no
    /// system fields for (never seen, or its deletion already buffered).
    private func bufferPolledChanges(_ page: PolledZoneChanges) -> Bool {
        let modifications = page.modifications.filter { record in
            guard let zone = zones.cloudZone(for: record.recordID.zoneID),
                  let tag = record.recordChangeTag else { return true }
            return Self.knownChangeTag(recordName: record.recordID.recordName, zone: zone, store: store) != tag
        }
        let deletions = page.deletions.filter { id in
            guard let zone = zones.cloudZone(for: id.zoneID) else { return false }
            return (try? store.systemFields(recordName: id.recordName, zone: zone)) != nil
        }
        return bufferFetched(modifications: modifications, deletions: deletions)
    }

    /// The change tag in a record's archived system fields, if any.
    private static func knownChangeTag(recordName: String, zone: CloudZoneID, store: TransportStore) -> String? {
        guard let data = try? store.systemFields(recordName: recordName, zone: zone),
              let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data),
              let known = CKRecord(coder: unarchiver) else { return nil }
        unarchiver.finishDecoding()
        return known.recordChangeTag
    }

    /// Lifts the quota pause (the owner freed iCloud space) and sends again.
    public func resume() async {
        guard isPaused else { return }
        isPaused = false
        await resend()
    }

    public func availability() async -> CloudAvailability {
        if let lastError { return .unavailable(lastError) }
        guard entitlementCheck() else {
            return .unavailable("missing iCloud entitlement (unsigned dev build?)")
        }
        do {
            switch try await CKContainer(identifier: containerID).accountStatus() {
            case .available: return .available
            case .noAccount: return .noAccount
            case .restricted: return .restricted
            case .couldNotDetermine: return .unavailable("iCloud account status could not be determined")
            case .temporarilyUnavailable: return .unavailable("iCloud account temporarily unavailable")
            @unknown default: return .unavailable("unknown iCloud account status")
            }
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }
}
