import AppKit
import WatchtowerCore

/// FileVault's state now and on every activation (#1769): a user who turns it
/// on in System Settings comes back to the app. Subscribes first, so an
/// activation during the first probe is not lost. `.unknown` until read.
@MainActor
@Observable
final class FileVaultWatch {
    private(set) var state: FileVaultState = .unknown
    @ObservationIgnored private var task: Task<Void, Never>?

    deinit { task?.cancel() }

    func start(status: FileVaultStatus = .live) {
        task?.cancel()
        task = Task { [weak self] in
            var activations = NotificationCenter.default
                .notifications(named: NSApplication.didBecomeActiveNotification).makeAsyncIterator()
            self?.state = await status.read()
            while await activations.next() != nil {
                guard let self else { return }
                self.state = await status.read()
            }
        }
    }
}
