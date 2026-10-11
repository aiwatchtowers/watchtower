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
        // An app bundle is a directory the resolver ignores; the native
        // installer's ~/.local/bin is hidden from a default panel.
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = true
        let localBin = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/bin")
        if FileManager.default.fileExists(atPath: localBin.path) { panel.directoryURL = localBin }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}
