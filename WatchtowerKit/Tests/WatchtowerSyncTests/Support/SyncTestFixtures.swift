import Foundation
import GRDB
import WatchtowerSync

/// Test-only slice row: the sync core is model-free, so replica tests decode
/// into this minimal record. `id` is required (a payload without it fails to
/// decode, like a real mirror's required column); `text` is optional.
struct ProbeRow: FetchableRecord, Equatable {
    let id: Int
    let text: String?

    init(id: Int, text: String?) {
        self.id = id
        self.text = text
    }

    init(row: Row) throws {
        guard let id: Int = row["id"] else {
            throw RowDecodingError.missingID
        }
        self.id = id
        self.text = row["text"]
    }

    enum RowDecodingError: Error {
        case missingID
    }
}

/// Heartbeat payloads for tests that only care about `updatedAt`.
enum HeartbeatFixtures {
    static func minimal(updatedAt: Date) -> HeartbeatPayload {
        HeartbeatPayload(
            updatedAt: updatedAt,
            appVersion: "1.0.0",
            hubID: "hub-1",
            macName: "Acme Mac",
            flavor: .default,
            lastPublishAt: nil,
            lastRelayAt: nil,
            relayBacklog: 0,
            accounts: [],
            enabledAt: updatedAt,
            ownerUser: "_owner",
            sharing: .none
        )
    }
}
