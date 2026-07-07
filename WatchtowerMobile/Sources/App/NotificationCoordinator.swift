import Foundation
import Observation
import os
import UserNotifications
import WatchtowerKit

/// Notification authorization as the app remembers it — drives the Settings
/// row and the "ask once, remember a decline" rule (Plan 6 Decision 5).
enum NotificationPermission: String {
    case notAsked
    case authorized
    case denied
}

/// Seam over exactly the UNUserNotificationCenter calls the coordinator
/// makes, so the alert logic is unit-testable with a fake center — the real
/// center prompts the OS and cannot be scripted from a test host.
protocol NotificationCentering: Sendable {
    func requestAuthorization() async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
    func authorizationStatus() async -> UNAuthorizationStatus
}

/// Production adapter over `UNUserNotificationCenter.current()`.
struct SystemNotificationCenter: NotificationCentering {
    func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    func add(_ request: UNNotificationRequest) async throws {
        try await UNUserNotificationCenter.current().add(request)
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}

/// Raises LOCAL notifications for freshly-hydrated slice rows the desktop
/// tagged with a notifyLevel (Decision 4: the AI already prioritized on the
/// Mac — the phone never re-derives importance). Consumes the hydrator's
/// `onRecordsApplied` hook via AppEnvironment.
///
/// Storm suppression (BINDING): alerts are deduped by a single high-water
/// `modifiedAt` watermark in replica_meta (`ReplicaStore.lastAlertedWatermark`),
/// and an EMPTY watermark means "never alerted" — the first applied batch
/// then arms the watermark WITHOUT alerting, because a new install's initial
/// hydrate is historical cloud records that still carry their tags. The
/// first hydrate is history, not news.
///
/// Watermark shape — one high-water Date, not a per-record map: hydration
/// batches are monotonic (store token guard + hydrateOnce coalescing) and
/// modifiedAt is stamped by the single desktop publisher's clock, so
/// "newer than everything already seen" is exactly "news". A per-record map
/// would grow without bound for no additional correctness. Consequences,
/// both intended: a re-publish of the same row with a newer modifiedAt
/// re-alerts (the desktop only republishes on content change — an urgent
/// item that changed IS news), and a hypothetical out-of-order record at or
/// below the watermark is silently skipped (a missed alert, never a storm —
/// the row still lands in the app).
@MainActor
@Observable
final class NotificationCoordinator {
    private let store: ReplicaStore
    private let center: any NotificationCentering
    private let defaults: UserDefaults
    /// The in-flight permission ask, if any — overlapping batches await it
    /// instead of double-prompting. nil result = transient request failure
    /// (not recorded; a later alertable row may ask again).
    private var askTask: Task<Bool?, Never>?

    /// Current permission as remembered/observed; the Settings row renders it.
    private(set) var permission: NotificationPermission

    /// UserDefaults slot remembering that we asked and what came back —
    /// a decline must survive relaunches (never re-ask).
    static let permissionDefaultsKey = "notify.permission"

    private static let logger = Logger(subsystem: "WatchtowerMobile", category: "NotificationCoordinator")

    init(
        store: ReplicaStore,
        center: any NotificationCentering = SystemNotificationCenter(),
        defaults: UserDefaults = .standard
    ) {
        self.store = store
        self.center = center
        self.defaults = defaults
        permission = defaults.string(forKey: Self.permissionDefaultsKey)
            .flatMap(NotificationPermission.init(rawValue:)) ?? .notAsked
    }

    // MARK: - Hook consumer

