import CloudKit
import Foundation

/// Conditional mailbox writes (relay client Phase 1, spec §3, Ruling 6). They go outside `CKSyncEngine`, never
/// through its `pending` queue, as one `modifyRecords` call with `.ifServerRecordUnchanged`
/// (`ConditionalDatabase`); the engine fetches what they wrote later like any other change.
///
/// The version a `.seq` names is CloudKit's own change tag: `recordSeq` is only the local handle of one stored
/// system-fields archive (`TransportStore.recordVersion`), and the save carries that archive, so the server
/// enforces the tag. Only `.relay` records go this way; slices keep the engine path.
extension CloudKitTransport: ConditionalTransport {
    /// What the local check decided for one item: an answer without a call, or a record to send.
    private enum SavePlan {
        case answer(SaveOutcome)
        /// `overwrite`: a `.none` save's first try, which goes once more over a server copy it collided with.
        case send(CKRecord, overwrite: Bool)
    }

    private enum DeletePlan {
        case answer(DeleteOutcome)
        case send(CKRecord.ID)
    }

    private enum Operation {
        case save(CKRecord)
        case delete(CKRecord.ID)

        var recordID: CKRecord.ID {
            switch self {
            case .save(let record): return record.recordID
            case .delete(let id): return id
            }
        }
    }

    /// One record's result of a modify call: what the server answered, or a refusal of the whole call.
    private enum OperationResult {
        case saved(CKRecord)
        case deleted
        case failed(CKError)
        case refused(TransportRefusal)
    }

    // MARK: - ConditionalTransport

    public func save(_ items: [ConditionalSave]) async throws -> [SaveOutcome] {
        var outcomes = [SaveOutcome?](repeating: nil, count: items.count)
        // Two items of one record go out in separate calls, in order (one call's results are keyed by record).
        var remaining = Array(items.indices)
        while !remaining.isEmpty {
            let (round, later) = Self.splitDuplicates(remaining) { items[$0].record.recordName }
            var outgoing: [(index: Int, record: CKRecord, overwrite: Bool)] = []
            for index in round {
                switch try planSave(items[index]) {
                case .answer(let outcome): outcomes[index] = outcome
                case let .send(record, overwrite): outgoing.append((index, record, overwrite))
                }
            }
            var retries: [(index: Int, record: CKRecord)] = []
            let results = await modify(outgoing.map { .save($0.record) })
            for entry in outgoing {
                let item = items[entry.index]
                switch try settleSave(item, result: results[entry.record.recordID], overwrite: entry.overwrite) {
                case .answer(let outcome): outcomes[entry.index] = outcome
                case .send(let record, _): retries.append((entry.index, record))
                }
            }
            if !retries.isEmpty {
                let retried = await modify(retries.map { .save($0.record) })
                for entry in retries {
                    let item = items[entry.index]
                    guard case .answer(let outcome) = try settleSave(
                        item, result: retried[entry.record.recordID], overwrite: false) else { continue }
                    outcomes[entry.index] = outcome
                }
            }
            remaining = later
        }
        return outcomes.map { $0 ?? .refused(.transient(code: "noResult")) }
    }

    public func delete(_ items: [ConditionalDelete]) async throws -> [DeleteOutcome] {
        var outcomes = [DeleteOutcome?](repeating: nil, count: items.count)
        var remaining = Array(items.indices)
        while !remaining.isEmpty {
            let (round, later) = Self.splitDuplicates(remaining) { items[$0].recordName }
            var outgoing: [(index: Int, id: CKRecord.ID)] = []
            for index in round {
                switch try planDelete(items[index]) {
                case .answer(let outcome): outcomes[index] = outcome
                case .send(let id): outgoing.append((index, id))
                }
            }
            let results = await modify(outgoing.map { .delete($0.id) })
            for entry in outgoing {
                outcomes[entry.index] = try settleDelete(items[entry.index], result: results[entry.id])
            }
            remaining = later
        }
        return outcomes.map { $0 ?? .refused(.transient(code: "noResult")) }
    }

    // MARK: - Local checks

    private func planSave(_ item: ConditionalSave) throws -> SavePlan {
        let record = item.record
        guard record.zone == .relay else { return .answer(.refused(.permanent(code: "notMailbox"))) }
        let zoneID = zones.zoneID(for: .relay)
        switch item.expect {
        case .absent:
            // A fresh record: the server refuses an existing name with `serverRecordChanged`.
            return .send(Self.ckRecord(from: record, in: zoneID, systemFields: nil), overwrite: false)
        case .seq(let expected):
            guard let version = try store.recordVersion(recordName: record.recordName, zone: .relay),
                  version.recordSeq == expected else {
                return .answer(try staleSave(record.recordName))
            }
            let archive = try store.systemFields(recordName: record.recordName, zone: .relay)
            return .send(Self.ckRecord(from: record, in: zoneID, systemFields: archive), overwrite: false)
        case .none:
            let archive = try store.systemFields(recordName: record.recordName, zone: .relay)
            return .send(Self.ckRecord(from: record, in: zoneID, systemFields: archive), overwrite: true)
        }
    }

