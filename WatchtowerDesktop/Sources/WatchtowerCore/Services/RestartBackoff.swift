import Foundation

/// The pause before a failed observation starts again (board #526): it
/// doubles after each failure in a row, up to `max`, and is back to `first`
/// once the observation delivers again — a database that keeps failing is
/// not hammered, and one blip costs a short pause.
package struct RestartBackoff: Equatable {
    package static let standardFirst: Duration = .seconds(2)
    package static let standardMax: Duration = .seconds(60)

    package let first: Duration
    package let max: Duration
    package private(set) var next: Duration

    package init(first: Duration = RestartBackoff.standardFirst, max: Duration = RestartBackoff.standardMax) {
        self.first = first
        self.max = Swift.max(first, max)
        next = first
    }

    /// A failure: the pause to wait now.
    package mutating func failed() -> Duration {
        let pause = next
        next = Swift.min(next * 2, max)
        return pause
    }

    /// The observation delivered: the next failure pauses `first` again.
    package mutating func succeeded() {
        next = first
    }
}
