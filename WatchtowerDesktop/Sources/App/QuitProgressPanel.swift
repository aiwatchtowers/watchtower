import AppKit

/// A small floating panel with a spinner for a quit step that may take a
/// moment (board #588: the deferred session deletes waiting out a busy
/// database). It appears only when the step runs longer than `delay`, so a
/// quick quit shows nothing, and it closes when the step ends.
@MainActor
enum QuitProgressPanel {
    /// Runs `work`; if it is still running after `delay`, `present` shows
    /// the panel and the closer it returns is called once `work` ends.
    /// `sleep` and `present` are seams for tests.
    static func showing(
        _ message: String,
        after delay: Duration = .milliseconds(500),
        sleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        present: @escaping @MainActor (String) -> () -> Void = Self.present,
        _ work: () async -> Void
    ) async {
        let state = RevealState()
        let reveal = Task { @MainActor in
            await sleep(delay)
            guard !state.done else { return }
            state.close = present(message)
        }
        await work()
        state.done = true
        reveal.cancel()
        state.close?()
        state.close = nil
    }

    @MainActor
    private final class RevealState {
        var done = false
        var close: (() -> Void)?
    }

    /// Puts the panel on screen over every app — it stays up while
    /// Watchtower is inactive or runs as a menu-bar app — and returns its
    /// closer.
    static func present(_ message: String) -> () -> Void {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 64),
            styleMask: [.titled, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Watchtower"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let stack = NSStackView(views: [spinner, NSTextField(labelWithString: message)])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        panel.contentView = stack
        panel.center()
        panel.orderFrontRegardless()
        return { panel.close() }
    }
}
