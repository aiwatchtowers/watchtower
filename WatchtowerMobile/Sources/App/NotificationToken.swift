import Foundation

/// One block observer of a `NotificationCenter`, removed when the token goes: an owner drops the token (or lets
/// it go with itself) and the observer is gone, with no `deinit` of its own. `handler` runs on the main queue.
final class NotificationToken {
    private let center: NotificationCenter
    private let token: any NSObjectProtocol

    init(center: NotificationCenter, name: Notification.Name, handler: @escaping @MainActor () -> Void) {
        self.center = center
        token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { handler() }
        }
    }

    deinit {
        center.removeObserver(token)
    }
}
