import Foundation

/// Serializes the chat's polls. A refresh requested while one runs is folded
/// into exactly one more run right after it. The runs live in the poller's
/// own task, so a caller that is cancelled (the pane's state changed) never
/// drops the run queued behind it.
@MainActor
package final class SessionFeedPoller {
    private let action: @MainActor () async -> Void
    private var run: Task<Void, Never>?
    private var again = false

    package init(_ action: @escaping @MainActor () async -> Void) {
        self.action = action
    }

    /// Returns once the run that covers this request has finished.
    package func refresh() async {
        if let run {
            again = true
            await run.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                again = false
                await action()
            } while again
            run = nil
        }
        run = task
        await task.value
    }
}
