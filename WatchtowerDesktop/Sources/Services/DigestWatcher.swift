import Foundation
import GRDB

/// The two notification calls `DigestWatcher.poll()` depends on, pulled out
/// as a protocol so tests can inject a spy instead of exercising the real
/// `UNUserNotificationCenter` — which requires a proper app bundle and
/// crashes when it's missing one, e.g. under `swift test`.
protocol DigestWatcherNotifying {
    func sendDecisionNotification(ideaID: Int, title: String)
    func sendBriefingNotification(attentionCount: Int)
}

extension NotificationService: DigestWatcherNotifying {}

@MainActor
@Observable
final class DigestWatcher {
    private var watchTask: Task<Void, Never>?
    private let dbPool: DatabasePool
    private let notificationService: DigestWatcherNotifying
    private var lastCheckedDecisionID: Int
    private var lastCheckedBriefingID: Int

    init(dbPool: DatabasePool, notificationService: DigestWatcherNotifying = NotificationService.shared) {
        self.dbPool = dbPool
        self.notificationService = notificationService
        self.lastCheckedDecisionID = UserDefaults.standard.integer(forKey: "lastCheckedDecisionID")
        self.lastCheckedBriefingID = UserDefaults.standard.integer(forKey: "lastCheckedBriefingID")
    }

    func start() {
        // Initialize lastCheckedDecisionID if first run
        if lastCheckedDecisionID == 0 {
            do {
                let maxID = try dbPool.read { db in
                    try IdeaQueries.maxDecisionID(db)
                }
                lastCheckedDecisionID = maxID
                UserDefaults.standard.set(maxID, forKey: "lastCheckedDecisionID")
            } catch {
                // Will start from 0
            }
        }

        if lastCheckedBriefingID == 0 {
            do {
                let maxID = try dbPool.read { db in
                    try BriefingQueries.maxID(db)
                }
                lastCheckedBriefingID = maxID
                UserDefaults.standard.set(maxID, forKey: "lastCheckedBriefingID")
            } catch {}
        }

        watchTask?.cancel()
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                self.poll()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func stop() {
        watchTask?.cancel()
        watchTask = nil
    }

    func poll() {
        let notifyDecisions = UserDefaults.standard.bool(forKey: "notifyDecisions")
        // notifyDecisions defaults to true — AppStorage default is true, but UserDefaults returns false
        // if the key was never set. Check if key exists; if not, treat as enabled.
        let decisionsEnabled = UserDefaults.standard.object(forKey: "notifyDecisions") == nil || notifyDecisions
        let quietHours = UserDefaults.standard.bool(forKey: "quietHoursEnabled")

        guard !quietHours else { return }

        do {
            let newDecisions = try dbPool.read { db in
                try IdeaQueries.fetchNewDecisionsSince(db, afterID: lastCheckedDecisionID)
            }

            var notificationCount = 0
            for idea in newDecisions {
                if decisionsEnabled && notificationCount < 5 {
                    notificationService.sendDecisionNotification(ideaID: idea.id, title: idea.title)
                    notificationCount += 1
                }
                lastCheckedDecisionID = idea.id
            }

            if lastCheckedDecisionID > 0 {
                UserDefaults.standard.set(lastCheckedDecisionID, forKey: "lastCheckedDecisionID")
            }
        } catch {
            print("[DigestWatcher] decision poll error: \(error.localizedDescription)")
        }

        // Poll for new briefings
        do {
            let newBriefings = try dbPool.read { db in
                try BriefingQueries.fetchNewSince(db, afterID: lastCheckedBriefingID)
            }
            for briefing in newBriefings {
                notificationService.sendBriefingNotification(
                    attentionCount: briefing.parsedAttention.count
                )
                lastCheckedBriefingID = briefing.id
            }
            if lastCheckedBriefingID > 0 {
                UserDefaults.standard.set(lastCheckedBriefingID, forKey: "lastCheckedBriefingID")
            }
        } catch {
            print("[DigestWatcher] briefing poll error: \(error.localizedDescription)")
        }
    }
}
