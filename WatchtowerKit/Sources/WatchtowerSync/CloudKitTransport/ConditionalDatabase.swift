import CloudKit

/// The CloudKit calls conditional mailbox writes make (`CloudKitTransport`'s `ConditionalTransport`): saves
/// and deletes outside `CKSyncEngine`, one result per record, and the fetch of one record whose current copy the
/// local buffer no longer holds. Tests replace it; the live one is the scope's `CKDatabase`.
protocol ConditionalDatabase: Sendable {
    func modify(saving: [CKRecord], deleting: [CKRecord.ID]) async throws -> (
        saves: [CKRecord.ID: Result<CKRecord, Error>],
        deletes: [CKRecord.ID: Result<Void, Error>]
    )

    /// The server's current copy of `id`; nil when the server has no such record.
    func fetchRecord(_ id: CKRecord.ID) async throws -> CKRecord?
}

extension CKDatabase: ConditionalDatabase {
    /// `.ifServerRecordUnchanged`: a save carrying a change tag lands only over that version, a fresh record
    /// only where none exists (the server refuses either with `serverRecordChanged`). Not atomic: every record
    /// gets its own result. The policy binds saves only; a delete is unconditional.
    func modify(saving: [CKRecord], deleting: [CKRecord.ID]) async throws -> (
        saves: [CKRecord.ID: Result<CKRecord, Error>],
        deletes: [CKRecord.ID: Result<Void, Error>]
    ) {
        let results = try await modifyRecords(
            saving: saving, deleting: deleting, savePolicy: .ifServerRecordUnchanged, atomically: false)
        return (results.saveResults, results.deleteResults)
    }

    func fetchRecord(_ id: CKRecord.ID) async throws -> CKRecord? {
        do {
            return try await record(for: id)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }
}
