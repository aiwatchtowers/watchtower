import Foundation
import WatchtowerRelayProto
import WatchtowerSync

/// One record saved outside any transport: the relay twin of `CloudKitTransport.saveDirectly`.
extension HostedRelayTransport {
    /// What `saveDirectly` refuses before any request.
    public enum DirectSaveError: Error, Equatable, Sendable {
        /// Only a `.relay` record without an asset goes out this way.
        case notAMailboxRecord
    }

    /// Saves `record` through `client` into the phone's mailbox with the relay Mac `macDeviceID`
    /// (`relay/<mac>/<phone>`), unconditionally: the phone's unlink farewell kept after its hub's
    /// files went (#143). Throws the relay's error; a save the relay did not report saved throws
    /// `HostedRelayError.undecodable(status: 200)`. Only a `.relay` record without an asset.
    public static func saveDirectly(_ record: CloudRecord, client: HostedRelayClient, macDeviceID: String) async throws {
        guard record.zone == .relay, record.assetFileURL == nil else { throw DirectSaveError.notAMailboxRecord }
        var item = Relay_V1_SaveItem()
        item.record.zone = HostedRelayZones.mailbox(mac: macDeviceID, phone: client.deviceID)
        item.record.name = record.recordName
        item.record.envelope = record.payload
        item.record.clientModifiedAtMs = Int64((record.modifiedAt.timeIntervalSince1970 * 1000).rounded())
        var save = Relay_V1_Save()
        save.items = [item]
        let result = try await client.save(save)
        guard result.conflicts.isEmpty, result.saved.map(\.name) == [record.recordName] else {
            logger.error("relay direct save: malformed save answer")
            throw HostedRelayError.undecodable(status: 200)
        }
    }
}