    /// Entry point wired to `ReplicaHydrator.onRecordsApplied`: dedup against
    /// the watermark, then (permission allowing) raise one local alert per
    /// genuinely fresh tagged row.
    func recordsApplied(_ records: [AppliedSliceRecord]) async {
        let fresh: [AppliedSliceRecord]
        do {
            fresh = try dedup(records)
        } catch {
            // ids-only logging; failing closed (no alert) is the safe side.
            Self.logger.error("alert dedup failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard !fresh.isEmpty, await ensureAuthorized() else { return }
        for record in fresh {
            await post(record)
        }
    }

    /// Watermark read-advance-filter. Synchronous on purpose: no await
    /// between the read and the write, so overlapping `recordsApplied` calls
    /// cannot interleave here and fresh-sets of successive batches are
    /// disjoint by construction.
    private func dedup(_ records: [AppliedSliceRecord]) throws -> [AppliedSliceRecord] {
        guard let newest = records.map(\.modifiedAt).max() else { return [] }
        guard let watermark = try store.lastAlertedWatermark() else {
            // Never alerted before → this is the initial hydrate. Swallow the
            // whole batch and arm the watermark; only rows the desktop
            // publishes after this moment can alert. (See the type doc.)
            try store.setLastAlertedWatermark(newest)
            return []
        }
        let fresh = records.filter { $0.modifiedAt > watermark && $0.isAlertable }
        if newest > watermark {
            // Advance BEFORE posting: a crash between advance and post costs
            // one missed alert, never a repeat — the storm-safe direction.
            try store.setLastAlertedWatermark(newest)
        }
        return fresh
    }

    // MARK: - Permission (Decision 5: contextual, once, decline remembered)

    private func ensureAuthorized() async -> Bool {
        switch permission {
        case .authorized: return true
        case .denied: return false
        case .notAsked: return await askOnce()
        }
    }

    /// The one-time contextual ask, triggered by the FIRST alertable row
    /// after initial-hydrate suppression — never on cold launch. The outcome
    /// is persisted; a transient request error records nothing (may re-ask).
    private func askOnce() async -> Bool {
        if let askTask {
            return await askTask.value ?? false
        }
        let task = Task { [center] () -> Bool? in
            do {
                return try await center.requestAuthorization()
            } catch {
                Self.logger.warning("authorization request failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        askTask = task
        defer { askTask = nil }
        guard let granted = await task.value else { return false }
        setPermission(granted ? .authorized : .denied)
        return granted
    }

    /// Re-reads the system authorization — the user can flip it in iOS
    /// Settings behind the app's back. Never prompts; a never-asked state
    /// stays untouched (`.notDetermined` cannot regress an answer we have,
    /// and querying before the first ask would be pointless).
    func refreshPermission() async {
        guard permission != .notAsked else { return }
        switch await center.authorizationStatus() {
        case .denied:
            setPermission(.denied)
        case .notDetermined:
            // Permission was reset (e.g. app data reset) — allow a future
            // contextual re-ask instead of pretending we still know.
            setPermission(.notAsked)
        default:
            setPermission(.authorized)
        }
    }

    private func setPermission(_ new: NotificationPermission) {
        permission = new
        defaults.set(new.rawValue, forKey: Self.permissionDefaultsKey)
    }

    // MARK: - Posting

    /// PII rule: the notification BODY may carry the user's own snippet (it
    /// is their lock screen — the spec intends it); the LOG line never does.
    private func post(_ record: AppliedSliceRecord) async {
        guard let content = content(for: record) else { return }
        let request = UNNotificationRequest(
            identifier: "\(record.recordName)@\(record.modifiedAt.timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
        } catch {
            Self.logger.warning(
                "failed to post alert for \(record.recordName, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func content(for record: AppliedSliceRecord) -> UNNotificationContent? {
        let content = UNMutableNotificationContent()
        switch record.notifyLevel {
        case "urgent":
            content.title = "Urgent inbox item"
            content.body = snippet(for: record) ?? "Needs your attention."
        case "briefing":
            content.title = "Your briefing is ready"
        default:
            // Unreachable via recordsApplied (isAlertable filtered) — belt
            // for direct callers; unknown future levels must never alert blind.
            return nil
        }
        content.sound = .default
        return content
    }

    /// One store read per urgent alert: the hook payload is identity-only,
    /// so the snippet is fetched back from the replica by recordName.
    private func snippet(for record: AppliedSliceRecord) -> String? {
        guard record.kind == .inboxItem else { return nil }
        let items = (try? store.fetchAll(InboxItem.self, kind: .inboxItem)) ?? []
        let match = items.first { SliceKind.inboxItem.recordName(id: String($0.id)) == record.recordName }
        guard let snippet = match?.snippet, !snippet.isEmpty else { return nil }
        return snippet
    }
}

private extension AppliedSliceRecord {
    /// The two levels this build knows (Decision 3). Anything else — nil or
    /// a future level from a newer desktop — is not alertable here.
    var isAlertable: Bool {
        notifyLevel == "urgent" || notifyLevel == "briefing"
    }
}
