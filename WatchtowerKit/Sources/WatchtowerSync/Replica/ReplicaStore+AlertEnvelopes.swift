import Foundation
import GRDB

// MARK: - Stored work alerts (shared-scope local alerts, ask #622)

/// One stored `ask_alert` envelope: the hub's wire name and the sealed bytes, as CloudKit delivered them.
public struct StoredAlertEnvelope: Equatable, Sendable {
    public let wireName: String
    public let envelope: Data
}

extension ReplicaStore {
    /// Every alert-class envelope the replica holds, ordered by wire name, unopened. A shared-scope phone has no
    /// query subscription (D14), so after a fetch it opens these itself with `AlertOpener` (the `K_alert` material is
    /// readable after the first unlock): the class is read from the plaintext header, so a row still waiting for
    /// the data keys (`kind` unset while the phone is locked) is listed as well. A row whose header does not parse
    /// is left out; the replica's own indexing reports it.
    public func alertEnvelopes() throws -> [StoredAlertEnvelope] {
        let rows = try writer.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT record_name, payload FROM slice_records
                    WHERE kind = ? OR kind IS NULL ORDER BY record_name
                    """,
                arguments: [SliceKind.askAlert.rawValue]
            )
        }
        return rows.compactMap { row in
            let envelope: Data = row["payload"]
            guard (try? Envelope.parse(envelope).header.envelopeClass) == .alert else { return nil }
            return StoredAlertEnvelope(wireName: row["record_name"], envelope: envelope)
        }
    }
}
