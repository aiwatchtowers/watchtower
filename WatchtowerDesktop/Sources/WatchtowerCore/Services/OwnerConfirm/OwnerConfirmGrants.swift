import Foundation

/// The commands this Desktop started itself (AGENT-07, board #568): the one
/// launch path (`ProcessCLIRunner`) registers each child's exact argv and pid
/// right after it starts it, and `OwnerConfirmServer` answers an owner-only
/// gesture from that pid with that argv at once, without a window — the
/// owner already pressed the button that ran it. An entry is used once and
/// lives `lifetime` seconds or until the child exits; any other process (an agent's shell, a Terminal,
/// a copy of the same command) matches none and gets the confirmation window.
package final class OwnerConfirmGrants: @unchecked Sendable {
    package static let shared = OwnerConfirmGrants()
    /// Long enough for a child to reach its gate on a loaded machine.
    package static let lifetime: TimeInterval = 60

    private struct Entry {
        let args: [String]
        let pid: Int32
        let expires: Date
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private let now: @Sendable () -> Date

    package init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    package func register(_ args: [String], pid: Int32) {
        lock.lock()
        defer { lock.unlock() }
        let at = now()
        entries.removeAll { $0.expires <= at }
        entries.append(Entry(args: args, pid: pid, expires: at.addingTimeInterval(Self.lifetime)))
    }

    /// True when `pid` has a live grant (not consumed): the server admits
    /// such a connection past its connection cap.
    package func hasLive(pid: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let at = now()
        return entries.contains { $0.pid == pid && $0.expires > at }
    }

    /// Drops `pid`'s grants once the child exited: a later process reusing
    /// the pid must not inherit them.
    package func revoke(pid: Int32) {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll { $0.pid == pid }
    }

    /// True, removing the entry, when `pid` is a live registered launch of `args`.
    package func consume(_ args: [String], pid: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let at = now()
        entries.removeAll { $0.expires <= at }
        guard let index = entries.firstIndex(where: { $0.pid == pid && $0.args == args }) else { return false }
        entries.remove(at: index)
        return true
    }
}
