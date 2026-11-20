import Combine
import Foundation
import WatchtowerCore

/// A file-event source the test fires by hand; `failing` paths refuse to open.
@MainActor
package final class FakeFileEventSource: FileEventSource {
    package var failing: Set<String> = []
    package private(set) var opens: [String] = []
    private var handlers: [String: (id: Int, onEvent: @Sendable (FileEvent) -> Void)] = [:]
    private var nextID = 0

    package init() {}

    package var openPaths: Set<String> { Set(handlers.keys) }

    package func open(_ path: String, onEvent: @escaping @Sendable (FileEvent) -> Void) throws -> any Cancellable {
        if failing.contains(path) { throw POSIXError(.EMFILE) }
        nextID += 1
        let id = nextID
        opens.append(path)
        handlers[path] = (id, onEvent)
        return AnyCancellable { [weak self] in
            MainActor.assumeIsolated {
                if self?.handlers[path]?.id == id { self?.handlers[path] = nil }
            }
        }
    }

    package func fire(_ path: String, _ event: FileEvent = .changed) {
        handlers[path]?.onEvent(event)
    }
}

/// A clock that moves only when the test advances it.
@MainActor
package final class ManualWatchClock: TranscriptWatchClock {
    package private(set) var now: ContinuousClock.Instant = .now
    private var timers: [(id: Int, at: ContinuousClock.Instant, action: @MainActor () -> Void)] = []
    private var nextID = 0

    package init() {}

    package var pendingTimers: Int { timers.count }

    package func schedule(at deadline: ContinuousClock.Instant, _ action: @escaping @MainActor () -> Void) -> any Cancellable {
        nextID += 1
        let id = nextID
        timers.append((id, deadline, action))
        return AnyCancellable { [weak self] in
            MainActor.assumeIsolated { self?.timers.removeAll { $0.id == id } }
        }
    }

    /// Runs every timer due by `now + duration`, in deadline order.
    package func advance(by duration: Duration) {
        let target = now + duration
        while let next = timers.filter({ $0.at <= target }).min(by: { $0.at < $1.at }) {
            timers.removeAll { $0.id == next.id }
            now = max(now, next.at)
            next.action()
        }
        now = target
    }
}
