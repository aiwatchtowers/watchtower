import Foundation

/// The Undo batch of the deferred session delete (board #480, spec
/// 2026-10-12-sessions-panel-design §4.2). A deleted session is hidden and
/// its process stopped at once; its DELETE waits until the window ends, so
/// Undo restores the row, its report links and its asks untouched. One
/// batch, one deadline: every delete inside the window joins the batch and
/// restarts it; Undo brings back the whole batch.
package struct PendingSessionDeletes: Equatable, Sendable {
    package struct Entry: Equatable, Sendable {
        package let sessionID: Int64
        /// nil = a standalone terminal.
        package let workbenchID: Int64?
        package let title: String

        package init(sessionID: Int64, workbenchID: Int64?, title: String) {
            self.sessionID = sessionID
            self.workbenchID = workbenchID
            self.title = title
        }
    }

    /// The Undo window, from the batch's last delete.
    package static let window: TimeInterval = 5

    /// The pending deletes, in delete order.
    package private(set) var batch: [Entry] = []
    /// When the batch commits; nil while empty.
    package private(set) var deadline: Date?

    package init() {}

    /// The hidden session ids — every read the owner can see drops them.
    package var ids: Set<Int64> { Set(batch.map(\.sessionID)) }

    /// The toast's text: "Session deleted" / "N sessions deleted"; nil
    /// while nothing is pending.
    package var toastText: String? {
        switch batch.count {
        case 0: nil
        case 1: "Session deleted"
        default: "\(batch.count) sessions deleted"
        }
    }

    /// Joins the batch (a session already in it is not listed twice) and
    /// restarts the window from `now`.
    package mutating func enqueueSessionDelete(_ entry: Entry, now: Date) {
        if !batch.contains(where: { $0.sessionID == entry.sessionID }) { batch.append(entry) }
        deadline = now.addingTimeInterval(Self.window)
    }

    /// Undo: the whole batch back, nothing pending.
    package mutating func restoreBatch() -> [Entry] {
        takeBatch()
    }

    /// The batch to commit once `now` reached the deadline (and clears it);
    /// nil before the deadline or while nothing is pending.
    package mutating func expiredBatch(now: Date) -> [Entry]? {
        guard let deadline, now >= deadline else { return nil }
        return takeBatch()
    }

    /// Commit now, whatever the deadline (quit): the batch, cleared.
    package mutating func takeBatch() -> [Entry] {
        let taken = batch
        batch = []
        deadline = nil
        return taken
    }

    /// The workbench is gone and its delete cascaded the hidden rows:
    /// nothing of it left to commit or restore. The deadline stays for the
    /// rest of the batch; an emptied batch has none.
    package mutating func discardBatch(workbenchID: Int64) {
        batch.removeAll { $0.workbenchID == workbenchID }
        if batch.isEmpty { deadline = nil }
    }
}
