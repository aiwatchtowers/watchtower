import CloudKit
import Foundation

/// The ask-alert push trigger per database scope (D14). The hub writes a payload-free `WatchtowerSignal` record
/// `sig-<wire name of the alert>` next to each sealed `ask_alert` (`AskAlertSignal` on the Mac); the notification
/// extension fetches the alert it names and opens it with `AlertOpener`. Registering the subscription, and the
/// shared-scope local notification, are A13's.
public enum AskAlertSubscription {
    /// The content-free text shown when the alert cannot be fetched or opened.
    public static let alertBody = "A session is waiting"

    private static let signalPrefix = "\(WireKind.signal)-"
    private static let dataZonePrefix = "\(CloudZoneID.data.rawValue)-"

    /// One subscription per hub: re-registering replaces it instead of adding a second.
    public static func subscriptionID(hubID: String) -> String {
        "ask-alert-\(hubID)"
    }

    /// `.private`: a `CKQuerySubscription` on `WatchtowerSignal` in the hub's DataZone, firing on creation, with a
    /// mutable-content alert (the extension fills it) and no silent push of its own.
    ///
    /// `.shared`: nil (D14). Apple supports query subscriptions only in the public and private databases, so a
    /// shared-scope phone gets none: the sync engine's own database subscription already sends a silent push that
    /// triggers a fetch, and the app filters `sig-…` records locally after it. Those pushes are best-effort, so a
    /// shared-scope alert can be late.
    public static func subscription(for scope: CloudDatabaseScope, hubID: String) -> CKQuerySubscription? {
        guard scope == .private else { return nil }
        let subscription = CKQuerySubscription(
            recordType: CloudKitTransport.signalRecordType, predicate: NSPredicate(value: true),
            subscriptionID: subscriptionID(hubID: hubID), options: [.firesOnRecordCreation])
        subscription.zoneID = HubZones(scope: scope, hubID: hubID).zoneID(for: .data)
        let info = CKSubscription.NotificationInfo()
        info.alertBody = alertBody
        info.shouldSendContentAvailable = false
        info.shouldSendMutableContent = true
        subscription.notificationInfo = info
        return subscription
    }

    /// The alert a signal record names: the same zone, the name after `sig-`, and the hub of that DataZone.
    /// nil for anything that is not a signal in a hub's DataZone.
    public static func alertReference(forSignal signalID: CKRecord.ID) -> (hubID: String, alertID: CKRecord.ID)? {
        let name = signalID.recordName, zone = signalID.zoneID
        guard name.hasPrefix(signalPrefix), name.count > signalPrefix.count,
              zone.zoneName.hasPrefix(dataZonePrefix), zone.zoneName.count > dataZonePrefix.count
        else { return nil }
        return (
            String(zone.zoneName.dropFirst(dataZonePrefix.count)),
            CKRecord.ID(recordName: String(name.dropFirst(signalPrefix.count)), zoneID: zone)
        )
    }

    /// The sealed envelope of a fetched alert record: a `WatchtowerEnvelope`'s `encryptedValues["payload"]`; nil for
    /// any other record type or a missing payload.
    public static func envelope(of record: CKRecord) -> Data? {
        guard record.recordType == CloudKitTransport.recordType else { return nil }
        return record.encryptedValues["payload"] as? Data
    }
}
