import AppKit
import WatchtowerCore

struct ArtifactActionOutcome: Equatable {
    var copied = false
    var opened = false
}

/// The only place an `ArtifactAction` becomes an effect: a pasteboard write
/// and/or opening an allowlisted URL. Nothing here sends (CHAT-05).
enum ArtifactActionPerformer {
    @discardableResult
    static func perform(
        _ action: ArtifactAction,
        pasteboard: NSPasteboard = .general,
        open: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) -> ArtifactActionOutcome {
        var outcome = ArtifactActionOutcome()
        switch action {
        case .copy(let text):
            outcome.copied = copy(text, to: pasteboard)
        case .open(let url):
            outcome.opened = openIfAllowed(url, open)
        case let .copyThenOpen(text, url):
            outcome.copied = copy(text, to: pasteboard)
            if let url { outcome.opened = openIfAllowed(url, open) }
        }
        return outcome
    }

    private static func copy(_ text: String, to pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    private static func openIfAllowed(_ url: URL, _ open: (URL) -> Bool) -> Bool {
        guard AllowedURLSchemes.permits(url) else { return false }
        return open(url)
    }
}

/// Export via NSSavePanel — the owner picks the destination, which is the
/// consent; no TCC prompt.
@MainActor
enum ArtifactExporter {
    static func export(_ draft: ArtifactDraft, onError: @escaping (String) -> Void) {
        let file = ArtifactActions.exportFile(for: draft)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.name
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try file.contents.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                onError("Export failed: \(error.localizedDescription)")
            }
        }
    }
}
