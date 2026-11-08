import Foundation
import WatchtowerRelayProto
import WatchtowerSync

/// Writes (R8): the plain queue flushed in enqueue order, and conditional saves and deletes
/// sent after it, their outcomes matched to the items by index (R6).
extension HostedRelayTransport {
    /// Why a flush stopped: the refusal and the zone of the write that met it.
    struct FlushStop {
        let refusal: TransportRefusal
        let zone: CloudZoneID
    }

    /// Sends the plain queue one row at a time, oldest first, unconditionally. Stops at the first
    /// refusal that retrying may clear, leaving it and the rest queued; a `.permanent` refusal
    /// (or an asset file that is gone) drops that row and goes on, as `CloudKitTransport` drops a
    /// record CloudKit rejects alone. Throws only for local errors (the store).
    ///
    /// Single-flight: one pass at a time, so no row goes out twice and a save re-queued as a
    /// delete mid-flight is never sent again after its delete. A caller waits for the pass in
    /// flight (which may have read the queue before the caller's rows were added), then runs its
    /// own, or joins one that started after it was called.
    func flush() async throws -> FlushStop? {
        let calledAt = flushStarts
        while let running = flushTask {
            if flushStarts > calledAt { return try await running.value }
            _ = try? await running.value
        }
        flushStarts += 1
        let task = Task { try await self.flushPass() }
        flushTask = task
        return try await task.value
    }

    /// One pass over the queue; clears `flushTask` in the same actor step as its last check.
    private func flushPass() async throws -> FlushStop? {
        do {
            let stop = try await sendQueue()
            flushTask = nil
            return stop
        } catch {
            flushTask = nil
            throw error
        }
    }

    private func sendQueue() async throws -> FlushStop? {
        while true {
            let batch = try store.pendingBatch(limit: 1)
            if let record = batch.saves.first {
                switch await sendPlain(record) {
                case .sent:
                    try store.clearPending(
                        saves: [(name: record.recordName, zone: record.zone, sentModifiedAt: record.modifiedAt)], deletes: [])
                case .dropped:
                    try store.dropPending(recordName: record.recordName, zone: record.zone)
                case .stopped(let refusal):
                    return FlushStop(refusal: refusal, zone: record.zone)
                }
            } else if let delete = batch.deletes.first {
                switch await deletePlain(delete.name, zone: delete.zone) {
                case .sent:
                    try store.clearPending(saves: [], deletes: [(name: delete.name, zone: delete.zone)])
                case .dropped:
                    try store.dropPending(recordName: delete.name, zone: delete.zone)
                case .stopped(let refusal):
                    return FlushStop(refusal: refusal, zone: delete.zone)
                }
            } else {
                return nil
            }
        }
    }

    private enum PlainResult {
        case sent, dropped
        case stopped(TransportRefusal)
    }

    private func sendPlain(_ record: CloudRecord) async -> PlainResult {
        do {
            var save = Relay_V1_Save()
            save.items = [try await saveItem(record, expect: .none)]
            energy?.record(.sendBatch)
            let result = try await call(record.zone) { try await self.client.save(save) }
            guard Self.saveOutcomes(result, items: [record]) != nil, result.conflicts.isEmpty else {
                Self.logger.error("relay flush: malformed save answer")
                return .stopped(.transient(code: "malformed_answer"))
            }
            return .sent
        } catch {
            return plainFailure(error)
        }
    }

    private func deletePlain(_ name: String, zone: CloudZoneID) async -> PlainResult {
        guard zone == .relay else { return .dropped }
        do {
            var delete = Relay_V1_Delete()
            delete.zone = zoneName(zone)
            var item = Relay_V1_DeleteItem()
            item.name = name
            delete.items = [item]
            energy?.record(.sendBatch)
            _ = try await call(zone) { try await self.client.delete(delete) }
            return .sent
        } catch {
            return plainFailure(error)
        }
    }

