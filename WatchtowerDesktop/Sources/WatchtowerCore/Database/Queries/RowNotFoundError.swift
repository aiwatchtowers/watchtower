import Foundation
import GRDB

/// An owner edit addressed a row that no longer exists — deleted in another
/// process (the daemon, the CLI, the agent, a second window) after the screen
/// loaded it. The `UPDATE … WHERE id = ?` touched nothing, so the writer
/// throws instead of reporting a success that never happened. The
/// non-target twin of `TargetNotFoundError`.
package struct RowNotFoundError: LocalizedError, Equatable {
    /// What the row is, as the owner calls it: "track", "idea", "chat".
    package let kind: String
    /// Text, not a number: calendar ids are strings.
    package let id: String

    package init(kind: String, id: some CustomStringConvertible) {
        self.kind = kind
        self.id = id.description
    }

    package var errorDescription: String? {
        "\(kind) #\(id) no longer exists (it may have been deleted elsewhere)"
    }
}

extension Database {
    /// Call right after a single-row `UPDATE … WHERE id = ?`, before any
    /// follow-up statement: `changesCount` reflects only the most recent
    /// statement (trigger writes excluded) and counts a matched row even when
    /// its values are unchanged, so 0 means the row is gone.
    package func requireUpdated(_ kind: String, id: some CustomStringConvertible) throws {
        try requireUpdated(orThrow: RowNotFoundError(kind: kind, id: id))
    }

    /// The same check with a domain error the screens already handle
    /// (e.g. `TerminalSessionQueryError.notFound`).
    package func requireUpdated(orThrow error: @autoclosure () -> Error) throws {
        guard changesCount > 0 else { throw error() }
    }
}
