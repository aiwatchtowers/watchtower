import CloudKit
import Foundation
import os

// MARK: - Send now (the mobile hub's fast lane)

extension CloudKitTransport {
    /// Asks the engine to send the pending queue at once instead of waiting
    /// for its own scheduling (mobile POC spec §4.5: the hub's fast lane
    /// sends right after a fast diff saved something). The same path as a
    /// throttle retry (`resend()`). No-op while stopped, without an engine,
    /// unlinked, paused for quota, or inside a server-requested wait.
    public func sendNow() async {
        guard !isStopped, !isPaused else { return }
        if let throttledUntil, now() < throttledUntil { return }
        await resend()
    }
}

// MARK: - Hub zones (multi-hub spec §3.3, §3.6)

extension CloudKitTransport {
    /// Hub role, after `stop()`: deletes this hub's two zones on the server
    /// (the owner turned the hub off; their shares and every participant go
    /// with them) and wipes the store, whose engine state and system fields
    /// describe zones that no longer exist. A delete that removed nothing
    /// throws CloudKit's error and leaves both in place; one that removed
    /// something but did not finish throws `HubZoneError.partlyDeleted`.
    /// A call while a delete runs joins it (its outcome, no second server
    /// delete), and `start()` waits for it.
    public func deleteHubZones() async throws {
        guard role == .hub else { throw HubZoneError.notHub }
        if let running = hubZoneDelete {
            try await running.value
            return
        }
        guard engine == nil else { throw HubZoneError.engineRunning }
        guard entitlementCheck() else { throw HubZoneError.noEntitlement }
        let work = Task { try await self.deleteZonesThenWipe() }
        hubZoneDelete = work
        let outcome = await work.result
        if hubZoneDelete == work { hubZoneDelete = nil }
        try outcome.get()
    }

    /// Returns once no `deleteHubZones` is running.
    func settleHubZoneDelete() async {
        while let running = hubZoneDelete {
            _ = await running.result
            if hubZoneDelete == running { hubZoneDelete = nil }
        }
    }

    private func deleteZonesThenWipe() async throws {
        do {
            try await zoneAdmin.deleteZones(zones.allZoneIDs)
        } catch let partial as PartialZoneDeleteError {
            logger.error("hub zones partly deleted: \(partial.underlying.localizedDescription, privacy: .public)")
            throw HubZoneError.partlyDeleted
        }
        // Re-checked after the await: the zones are gone, so a store this
        // engine drives must not be wiped under it (`start()` waits for this
        // delete, so this holds unless that contract breaks).
        guard engine == nil else {
            logger.error("hub zones deleted while an engine runs; the store is not wiped")
            throw HubZoneError.partlyDeleted
        }
        do {
            try store.wipe()
        } catch {
            logger.error("hub zones deleted, store not wiped: \(error.localizedDescription, privacy: .public)")
            throw HubZoneError.partlyDeleted
        }
    }

    /// Hub role: the single-hub build's fixed-name `DataZone`/`RelayZone`.
    /// `deleteIf` gets the legacy DataZone `heartbeat` payload (nil: none)
    /// and decides; both legacy zones that exist go together, or neither. A
    /// legacy RelayZone with no legacy DataZone has no heartbeat (nil) and is
    /// deleted if `deleteIf` agrees. A heartbeat record that exists but whose
    /// payload cannot be read keeps the zones without asking `deleteIf`
    /// (spec §3.6): it may be another hub's.
    public func removeLegacyZones(
        deleteIf: @Sendable (_ heartbeatPayload: Data?) -> Bool
    ) async throws -> LegacyZoneCleanup {
        guard role == .hub else { throw HubZoneError.notHub }
        guard entitlementCheck() else { throw HubZoneError.noEntitlement }
        let present = try await zoneAdmin.zoneIDs().filter(HubZones.legacyZoneIDs.contains)
        guard !present.isEmpty else { return .noneFound }
        var payload: Data?
        let legacyData = HubZones.legacyZoneID(.data)
        if present.contains(legacyData) {
            let heartbeat = try await zoneAdmin.record(CKRecord.ID(recordName: HeartbeatPayload.recordName, zoneID: legacyData))
            if let heartbeat {
                guard let bytes = heartbeat.encryptedValues["payload"] as? Data else { return .kept }
                payload = bytes
            }
        }
        guard deleteIf(payload) else { return .kept }
        try await zoneAdmin.deleteZones(present)
        return .deleted
    }
}
