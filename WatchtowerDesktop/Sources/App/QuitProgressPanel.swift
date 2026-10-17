import AppKit

/// A small floating panel with a spinner for a quit step that may take a
/// moment (board #588: the deferred session deletes waiting out a busy
/// database). It appears only when the step runs longer than `delay`, so a
/// quick quit shows nothing, and it closes when the step ends.
@MainActor
enum QuitProgressPanel {
    static func showing(
        _ message: String,
        after delay: Duration = .milliseconds(500),
        _ work: () async -> Void
    ) async {
        let reveal = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            let panel = makePanel(message)
            panel.orderFrontRegardless()
            // Stays up until the step ends (the cancel wakes the sleep).
            try? await Task.sleep(for: .seconds(3600))
            panel.close()
        }
        await work()
        reveal.cancel()
        await reveal.value
    }

    private static func makePanel(_ message: String) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 64),
            styleMask: [.titled, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Watchtower"
        panel.level = .floating
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
        return panel
    }
}
