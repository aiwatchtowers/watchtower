import Foundation
import Observation

/// Waits until `condition` holds, re-checking it on every change of the observable state it reads
/// (`withObservationTracking`). No deadline: the wait ends on the event, never on a clock, and a wait that
/// never ends is a hang the lane watchdog reports. `condition` must read the `@Observable` state it waits
/// on; a condition that reads only plain state (a fake's counter, a row in the database) is never
/// re-checked — such a wait needs the fake's own signal instead.
@MainActor
public func untilObserved(_ condition: @escaping @MainActor () -> Bool) async {
    let once = ResumeOnce()
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        once.continuation = continuation
        recheck(condition, once)
    }
}

@MainActor
private func recheck(_ condition: @escaping @MainActor () -> Bool, _ once: ResumeOnce) {
    guard once.continuation != nil else { return }
    let met = withObservationTracking(condition) {
        Task { @MainActor in recheck(condition, once) }
    }
    if met { once.resume() }
}

@MainActor
private final class ResumeOnce {
    var continuation: CheckedContinuation<Void, Never>?

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
