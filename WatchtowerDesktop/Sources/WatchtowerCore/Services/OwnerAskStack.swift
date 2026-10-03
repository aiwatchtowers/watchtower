import Foundation

/// The "Waiting for you" stack of a workbench (spec 2026-10-03 Part 8): its open
/// asks oldest first, how many each session has, and the asks filed from
/// outside the app (no session) as one group. Pure.
package struct OwnerAskStack: Equatable, Sendable {
    /// The asks of one session, or of none (`sessionID` nil).
    package struct Group: Identifiable, Equatable, Sendable {
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

    /// One group per session in the order of its oldest ask; the asks
    /// without a session last.
    package var groups: [Group] {
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
        let sessions = order.map { Group(sessionID: $0, asks: bySession[$0] ?? []) }
        return outside.isEmpty ? sessions : sessions + [Group(sessionID: nil, asks: outside)]
    }
}
