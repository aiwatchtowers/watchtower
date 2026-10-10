import AppKit

/// The open panel for the `claude` executable: onboarding's manual-path row
/// and a workbench session's exit-127 bar.
enum ClaudeExecutablePanel {
    @MainActor static func pick() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Select the 'claude' executable"
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}