    /// A `.seq` whose version is not the stored one: the phone already holds a newer version (or none at all).
    /// When the stored handle is newer than the buffered event (this phone's own save, not fetched back yet),
    /// the buffer holds no current copy to hand back: the write waits for the next fetch.
    private func staleSave(_ recordName: String) throws -> SaveOutcome {
        guard let current = try store.latestEvent(recordName: recordName, zone: .relay) else {
            return .refused(.permanent(code: "unknownVersion"))
        }
        if let version = try store.recordVersion(recordName: recordName, zone: .relay),
           current.recordSeq != version.recordSeq {
            return .refused(.transient(code: "staleBuffer"))
        }
        return .conflict(current: current)
    }

    /// CloudKit has no conditional delete (the save policy binds saves only), so a `.seq` is checked against
    /// the stored handle and change tag here and the delete goes out unconditionally (Ruling 6).
    private func planDelete(_ item: ConditionalDelete) throws -> DeletePlan {
        guard item.zone == .relay else { return .answer(.refused(.permanent(code: "notMailbox"))) }
        let id = CKRecord.ID(recordName: item.recordName, zoneID: zones.zoneID(for: .relay))
        switch item.expect {
        case .none:
            return .send(id)
        case .absent:
            if let current = try store.latestEvent(recordName: item.recordName, zone: .relay) {
                return .answer(.conflict(current: current))
            }
            if try store.recordVersion(recordName: item.recordName, zone: .relay) != nil {
                return .answer(.refused(.permanent(code: "unknownVersion")))
            }
            return .answer(.deleted)
        case .seq(let expected):
            guard let version = try store.recordVersion(recordName: item.recordName, zone: .relay),
                  version.recordSeq == expected, version.changeTag != nil else {
                switch try staleSave(item.recordName) {
                case .conflict(let current): return .answer(.conflict(current: current))
                case .refused(let refusal): return .answer(.refused(refusal))
                case .saved: return .answer(.refused(.permanent(code: "unknownVersion")))
                }
            }
            return .send(id)
        }
    }

    // MARK: - Results

    private func settleSave(_ item: ConditionalSave, result: OperationResult?, overwrite: Bool) throws -> SavePlan {
        let name = item.record.recordName
        switch result {
        case .saved(let saved):
            let recordSeq = try store.saveSystemFields(Self.archivedSystemFields(of: saved), recordName: name, zone: .relay)
            return .answer(.saved(recordSeq: recordSeq))
        case .failed(let error) where error.code == .serverRecordChanged:
            guard let server = error.serverRecord else {
                return .answer(.refused(.transient(code: "serverRecordChanged")))
            }
            let archive = Self.archivedSystemFields(of: server)
            let recordSeq = try store.saveSystemFields(archive, recordName: name, zone: .relay)
            if overwrite {
                // Today's direct-save rule for an unconditional write: once more, over the copy it collided with.
                return .send(Self.ckRecord(from: item.record, in: server.recordID.zoneID, systemFields: archive),
                             overwrite: false)
            }
            // Never "my payload wins" here: the caller gets the server's version.
            guard let current = Self.cloudRecord(from: server, zone: .relay) else {
                return .answer(.refused(.transient(code: "serverRecordChanged")))
            }
            return .answer(.conflict(current: Self.cloudRecord(current, recordSeq: recordSeq)))
        case .failed(let error) where error.code == .unknownItem:
            // The record was deleted on the server while this phone held its change tag.
            try store.deleteSystemFields(recordNames: [name], zone: .relay)
            if overwrite {
                return .send(Self.ckRecord(from: item.record, in: zones.zoneID(for: .relay), systemFields: nil),
                             overwrite: false)
            }
            return .answer(.refused(.permanent(code: "gone")))
        case .failed(let error):
            return .answer(.refused(Self.refusal(for: error)))
        case .refused(let refusal):
            return .answer(.refused(refusal))
        case .deleted, nil:
            return .answer(.refused(.transient(code: "noResult")))
        }
    }

    private func settleDelete(_ item: ConditionalDelete, result: OperationResult?) throws -> DeleteOutcome {
        switch result {
        case .deleted:
            try store.deleteSystemFields(recordNames: [item.recordName], zone: .relay)
            return .deleted
        case .failed(let error) where error.code == .unknownItem:
            // The seam's idempotent delete: already gone counts as deleted.
            try store.deleteSystemFields(recordNames: [item.recordName], zone: .relay)
            return .deleted
        case .failed(let error):
            return .refused(Self.refusal(for: error))
        case .refused(let refusal):
            return .refused(refusal)
        case .saved, nil:
            return .refused(.transient(code: "noResult"))
        }
    }

