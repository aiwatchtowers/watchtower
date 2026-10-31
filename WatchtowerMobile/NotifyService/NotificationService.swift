import os
import UserNotifications
import WatchtowerSync

/// Notification Service Extension (mobile POC spec §2.1, mobile E2E spec §2.6). A private-scope phone's
/// `WatchtowerSignal` query subscription (`AskAlertSubscription`, D14) pushes "A session is waiting" with mutable
/// content; this extension fetches the sealed `ask_alert` the signal names (20 s bound), opens it with
/// `AlertOpener` over the shared alert group's material only, and sets the title and body. Any failure delivers the
/// content-free notification unchanged. Thin glue: fetch → open → `WorkAlertContent` → copy its fields; any failure leaves the generic body.
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
        guard let source = CloudKitPushWake().alertSource(for: request.content.userInfo) else {
            deliver(nil)
            return
        }
        let content = request.content
        work = Task { [weak self] in
            let filled = await Self.fill(content, source: source)
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
        _ content: UNNotificationContent, source: AlertSource
    ) async -> UNNotificationContent? {
        do {
            guard let group = Bundle.main.object(forInfoDictionaryKey: "WTKeychainAlertGroup") as? String, !group.isEmpty,
                  let material = try KeychainPhoneKeyStore.alertMaterial(
                      source.hubID, backend: SecItemKeychainBackend(), alertGroup: group)
            else {
                logger.notice("ask alert not filled: no alert material for its hub")
                return nil
            }
            guard let envelope = try await CloudKitPushWake().envelope(for: source, timeout: fetchTimeout),
                  let payload = AlertOpener(material: material).open(wireName: source.wireName, envelope: envelope)
            else { return nil }
            let filled = content.mutableCopy() as? UNMutableNotificationContent ?? UNMutableNotificationContent()
            let fields = WorkAlertContent(payload: payload, hubID: source.hubID)
            filled.title = fields.title
            filled.body = fields.body
            filled.threadIdentifier = fields.threadID
            filled.userInfo = content.userInfo.merging(fields.userInfo) { _, new in new }
            return filled
        } catch {
            logger.notice("ask alert not filled: \(errorCode(error), privacy: .public)")
            return nil
        }
    }

    /// A code, never key or payload bytes.
    private static func errorCode(_ error: Error) -> String {
        if let code = CloudKitPushWake.errorCode(error) { return code }
        switch error {
        case KeyStoreError.corrupt: return "corrupt"
        case let error as KeyStoreError: return String(describing: error)
        default: return "unexpected"
        }
    }
}
