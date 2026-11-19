import Foundation

/// Yields until `condition` holds, at most `turns` main-actor turns
/// (`Task.yield`): true when it held. Bounded by a count, never by a clock,
/// so a condition that never holds fails its assertion instead of hanging
/// the run (a view's button runs its press in a Task; a fake's write lands a
/// few turns later).
@MainActor
public func settles(turns: Int = 100_000, _ condition: () -> Bool) async -> Bool {
    for _ in 0..<turns where !condition() { await Task.yield() }
    return condition()
}
