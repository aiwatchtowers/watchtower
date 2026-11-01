import Foundation
import WatchtowerRelayProto
import WatchtowerSync

/// One record saved outside any transport: the relay twin of `CloudKitTransport.saveDirectly`.
extension HostedRelayTransport {
    /// Why `saveDirectly` did not save.
    public enum DirectSaveError: Error, Equatable, Sendable {
        /// Only a `.relay` record without an asset goes out this way (refused before any request).
        case notAMailboxRecord
        /// The copy changed between the read and the retry (a new link's record): it is kept.
        case refused
    }

    /// Saves `record` through `client` into the phone's mailbox with the relay Mac `macDeviceID`
    /// (`relay/<mac>/<phone>`): the phone's unlink farewell kept after its hub's files went (#143).
    /// A compare-and-swap, as CloudKit's: first `must_not_exist`; on a conflict, once more with
    /// `expected_seq` of the copy it was refused for, so a farewell that lands late never replaces
    /// a relink's record (#261) — that copy's change refuses it (`.refused`). A save cancelled while
    /// the first try ran never tries again. Throws the relay's error; an answer that does not
    /// account for the record throws `HostedRelayError.undecodable(status: 200)`.
    public static func saveDirectly(_ record: CloudRecord, client: HostedRelayClient, macDeviceID: String) async throws {
        try await saveDirectly(record, client: client, macDeviceID: macDeviceID) {}
    }

    /// `beforeRetry` runs between the refused first try and the retry (tests).
    static func saveDirectly(
        _ record: CloudRecord,
        client: HostedRelayClient,
        macDeviceID: String,
        beforeRetry: @Sendable () async throws -> Void
    ) async throws {
        guard record.zone == .relay, record.assetFileURL == nil else { throw DirectSaveError.notAMailboxRecord }
        var item = Relay_V1_SaveItem()
        item.record.zone = HostedRelayZones.mailbox(mac: macDeviceID, phone: client.deviceID)
        item.record.name = record.recordName
        item.record.envelope = record.payload
        item.record.clientModifiedAtMs = Int64((record.modifiedAt.timeIntervalSince1970 * 1000).rounded())
        item.mustNotExist = true
        guard let seen = try await saveOne(item, client: client) else { return }
        try await beforeRetry()
        try Task.checkCancellation()
        item.expectedSeq = seen
        guard try await saveOne(item, client: client) == nil else { throw DirectSaveError.refused }
    }

    /// One conditional save: nil once saved, else the seq of the copy it was refused for.
    private static func saveOne(_ item: Relay_V1_SaveItem, client: HostedRelayClient) async throws -> UInt64? {
        var save = Relay_V1_Save()
        save.items = [item]
        let result = try await client.save(save)
        if result.conflicts.isEmpty, result.saved.map(\.name) == [item.record.name] { return nil }
        if result.saved.isEmpty, result.conflicts.count == 1, let conflict = result.conflicts.first, conflict.index == 0 {
            // A record gone for good (no copy) has nothing to condition on: refused.
            guard conflict.hasCurrent else { throw DirectSaveError.refused }
            return conflict.current.recordSeq
        }
        logger.error("relay direct save: malformed save answer")
        throw HostedRelayError.undecodable(status: 200)
    }
}
