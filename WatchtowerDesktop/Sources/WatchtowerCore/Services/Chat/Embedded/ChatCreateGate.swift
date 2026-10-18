import Foundation

/// A pane's first-use chat creates, one per context at a time (board #670):
/// the create awaits the writer, so the pane may move on to another track or
/// recording meanwhile. Keyed by context, a create still under way for one
/// never blocks the next context's own create, and a second open of the
/// same context while its create waits does nothing.
package struct ChatCreateGate: Equatable {
    package private(set) var keys: Set<String> = []

    package init() {}

    /// False (start nothing) while a create for `key` is under way.
    package mutating func begin(_ key: String) -> Bool {
        keys.insert(key).inserted
    }

    package mutating func end(_ key: String) {
        keys.remove(key)
    }

    package func isCreating(_ key: String) -> Bool {
        keys.contains(key)
    }
}
