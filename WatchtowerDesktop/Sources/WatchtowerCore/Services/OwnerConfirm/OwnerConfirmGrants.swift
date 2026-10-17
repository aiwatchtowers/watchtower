import Foundation

/// The commands this Desktop started itself (AGENT-07, board #568): the one
/// launch path (`ProcessCLIRunner`) registers each child's exact argv before
/// it starts it, and `OwnerConfirmServer` answers an owner-only gesture whose
/// argv is registered at once, without a window — the owner already pressed
/// the button that ran it. An entry is used once and lives `lifetime`
/// seconds; a CLI the Desktop did not start (an agent's shell, a Terminal)
/// matches none and gets the confirmation window.
package final class OwnerConfirmGrants: @unchecked Sendable {
    package static let shared = OwnerConfirmGrants()
    /// Long enough for a child to reach its gate on a loaded machine.
    package static let lifetime: TimeInterval = 60

    private let lock = NSLock()
    private var entries: [(args: [String], expires: Date)] = []
    private let now: @Sendable () -> Date

    package init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    package func register(_ args: [String]) {
        lock.lock()
        defer { lock.unlock() }
        let at = now()
        entries.removeAll { $0.expires <= at }
        entries.append((args, at.addingTimeInterval(Self.lifetime)))
    }

    /// True, removing the entry, when `args` is a live registered launch.
    package func consume(_ args: [String]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let at = now()
        entries.removeAll { $0.expires <= at }
        guard let index = entries.firstIndex(where: { $0.args == args }) else { return false }
        entries.remove(at: index)
        return true
    }
}
