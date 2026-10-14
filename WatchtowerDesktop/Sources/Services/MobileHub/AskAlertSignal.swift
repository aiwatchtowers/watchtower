import Foundation
import WatchtowerSync

/// The ask-alert push trigger under E2E (D14, F12): the alert itself is an envelope sealed under `K_alert`, so a
/// CloudKit subscription can no longer match its kind. Next to each alert the publisher writes a payload-free
/// `WatchtowerSignal` record named `sig-<wire name of the alert>` (kind `WireKind.signal`), which `SecureTransport`
/// passes through unsealed: the private-scope phone's `CKQuerySubscription` fires on it, and a shared-scope phone
/// finds it after its silent-push fetch. It names only the alert's opaque record, never its content. Written when an
/// alert first reaches the zone, deleted with the alert.
enum AskAlertSignal {
    static let prefix = "\(WireKind.signal)-"

    static func signalName(forAlertWireName wireName: String) -> String {
        prefix + wireName
    }

    /// The signal of a sealed alert (`alert.recordName` is its wire name).
    static func record(forSealedAlert alert: CloudRecord) -> CloudRecord {
        CloudRecord(
            recordName: signalName(forAlertWireName: alert.recordName), zone: .data, kind: WireKind.signal,
            modifiedAt: alert.modifiedAt, payload: Data()
        )
    }

    /// The signals to delete with the alerts named `plainNames`, by the alerts' wire names.
    static func signalNames(forDeletedAlerts plainNames: [String], transport: SecureTransport) throws -> [String] {
        try plainNames.map { signalName(forAlertWireName: try transport.wireName(plain: $0, zone: .data)) }
    }
}
