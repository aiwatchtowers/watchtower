import CloudKit
import os
import UserNotifications
import WatchtowerSync

/// Notification Service Extension (mobile POC spec §2.1, mobile E2E spec §2.6). A private-scope phone's
/// `WatchtowerSignal` query subscription (`AskAlertSubscription`, D14) pushes "A session is waiting" with mutable
/// content; this extension fetches the sealed `ask_alert` the signal names (20 s bound), opens it with
/// `AlertOpener` over the shared alert group's material only, and sets the title and body. Any failure delivers the
/// content-free notification unchanged. Thin glue: fetch → open → set fields; the rest of A13 is not built.
final class NotificationService: UNNotificationServiceExtension {
    private static let logger = Logger(subsystem: "WatchtowerMobile", category: "NotifyService")
    private static let fetchTimeout: TimeInterval = 20

    private let lock = NSLock()
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var original: UNNotificationContent?
    private var work: Task<Void, Never>?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        lock.withLock {
            self.contentHandler = contentHandler
            original = request.content
        }
        guard let notification = CKNotification(fromRemoteNotificationDictionary: request.content.userInfo)
                as? CKQueryNotification,
              notification.databaseScope == .private,
              let signalID = notification.recordID,
              let reference = AskAlertSubscription.alertReference(forSignal: signalID)
        else {
            deliver(nil)
            return
        }
        let content = request.content
        work = Task { [weak self] in
            let filled = await Self.fill(content, reference: reference)
            self?.deliver(filled)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        work?.cancel()
        deliver(nil)
    }

    /// Exactly once: the filled content, or the notification as it arrived.
    private func deliver(_ filled: UNNotificationContent?) {
        let (handler, content) = lock.withLock {
            defer { contentHandler = nil }
            return (contentHandler, filled ?? original)
        }
        guard let handler, let content else { return }
        handler(content)
    }

    private static func fill(
        _ content: UNNotificationContent, reference: (hubID: String, alertID: CKRecord.ID)
    ) async -> UNNotificationContent? {
        do {
            guard let group = Bundle.main.object(forInfoDictionaryKey: "WTKeychainAlertGroup") as? String, !group.isEmpty,
                  let material = try KeychainPhoneKeyStore.alertMaterial(
                      reference.hubID, backend: SecItemKeychainBackend(), alertGroup: group)
            else {
                logger.notice("ask alert not filled: no alert material for its hub")
                return nil
            }
            let record = try await fetch(reference.alertID)
            guard let envelope = AskAlertSubscription.envelope(of: record),
                  let payload = AlertOpener(material: material).open(wireName: reference.alertID.recordName, envelope: envelope)
            else { return nil }
            let filled = content.mutableCopy() as? UNMutableNotificationContent ?? UNMutableNotificationContent()
            filled.title = payload.workbenchName
            filled.body = payload.title
            return filled
        } catch {
            logger.notice("ask alert not filled: \(errorCode(error), privacy: .public)")
            return nil
        }
    }

    private static func fetch(_ id: CKRecord.ID) async throws -> CKRecord {
        let configuration = CKOperation.Configuration()
        configuration.timeoutIntervalForRequest = fetchTimeout
        configuration.timeoutIntervalForResource = fetchTimeout
        return try await CKContainer(identifier: WatchtowerCloud.containerID).privateCloudDatabase
            .configuredWith(configuration: configuration) { database in try await database.record(for: id) }
    }

    /// A code, never key or payload bytes.
    private static func errorCode(_ error: Error) -> String {
        switch error {
        case let error as CKError: return "CKError \(error.code.rawValue)"
        case KeyStoreError.corrupt: return "corrupt"
        case let error as KeyStoreError: return String(describing: error)
        default: return "unexpected"
        }
    }
}
