import Foundation

/// Active review time: counts only while the window is key and the owner
/// interacted within `idleSeconds`; one tick gap never counts more than `tickCap`.
package struct ReviewPace: Equatable, Sendable {
    package enum Limits {
        package static let idleSeconds = 120.0
        package static let tickCap = 15.0
        package static let breakHintSeconds = 3600
    }

    package private(set) var activeSeconds: Int
    private var remainder = 0.0
    private var lastTick: Date?
    private var lastInteraction: Date?

    package init(activeSeconds: Int) {
        self.activeSeconds = activeSeconds
    }

    package mutating func noteInteraction(at date: Date) {
        lastInteraction = date
    }

    package mutating func tick(at date: Date, isKey: Bool) {
        defer { lastTick = date }
        guard isKey, let last = lastTick, let interaction = lastInteraction,
              date.timeIntervalSince(interaction) <= Limits.idleSeconds else { return }
        let gap = min(max(date.timeIntervalSince(last), 0), Limits.tickCap)
        let total = remainder + gap
        let whole = total.rounded(.down)
        activeSeconds += Int(whole)
        remainder = total - whole
    }

    package var breakHintDue: Bool { activeSeconds >= Limits.breakHintSeconds }
}
