import Foundation
import os
import UserNotifications
import WatchtowerSync

/// Adds one local notification: the live one is the current notification center, a fake in tests.
struct LocalAlertPosting {
    var post: @MainActor (UNNotificationRequest) async throws -> Void

    static let live = Self { try await UNUserNotificationCenter.current().add($0) }
}

/// Work alerts for a shared-scope hub (a phone on another Apple ID, ask #622). Apple allows no query subscription
/// in the shared database (D14), so nothing pushes an alert there; the sync engine's silent push only fetches. After
/// each fetch the session hands this the replica's stored `ask_alert` envelopes (`ReplicaStore.alertEnvelopes`):
/// each one not yet seen is opened with `AlertOpener` over the hub's alert material (the extension's key, readable
/// after the first unlock, so a locked phone opens it too) and posted as a local notification with the extension's
/// fields (`WorkAlertContent`), so a tap routes and the settled-alert sweep removes it like a pushed one. Best-effort:
/// only while iOS lets the app fetch.
///
/// What was seen is kept per hub in `defaults` (wire name → alert key), so a relaunch never posts again; an entry
/// whose record left the replica (the Mac deleted the settled alert) is dropped. With the switch off nothing is
/// posted, and what arrived meanwhile counts as seen: turning it on alerts from then on, as the private scope's
/// subscription does.
@MainActor
final class SharedAlertPoster {
    private static let logger = Logger(subsystem: "WatchtowerMobile", category: "SharedAlerts")

    private let hubID: String
    private let store: ReplicaStore
    private let keys: any PhoneKeyStore
    private let defaults: UserDefaults
    private let posting: LocalAlertPosting

    init(hubID: String, store: ReplicaStore, keys: any PhoneKeyStore, defaults: UserDefaults, posting: LocalAlertPosting) {
        self.hubID = hubID
        self.store = store
        self.keys = keys
        self.defaults = defaults
        self.posting = posting
    }

    /// Stable per alert: a repeat replaces instead of adding a second.
    static func identifier(hubID: String, key: String) -> String {
        "work-alert-\(hubID)-\(key)"
    }

    static func postedDefaultsKey(hubID: String) -> String {
        "hub.\(hubID).sharedAlerts.seen"
    }

    /// Opens and posts the alerts not seen yet. The seen list is read, updated and saved before the first post, with
    /// no suspension between, so two fetches ending together never post one alert twice.
    func postNew(enabled: Bool) async {
        let requests = collect(enabled: enabled)
        for request in requests {
            do {
                try await posting.post(request)
            } catch {
                Self.logger.error("shared alert not posted: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func collect(enabled: Bool) -> [UNNotificationRequest] {
        let stored: [StoredAlertEnvelope]
        do {
            stored = try store.alertEnvelopes()
        } catch {
            Self.logger.error("shared alerts not read: \(error.localizedDescription, privacy: .public)")
            return []
        }
        let key = Self.postedDefaultsKey(hubID: hubID)
        let present = Set(stored.map(\.wireName))
        var seen = (defaults.dictionary(forKey: key) as? [String: String] ?? [:]).filter { present.contains($0.key) }
        let fresh = stored.filter { seen[$0.wireName] == nil }
        var requests: [UNNotificationRequest] = []
        if !fresh.isEmpty, let opener = opener() {
            for row in fresh {
                // `AlertOpener.open` logs why (a code only); the row is tried again on the next fetch.
                guard let payload = opener.open(wireName: row.wireName, envelope: row.envelope) else {
                    Self.logger.notice("shared alert skipped: it does not open")
                    continue
                }
                let shown = seen.values.contains(payload.key)
                seen[row.wireName] = payload.key
                if enabled, !shown { requests.append(request(payload)) }
            }
        }
        defaults.set(seen, forKey: key)
        return requests
    }

    private func opener() -> AlertOpener? {
        do {
            guard let material = try keys.alertMaterial(hubID) else {
                Self.logger.notice("shared alerts not opened: no alert material for the hub")
                return nil
            }
            return AlertOpener(material: material)
        } catch {
            Self.logger.notice("shared alerts not opened: alert material unreadable")
            return nil
        }
    }

    private func request(_ payload: WorkAlertPayload) -> UNNotificationRequest {
        let fields = WorkAlertContent(payload: payload, hubID: hubID)
        let content = UNMutableNotificationContent()
        content.title = fields.title
        content.body = fields.body
        content.threadIdentifier = fields.threadID
        content.userInfo = fields.userInfo
        return UNNotificationRequest(
            identifier: Self.identifier(hubID: hubID, key: payload.key), content: content, trigger: nil)
    }
}