    private func plainFailure(_ error: any Error) -> PlainResult {
        if error is AssetMissing {
            Self.logger.error("relay flush: a queued record's asset file is gone, dropped")
            return .dropped
        }
        let refusal = Self.refusal(for: error)
        guard refusal.isPermanent else { return .stopped(refusal) }
        Self.logger.error("relay flush: a queued write refused for good, dropped: \(String(describing: refusal), privacy: .public)")
        return .dropped
    }

    // MARK: - ConditionalTransport

    /// Phase 1's contract: one outcome per item in order; a call-level failure is `.refused` for
    /// every item; throws only for local errors. A `.data` item is refused before any request.
    public func save(_ items: [ConditionalSave]) async throws -> [SaveOutcome] {
        var outcomes: [SaveOutcome?] = items.map { $0.record.zone == .relay ? nil : .refused(.permanent(code: "forbidden")) }
        let sending = outcomes.indices.filter { outcomes[$0] == nil }
        guard !sending.isEmpty else { return outcomes.compactMap { $0 } }
        if let refusal = try await beforeDirectWrite() {
            for index in sending { outcomes[index] = .refused(refusal) }
            return outcomes.compactMap { $0 }
        }
        do {
            var save = Relay_V1_Save()
            for index in sending { save.items.append(try await saveItem(items[index].record, expect: items[index].expect)) }
            energy?.record(.sendBatch)
            let result = try await call(.relay) { try await self.client.save(save) }
            if let answered = Self.saveOutcomes(result, items: sending.map { items[$0].record }) {
                for (position, index) in sending.enumerated() { outcomes[index] = answered[position] }
            } else {
                Self.logger.error("relay save: malformed answer for \(sending.count) items")
                for index in sending { outcomes[index] = .refused(.transient(code: "malformed_answer")) }
                await reread(.relay)
            }
        } catch let error as AssetMissing {
            throw error
        } catch {
            let refusal = Self.refusal(for: error)
            for index in sending { outcomes[index] = .refused(refusal) }
            await reread(.relay)
        }
        return outcomes.compactMap { $0 }
    }

    /// `.absent` has no relay form (R6) and `.data` is read only: both are refused before any request.
    public func delete(_ items: [ConditionalDelete]) async throws -> [DeleteOutcome] {
        var outcomes: [DeleteOutcome?] = items.map { item in
            if item.expect == .absent { return .refused(.permanent(code: "unsupported_precondition")) }
            return item.zone == .relay ? nil : .refused(.permanent(code: "forbidden"))
        }
        let sending = outcomes.indices.filter { outcomes[$0] == nil }
        guard !sending.isEmpty else { return outcomes.compactMap { $0 } }
        if let refusal = try await beforeDirectWrite() {
            for index in sending { outcomes[index] = .refused(refusal) }
            return outcomes.compactMap { $0 }
        }
        var delete = Relay_V1_Delete()
        delete.zone = mailboxZone
        delete.items = sending.map { index in
            var item = Relay_V1_DeleteItem()
            item.name = items[index].recordName
            if case .seq(let seq) = items[index].expect { item.expectedSeq = seq }
            return item
        }
        do {
            energy?.record(.sendBatch)
            let result = try await call(.relay) { try await self.client.delete(delete) }
            if let answered = Self.deleteOutcomes(result, zones: sending.map { items[$0].zone }) {
                for (position, index) in sending.enumerated() { outcomes[index] = answered[position] }
            } else {
                Self.logger.error("relay delete: malformed answer for \(sending.count) items")
                for index in sending { outcomes[index] = .refused(.transient(code: "malformed_answer")) }
                await reread(.relay)
            }
        } catch {
            let refusal = Self.refusal(for: error)
            for index in sending { outcomes[index] = .refused(refusal) }
            await reread(.relay)
        }
        return outcomes.compactMap { $0 }
    }

