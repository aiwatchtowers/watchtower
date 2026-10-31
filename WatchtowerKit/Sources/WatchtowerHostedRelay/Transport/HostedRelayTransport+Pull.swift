import Foundation
import WatchtowerRelayProto
import WatchtowerSync

/// Server pages into the local buffer (R5): one pull in flight at a time, each zone paged from
/// its stored cursor, the cursor moving only with the page it covers; `TOKEN_EXPIRED` resyncs
/// the zone from 0 and deletes what the server forgot only after the resync's last page (R10).
extension HostedRelayTransport {
    /// Pulls `zones`, joining the pull in flight (which then pulls them too before it ends).
    func pullZones(_ zones: Set<CloudZoneID>) async throws {
        zonesToPull.formUnion(zones)
        if let pullTask { return try await pullTask.value }
        let task = Task { try await self.drainPulls() }
        pullTask = task
        try await task.value
    }

    /// Pulls the owed zones until none is owed. The last check and the end of the pull are one
    /// step on the actor, so a caller that joins is always served.
    private func drainPulls() async throws {
        var buffered = false
        do {
            while !zonesToPull.isEmpty {
                let zones = CloudZoneID.allCases.filter(zonesToPull.contains)
                zonesToPull.removeAll()
                for zone in zones {
                    let pulled = try await pullZone(zone)
                    buffered = buffered || pulled
                }
            }
        } catch {
            zonesToPull.removeAll()
            pullTask = nil
            if buffered { engineFetchedHandler?() }
            throw error
        }
        pullTask = nil
        if buffered { engineFetchedHandler?() }
    }

    /// Pages `zone` from its cursor to the end; true when it buffered anything.
    private func pullZone(_ zone: CloudZoneID) async throws -> Bool {
        try gate()
        var resync = try store.relayResyncPending(zone)
        var since = try store.relayCursor(zone: zone)
        var restarted = false
        var buffered = false
        while true {
            var request = Relay_V1_Changes()
            request.zone = zoneName(zone)
            request.sinceSeq = since
            request.limit = Self.pageLimit
            energy?.record(zone == .data ? .dataZonePoll : .relayZonePoll)
            let page: Relay_V1_ChangesResult
            do {
                page = try await call(zone) { try await self.client.changes(request) }
            } catch HostedRelayError.server(code: .tokenExpired, _) where since > 0 && !restarted {
                // Once per pull: a resync that expires again waits for the next pull.
                Self.logger.info("relay pull: token expired, resyncing \(Self.kind(zone), privacy: .public)")
                try store.beginRelayResync(zone)
                (resync, restarted, since) = (true, true, 0)
                continue
            }
            if page.more, page.newSeq <= since {
                Self.logger.error("relay pull: a page that does not move, \(Self.kind(zone), privacy: .public)")
                throw HostedRelayError.undecodable(status: 200)
            }
            var changed: [CloudRecord] = []
            var deleted = page.deleted
            for record in page.changed {
                if record.deleted {
                    deleted.append(record.name)
                } else {
                    changed.append(try await incoming(record, zone: zone))
                }
            }
            try store.bufferRelayPage(zone: zone, changed: changed, deleted: deleted, newSeq: page.newSeq, resync: resync)
            buffered = buffered || !changed.isEmpty || !deleted.isEmpty
            since = page.newSeq
            if !page.more { break }
        }
        if resync {
            let gone = try store.finishRelayResync(zone)
            if !gone.isEmpty {
                Self.logger.info("relay resync: \(gone.count) records gone, \(Self.kind(zone), privacy: .public)")
                buffered = true
            }
        }
        return buffered
    }

    /// A server record as the buffer keeps it (R7: the writer's clock is `serverAt`; no author),
    /// its attachment downloaded to the stash first.
    private func incoming(_ record: Relay_V1_Record, zone: CloudZoneID) async throws -> CloudRecord {
        let asset = record.attachmentID.isEmpty ? nil : try await download(record, zone: zone)
        return Self.cloudRecord(record, zone: zone, asset: asset)
    }

    /// The relay's `Record` as a `CloudRecord` of `zone` (pages and conflicts).
    static func cloudRecord(_ record: Relay_V1_Record, zone: CloudZoneID, asset: URL? = nil) -> CloudRecord {
        let at = Date(timeIntervalSince1970: TimeInterval(record.clientModifiedAtMs) / 1000)
        return CloudRecord(
            recordName: record.name, zone: zone, kind: WireKind.envelope, modifiedAt: at, payload: record.envelope,
            assetFileURL: asset, origin: RecordOrigin(author: nil, serverAt: at), recordSeq: record.recordSeq)
    }

    /// Re-reads `zone` after a refused write (R6, R8); a failure is only logged.
    func reread(_ zone: CloudZoneID) async {
        do {
            try await pullZones([zone])
        } catch {
            Self.logger.error("relay re-read after a refused write failed, \(Self.kind(zone), privacy: .public)")
        }
    }
}
