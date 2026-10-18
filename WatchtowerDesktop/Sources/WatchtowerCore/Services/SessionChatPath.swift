import Foundation

/// Where the session chat pane is: the main feed (empty stack) or a subagent
/// opened in place, nested ones deeper. Level 0 is the main feed, level n
/// the n-th subagent of the stack.
package struct SessionChatPath: Equatable, Sendable {
    package private(set) var stack: [SessionFeedSubagent] = []

    package init() {}

    package var isRoot: Bool { stack.isEmpty }

    package mutating func push(_ s: SessionFeedSubagent) {
        stack.append(s)
    }

    /// One level up; a no-op at the root.
    package mutating func pop() {
        _ = stack.popLast()
    }

    /// Keeps the first `level` subagents (0 = the main feed). A level at or
    /// beyond the current depth changes nothing.
    package mutating func popTo(level: Int) {
        let keep = max(0, level)
        guard keep < stack.count else { return }
        stack.removeLast(stack.count - keep)
    }
}
