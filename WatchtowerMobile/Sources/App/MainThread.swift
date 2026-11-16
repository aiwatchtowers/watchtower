import Foundation

/// Runs main-actor work from any thread: at once on the main thread, else on the main queue. For UIKit and
/// UserNotifications completion handlers, which assert they are called on the main thread.
enum MainThread {
    static func run(_ body: @escaping @MainActor () -> Void) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
            return
        }
        MainActor.assumeIsolated { body() }
    }
}
