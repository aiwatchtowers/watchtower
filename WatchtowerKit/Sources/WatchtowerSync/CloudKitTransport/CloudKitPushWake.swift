import CloudKit
import Foundation

/// Saves and deletes CloudKit subscriptions; the live one is the private `CKDatabase`, a fake in tests.
public protocol SubscriptionSaving: Sendable {
    func save(_ subscription: CKSubscription) async throws
    func delete(id: CKSubscription.ID) async throws
}

/// The live saver: one container's private database.
public struct CloudKitSubscriptionSaver: SubscriptionSaving {
    public let containerID: String

    public init(containerID: String = WatchtowerCloud.containerID) {
        self.containerID = containerID
    }

    private var database: CKDatabase { CKContainer(identifier: containerID).privateCloudDatabase }

    public func save(_ subscription: CKSubscription) async throws {
        _ = try await database.save(subscription)
    }

    public func delete(id: CKSubscription.ID) async throws {
        do {
            _ = try await database.deleteSubscription(withID: id)
        } catch let error as CKError where error.code == .unknownItem {
            // Already gone: what was asked for.
        }
    }
}

/// `PushWake` over CloudKit: the `WatchtowerSignal` query subscription, database-notification origins and the
/// notification extension's record fetch.
public struct CloudKitPushWake: PushWake {
    private let containerID: String
    private let saver: (any SubscriptionSaving)?

    /// `saver` nil means `CloudKitSubscriptionSaver(containerID:)`, built only when a subscribe/unsubscribe runs.
    public init(containerID: String = WatchtowerCloud.containerID, saver: (any SubscriptionSaving)? = nil) {
        self.containerID = containerID
        self.saver = saver
    }

    private var activeSaver: any SubscriptionSaving {
        saver ?? CloudKitSubscriptionSaver(containerID: containerID)
    }

    public func subscribeAlerts(hubID: String, route: HubRoute) async throws -> Bool {
        guard case .cloudKit(let scope) = route else { throw UnsupportedRouteError(route: route) }
        guard let subscription = AskAlertSubscription.subscription(for: scope, hubID: hubID) else { return false }
        try await activeSaver.save(subscription)
        return true
    }

    public func unsubscribeAlerts(hubID: String, route: HubRoute) async throws {
        guard case .cloudKit(let scope) = route else { throw UnsupportedRouteError(route: route) }
        if AskAlertSubscription.subscription(for: scope, hubID: hubID) != nil {
            try await activeSaver.delete(id: AskAlertSubscription.subscriptionID(hubID: hubID))
        }
    }

    public func origin(ofRemoteNotification userInfo: [AnyHashable: Any]) -> PushOrigin? {
        let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKDatabaseNotification
        switch notification?.databaseScope {
        case .private: return .private
        case .shared: return .shared
        default: return nil
        }
    }

    public func alertSource(for userInfo: [AnyHashable: Any]) -> AlertSource? {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKQueryNotification,
              notification.databaseScope == .private,
              let signalID = notification.recordID,
              let reference = AskAlertSubscription.alertReference(forSignal: signalID)
        else { return nil }
        return .fetchRecord(AlertRecordRef(
            hubID: reference.hubID, wireName: reference.alertID.recordName,
            zoneName: reference.alertID.zoneID.zoneName, ownerName: reference.alertID.zoneID.ownerName))
    }

    public func envelope(for source: AlertSource, timeout: TimeInterval) async throws -> Data? {
        switch source {
        case .inline(_, let envelope):
            return envelope
        case .fetchRecord(let ref):
            let id = CKRecord.ID(
                recordName: ref.wireName, zoneID: CKRecordZone.ID(zoneName: ref.zoneName, ownerName: ref.ownerName))
            let configuration = CKOperation.Configuration()
            configuration.timeoutIntervalForRequest = timeout
            configuration.timeoutIntervalForResource = timeout
            let record = try await CKContainer(identifier: containerID).privateCloudDatabase
                .configuredWith(configuration: configuration) { database in try await database.record(for: id) }
            return AskAlertSubscription.envelope(of: record)
        }
    }

    /// A code, never key or payload bytes.
    public static func errorCode(_ error: any Error) -> String? {
        guard let error = error as? CKError else { return nil }
        return "CKError \(error.code.rawValue)"
    }
}
