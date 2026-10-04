import Foundation

/// The "Waiting for you" stack of a workbench (spec 2026-10-03 Part 8): its open
/// asks oldest first, how many each session has, and the asks filed from
/// outside the app (no session) as one group. Pure.
package struct OwnerAskStack: Equatable, Sendable {
    /// The asks of one session, or of none (`sessionID` nil).
    package struct SessionGroup: Identifiable, Equatable, Sendable {
        package let sessionID: Int64?
        package let asks: [OwnerAsk]

        package var id: Int64 { sessionID ?? 0 }
        package var isOutsideTheApp: Bool { sessionID == nil }
    }

    package static let outsideTheAppTitle = "Outside the app"

    /// Open asks by `created_at`, then id.
    package let asks: [OwnerAsk]

    /// Keeps only `open` asks, whatever order they come in.
    package init(_ asks: [OwnerAsk]) {
        self.asks = asks.filter(\.isOpen).sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    package var count: Int { asks.count }

    /// Open asks of `sessionID`; nil counts the asks without a session.
    package func count(session sessionID: Int64?) -> Int {
        asks.filter { $0.sessionID == sessionID }.count
    }

    /// The 1-based place of `askID` in the stack; nil once it no longer waits.
    package func askPosition(of askID: Int64) -> Int? {
        asks.firstIndex { $0.id == askID }.map { $0 + 1 }
    }

    /// The ask after `askID` ("k of N ›"), whichever session filed it; past
    /// the last it wraps, and from an ask no longer waiting it is the oldest.
    /// nil when no other ask waits.
    package func next(after askID: Int64) -> OwnerAsk? {
        guard let index = asks.firstIndex(where: { $0.id == askID }) else { return asks.first }
        let next = asks[(index + 1) % asks.count]
        return next.id == askID ? nil : next
    }

    /// The ask a drawer opens on by itself (board #364): the oldest open ask
    /// of the first session on screen that holds an ask the owner has not
    /// closed a drawer on (`dismissed`) — "k of N" walks the rest. An ask
    /// filed outside the app never opens by itself. nil when none.
    package func askToOpen(sessionsOnScreen: Set<Int64>, dismissed: Set<Int64>) -> OwnerAsk? {
        groups.first { group in
            guard let session = group.sessionID, sessionsOnScreen.contains(session) else { return false }
            return group.asks.contains { !dismissed.contains($0.id) }
        }?.asks.first
    }

    /// One group per session in the order of its oldest ask; the asks
    /// without a session last.
    package var groups: [SessionGroup] {
        var order: [Int64] = []
        var bySession: [Int64: [OwnerAsk]] = [:]
        var outside: [OwnerAsk] = []
        for ask in asks {
            guard let session = ask.sessionID else {
                outside.append(ask)
                continue
            }
            if bySession[session] == nil { order.append(session) }
            bySession[session, default: []].append(ask)
        }
        let sessions = order.map { SessionGroup(sessionID: $0, asks: bySession[$0] ?? []) }
        return outside.isEmpty ? sessions : sessions + [SessionGroup(sessionID: nil, asks: outside)]
    }
}
