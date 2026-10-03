import Foundation

/// A place in a workbench file: 1-based line, 1-based UTF-16 column (the
/// Go↔Swift and page convention).
package struct CodeNavLocation: Equatable, Hashable, Sendable {
    /// Relative to the workbench folder.
    package let path: String
    package let line: Int
    package let col: Int

    package init(path: String, line: Int, col: Int) {
        self.path = path
        self.line = line
        self.col = col
    }
}

/// The Files pane's back/forward stack (spec §8.2): a jump (go to
/// definition) records where it left from; back returns there and keeps
/// the place it left for forward. A jump after back drops the forward side.
/// Each side keeps the latest `cap` places.
package struct CodeNavigationHistory: Equatable, Sendable {
    package static let cap = 100

    /// Oldest first.
    private var backStack: [CodeNavLocation] = []
    /// Nearest last.
    private var forwardStack: [CodeNavLocation] = []

    package init() {}

    package var canGoBack: Bool {
        !backStack.isEmpty
    }

    package var canGoForward: Bool {
        !forwardStack.isEmpty
    }

    /// A jump leaves `origin`.
    package mutating func recordJump(from origin: CodeNavLocation) {
        forwardStack.removeAll()
        if backStack.last != origin { Self.append(origin, to: &backStack) }
    }

    /// Where back goes from `current` (nil = not known: nothing is kept for
    /// forward). An entry equal to `current` is passed over.
    package mutating func goBack(from current: CodeNavLocation?) -> CodeNavLocation? {
        Self.step(from: current, taking: &backStack, keeping: &forwardStack)
    }

    package mutating func goForward(from current: CodeNavLocation?) -> CodeNavLocation? {
        Self.step(from: current, taking: &forwardStack, keeping: &backStack)
    }

    private static func step(
        from current: CodeNavLocation?, taking source: inout [CodeNavLocation], keeping other: inout [CodeNavLocation]
    ) -> CodeNavLocation? {
        while source.last != nil, source.last == current { source.removeLast() }
        guard let target = source.popLast() else { return nil }
        if let current, other.last != current { append(current, to: &other) }
        return target
    }

    private static func append(_ location: CodeNavLocation, to stack: inout [CodeNavLocation]) {
        stack.append(location)
        if stack.count > cap { stack.removeFirst(stack.count - cap) }
    }
}
