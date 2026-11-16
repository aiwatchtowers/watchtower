import Foundation

// MARK: - The replica's screen models (mobile Inbox spec §7)

extension HubSession {
    /// The calendar, the chats, the Inbox and the recordings observe the replica for the session's lifetime.
    func startReplicaModels() {
        calendarReplica.start(store: store)
        chats.start(store: store)
        inbox.hubName = { [weak self] in self?.hubName ?? self?.workbenchReplica.snapshot.heartbeat?.macName ?? "" }
        inbox.observe(store: store)
        inbox.start()
        phoneRecordings.start(store: store)
    }
}