    /// What every direct write does first: answer for a stopped or held transport, then flush
    /// the plain queue (R8). Returns the refusal for every item when nothing may be sent.
    private func beforeDirectWrite() async throws -> TransportRefusal? {
        if let refusal = held() { return refusal }
        guard let stop = try await flush() else { return nil }
        await reread(stop.zone)
        return stop.refusal
    }

    /// The outcomes of a save answer for `items`, by index; nil when the answer does not cover
    /// the request exactly (an index out of range or repeated, too few or too many saved, a saved
    /// record under another item's name). A conflict without a live `current` is
    /// `.permanent(code: "gone")` (R6).
    static func saveOutcomes(_ result: Relay_V1_SaveResult, items: [CloudRecord]) -> [SaveOutcome]? {
        guard let conflicts = conflictsByIndex(result.conflicts.map { (Int($0.index), $0) }, count: items.count),
              conflicts.count + result.saved.count == items.count
        else { return nil }
        var saved = result.saved.makeIterator()
        var outcomes: [SaveOutcome] = []
        for item in items.indices {
            if let conflict = conflicts[item] {
                guard conflict.hasCurrent, !conflict.current.deleted else {
                    outcomes.append(.refused(.permanent(code: "gone")))
                    continue
                }
                outcomes.append(.conflict(current: cloudRecord(conflict.current, zone: items[item].zone)))
                continue
            }
            guard let record = saved.next(), record.name == items[item].recordName else { return nil }
            outcomes.append(.saved(recordSeq: record.recordSeq))
        }
        return outcomes
    }

    /// The outcomes of a delete answer by index; nil for an index out of range or repeated. A
    /// conflict without a live `current` is `.deleted` (an absent record counts as deleted).
    static func deleteOutcomes(_ result: Relay_V1_DeleteResult, zones: [CloudZoneID]) -> [DeleteOutcome]? {
        guard let conflicts = conflictsByIndex(result.conflicts.map { (Int($0.index), $0) }, count: zones.count) else {
            return nil
        }
        return zones.indices.map { index in
            guard let conflict = conflicts[index], conflict.hasCurrent, !conflict.current.deleted else { return .deleted }
            return .conflict(current: cloudRecord(conflict.current, zone: zones[index]))
        }
    }

    private static func conflictsByIndex<C>(_ conflicts: [(Int, C)], count: Int) -> [Int: C]? {
        var byIndex: [Int: C] = [:]
        for (index, conflict) in conflicts {
            guard index < count, byIndex[index] == nil else { return nil }
            byIndex[index] = conflict
        }
        return byIndex
    }

    /// One wire item: the record's attachment uploaded first, its envelope as is.
    private func saveItem(_ record: CloudRecord, expect: WriteExpectation) async throws -> Relay_V1_SaveItem {
        var item = Relay_V1_SaveItem()
        var attachment = ""
        if let file = record.assetFileURL {
            attachment = try await upload(file, zone: record.zone)
            noteOwnAttachment(attachment, of: record)
        }
        item.record.zone = zoneName(record.zone)
        item.record.name = record.recordName
        item.record.envelope = record.payload
        item.record.clientModifiedAtMs = Int64((record.modifiedAt.timeIntervalSince1970 * 1000).rounded())
        item.record.attachmentID = attachment
        switch expect {
        case .none: break
        case .absent: item.mustNotExist = true
        case .seq(let seq): item.expectedSeq = seq
        }
        return item
    }

    /// Ledgers an upload as this device's own, so its pull never downloads it back (#1469).
    /// Best-effort: a failed write only costs that one download later.
    private func noteOwnAttachment(_ attachmentID: String, of record: CloudRecord) {
        do {
            try store.noteRelayOwnAttachment(attachmentID, name: record.recordName, zone: record.zone)
        } catch {
            Self.logger.error("relay upload: own attachment not ledgered, \(Self.kind(record.zone), privacy: .public)")
        }
    }
}
