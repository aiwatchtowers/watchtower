import Foundation
import WatchtowerCore

/// Counts `restartLogging()` calls instead of touching the real daemon — the
/// account view models' `DaemonRestarting` seam.
package final class FakeDaemonRestarter: DaemonRestarting, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    package init() {}

    package var restartCount: Int {
        lock.withLock { calls }
    }

    package func restartLogging() async {
        lock.withLock { calls += 1 }
    }
}