    // MARK: - The call

    /// One modify call for `operations`; a request-level `limitExceeded` splits them in halves and retries each
    /// (as `shrinkBatch` does for the engine), down to a single record, which is then too large on its own.
    private func modify(_ operations: [Operation]) async -> [CKRecord.ID: OperationResult] {
        guard !operations.isEmpty else { return [:] }
        var saving: [CKRecord] = []
        var deleting: [CKRecord.ID] = []
        for operation in operations {
            switch operation {
            case .save(let record): saving.append(record)
            case .delete(let id): deleting.append(id)
            }
        }
        energy?.record(.sendBatch)
        do {
            let (saves, deletes) = try await conditionalDatabase().modify(saving: saving, deleting: deleting)
            var results: [CKRecord.ID: OperationResult] = [:]
            for record in saving {
                results[record.recordID] = Self.operationResult(saves[record.recordID].map { $0.map(OperationResult.saved) })
            }
            for id in deleting {
                results[id] = Self.operationResult(deletes[id].map { $0.map { OperationResult.deleted } })
            }
            return results
        } catch let error as CKError where error.code == .limitExceeded && operations.count > 1 {
            let half = operations.count / 2
            var results = await modify(Array(operations[..<half]))
            results.merge(await modify(Array(operations[half...]))) { _, new in new }
            return results
        } catch let error as CKError where error.code == .partialFailure {
            let perItem = error.partialErrorsByItemID ?? [:]
            var results: [CKRecord.ID: OperationResult] = [:]
            for operation in operations {
                if let itemError = perItem[operation.recordID] as? CKError {
                    results[operation.recordID] = .failed(itemError)
                } else {
                    results[operation.recordID] = .refused(.transient(code: "partialFailure"))
                }
            }
            return results
        } catch {
            let refusal: TransportRefusal
            if let error = error as? CKError {
                refusal = Self.refusal(for: error)
            } else {
                refusal = .transient(code: error is CancellationError ? "cancelled" : "notCloudKit")
            }
            return Dictionary(operations.map { ($0.recordID, OperationResult.refused(refusal)) }) { _, new in new }
        }
    }

    private static func operationResult(_ result: Result<OperationResult, Error>?) -> OperationResult {
        switch result {
        case .success(let value): return value
        case .failure(let error as CKError): return .failed(error)
        case .failure: return .refused(.transient(code: "notCloudKit"))
        case nil: return .refused(.transient(code: "noResult"))
        }
    }

    private func conditionalDatabase() -> any ConditionalDatabase {
        if let conditionalDatabaseStorage { return conditionalDatabaseStorage }
        let database = scope.database(in: CKContainer(identifier: containerID))
        conditionalDatabaseStorage = database
        return database
    }

    /// The first item of each record name, and the rest for a later call.
    private static func splitDuplicates(_ indices: [Int], name: (Int) -> String) -> (round: [Int], later: [Int]) {
        var seen: Set<String> = []
        var round: [Int] = []
        var later: [Int] = []
        for index in indices {
            if seen.insert(name(index)).inserted { round.append(index) } else { later.append(index) }
        }
        return (round, later)
    }

    // MARK: - Error map

    /// A CloudKit error as a refusal. `.permanent` only for true refusals (the zone or the permission is gone,
    /// the record too large alone); everything a retry may clear, and every code not listed, is `.transient`.
    static func refusal(for error: CKError) -> TransportRefusal {
        switch error.code {
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .notAuthenticated,
             .accountTemporarilyUnavailable:
            return .unreachable
        case .requestRateLimited, .zoneBusy:
            return .rateLimited(retryAfter: error.retryAfterSeconds)
        case .quotaExceeded:
            return .quotaExceeded
        case .limitExceeded:
            return .permanent(code: "tooLarge")
        default:
            if let name = permanentCodeNames[error.code] { return .permanent(code: name) }
            return .transient(code: transientCodeNames[error.code] ?? "ckError\(error.code.rawValue)")
        }
    }

    private static let permanentCodeNames: [CKError.Code: String] = [
        .zoneNotFound: "zoneNotFound", .userDeletedZone: "userDeletedZone", .permissionFailure: "permissionFailure",
        .invalidArguments: "invalidArguments", .badContainer: "badContainer", .badDatabase: "badDatabase",
        .missingEntitlement: "missingEntitlement"
    ]

    private static let transientCodeNames: [CKError.Code: String] = [
        .operationCancelled: "operationCancelled", .serverResponseLost: "serverResponseLost",
        .partialFailure: "partialFailure", .internalError: "internalError",
        .serverRejectedRequest: "serverRejectedRequest"
    ]
}
