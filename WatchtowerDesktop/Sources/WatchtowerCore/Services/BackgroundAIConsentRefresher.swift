import Foundation

/// Re-reads the background AI answer when the app becomes active (#1886,
/// plan Decision 12): an answer given outside the Desktop
/// (`watchtower ai background allow|pause` in a terminal) or a profile change
/// shows once the owner comes back to the app. No file watcher; the
/// Desktop's own allow/pause call re-reads directly.
@MainActor
package final class BackgroundAIConsentRefresher {
    private let center: NotificationCenter
    private let activation: Notification.Name
    private let reload: @MainActor () -> Void
    private var observer: (any NSObjectProtocol)?

    package init(center: NotificationCenter, activation: Notification.Name, reload: @escaping @MainActor () -> Void) {
        self.center = center
        self.activation = activation
        self.reload = reload
    }

    /// Observes `activation`; a second start is a no-op. Delivered on the
    /// posting thread, so a main-thread post re-reads before it returns.
    package func start() {
        guard observer == nil else { return }
        observer = center.addObserver(forName: activation, object: nil, queue: nil) { [weak self] _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.reload() }
            } else {
                Task { @MainActor in self?.reload() }
            }
        }
    }

    package func stop() {
        if let observer { center.removeObserver(observer) }
        observer = nil
    }
}
