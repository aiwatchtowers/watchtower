import Foundation

/// Which system default device changed under a running capture.
package enum AudioDeviceChange: String, Sendable {
    case defaultOutput = "default output"
    case defaultInput = "default input"
}

/// The CoreAudio listener seam: reports default-device changes while a
/// recording runs. `startMonitoring`'s handler must be called on the queue
/// the owning `TapReattachController` lives on.
package protocol AudioDeviceChangeMonitoring {
    func startMonitoring(_ handler: @escaping (AudioDeviceChange) -> Void) throws
    func stopMonitoring()
}

/// The timer seam: runs `work` after `delay` on the controller's queue and
/// returns what calls it off.
package protocol ReattachScheduling {
    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> () -> Void
}

/// Re-attaches the system-audio capture when the default output (or input)
/// device changes mid-recording. A process tap and the aggregate device built
/// around it are bound to the devices present when they were created; after
/// headphones are plugged in or a Bluetooth headset connects, the tap stops
/// delivering the call and the transcript quietly loses the other side
/// (`CallAudioWatch` only warns about it). The controller rebuilds instead.
///
/// The state machine only: the actual rebuild is the `rebuild` closure (the
/// recorder's make-before-break swap, which keeps the old capture running
/// when the new one cannot be built), the listener and the timer are seams,
/// so every path is testable without audio hardware.
///
/// - A burst of changes (a Bluetooth headset switches output, then input,
///   within a second) is debounced into ONE rebuild, `debounce` after the
///   last change.
/// - A failed rebuild is retried `maxRetries` times, `retryDelay` apart (a
///   headset can be listed a moment before it accepts IO); after that the
///   controller waits for the next device change. Nothing here ever fails
///   the recording.
/// - Changes before `start()` or after `stop()` do nothing, and `stop()`
///   cancels a pending rebuild, so a rebuild never runs after the recording
///   stopped.
///
/// Not thread-safe by design: every call (including the monitor's and the
/// scheduler's callbacks) happens on one serial queue the recorder owns.
package final class TapReattachController {
    package enum State: Equatable, Sendable {
        /// Not started yet.
        case idle
        /// Monitoring; the last rebuild (if any) succeeded.
        case attached
        /// A device changed; a rebuild is scheduled.
        case pending
        /// Rebuilding failed after every retry; still monitoring for the
        /// next change. The capture keeps whatever it had (at least the mic).
        case detached
        /// Stopped for good.
        case stopped
    }

    static let debounce: TimeInterval = 1
    static let retryDelay: TimeInterval = 2
    static let maxRetries = 2

    private let monitor: AudioDeviceChangeMonitoring
    private let scheduler: ReattachScheduling
    private let rebuild: () throws -> Void
    private let log: (String) -> Void

    private(set) var state: State = .idle
    /// Successful rebuilds so far (for the log line).
    private(set) var reattachCount = 0
    private var cancelPending: (() -> Void)?
    /// The changes collected since the last rebuild, for the log line.
    private var pendingTriggers: [AudioDeviceChange] = []

    package init(
        monitor: AudioDeviceChangeMonitoring,
        scheduler: ReattachScheduling,
        rebuild: @escaping () throws -> Void,
        log: @escaping (String) -> Void
    ) {
        self.monitor = monitor
        self.scheduler = scheduler
        self.rebuild = rebuild
        self.log = log
    }

    /// Starts listening. Throws when the listener cannot be installed — the
    /// recording itself is unaffected; it just will not re-attach.
    package func start() throws {
        try monitor.startMonitoring { [weak self] change in
            self?.deviceChanged(change)
        }
        state = .attached
    }

    /// Stops listening and drops a pending rebuild. Idempotent.
    package func stop() {
        guard state != .stopped else { return }
        let wasMonitoring = state != .idle
        cancelPending?()
        cancelPending = nil
        pendingTriggers = []
        state = .stopped
        if wasMonitoring {
            monitor.stopMonitoring()
        }
    }

    private func deviceChanged(_ change: AudioDeviceChange) {
        guard state != .stopped else { return }
        if !pendingTriggers.contains(change) {
            pendingTriggers.append(change)
        }
        state = .pending
        // A new change restarts the debounce and the retry budget: the device
        // set moved again, so the previous attempt's verdict no longer holds.
        schedule(after: Self.debounce, attempt: 0)
    }

    private func schedule(after delay: TimeInterval, attempt: Int) {
        cancelPending?()
        cancelPending = scheduler.schedule(after: delay) { [weak self] in
            self?.runRebuild(attempt: attempt)
        }
    }

    private func runRebuild(attempt: Int) {
        cancelPending = nil
        guard state == .pending else { return }
        let triggers = pendingTriggers.map(\.rawValue).joined(separator: " + ")
        do {
            try rebuild()
            // A stop that landed during the rebuild wins.
            guard state == .pending else { return }
            reattachCount += 1
            pendingTriggers = []
            state = .attached
            log("re-attached system audio after \(triggers) change (re-attach #\(reattachCount))")
        } catch {
            guard state == .pending else { return }
            if attempt < Self.maxRetries {
                log("re-attaching system audio after \(triggers) change failed, retrying "
                    + "(\(attempt + 1)/\(Self.maxRetries)): \(error.localizedDescription)")
                schedule(after: Self.retryDelay, attempt: attempt + 1)
            } else {
                pendingTriggers = []
                state = .detached
                log("re-attaching system audio after \(triggers) change failed, giving up until the "
                    + "next device change: \(error.localizedDescription)")
            }
        }
    }
}

/// `ReattachScheduling` on a `DispatchQueue`.
package struct DispatchReattachScheduler: ReattachScheduling {
    private let queue: DispatchQueue

    package init(queue: DispatchQueue) {
        self.queue = queue
    }

    package func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> () -> Void {
        let item = DispatchWorkItem(block: work)
        queue.asyncAfter(deadline: .now() + delay, execute: item)
        return item.cancel
    }
}
