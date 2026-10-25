import Foundation
import Observation

/// The app-wide organization policy (#608). `refresh()` re-reads the managed
/// preferences and publishes only a change; `start` refreshes at once, on
/// every app activation and every 60 s (a managed preference change does not
/// reliably reach a running app). Nothing here writes a setting: a tighter
/// policy only outvotes the owner's stored choices, and removing the profile
/// brings them back (POLICY-03).
@MainActor
@Observable
package final class ManagedPolicyCenter {
    package private(set) var policy: ManagedPolicy = .none

    @ObservationIgnored private let read: () -> [String: Any]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observer: (any NSObjectProtocol)?
    @ObservationIgnored private var observedCenter: NotificationCenter?
    /// Told after a refresh that changed the policy.
    @ObservationIgnored package var onChange: (@MainActor (ManagedPolicy) -> Void)?

    package init(read: @escaping () -> [String: Any]) {
        self.read = read
    }

    package func refresh() {
        let next = ManagedPolicy.normalize(read())
        guard next != policy else { return }
        policy = next
        onChange?(next)
    }

    /// Refreshes now, on each `activation` notification and every `interval`.
    /// `queue` nil delivers the notification on the posting thread (the
    /// main one; tests rely on it being synchronous).
    package func start(
        activation: Notification.Name,
        center: NotificationCenter = .default,
        queue: OperationQueue? = .main,
        interval: TimeInterval = 60
    ) {
        refresh()
        guard timer == nil else { return }
        observedCenter = center
        observer = center.addObserver(forName: activation, object: nil, queue: queue) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    package func stop() {
        timer?.invalidate()
        timer = nil
        if let observer { observedCenter?.removeObserver(observer) }
        observer = nil
        observedCenter = nil
    }
}
