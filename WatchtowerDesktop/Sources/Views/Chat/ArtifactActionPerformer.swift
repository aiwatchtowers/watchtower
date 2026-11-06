import AppKit
import os
import UniformTypeIdentifiers
import WatchtowerCore

/// Print… and the exports' failures (the panel shows a notice too).
let artifactExportLog = Logger(subsystem: Constants.bundleID, category: "artifact-export")

struct ArtifactActionOutcome: Equatable {
    var copied = false
    var opened = false
}

/// The only place a `ChatArtifactAction` becomes an effect: a pasteboard write
/// and/or opening an allowlisted URL. Nothing here sends (CHAT-05).
enum ArtifactActionPerformer {
    @discardableResult
    static func perform(
        _ action: ChatArtifactAction,
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
                artifactExportLog.error("Export failed: \(error.localizedDescription, privacy: .private)")
                onError("Export failed: \(error.localizedDescription)")
            }
        }
    }

    /// Export as Word: the document rendered (`ArtifactPrint.documentPage`,
    /// which has nothing that loads), read by AppKit's HTML importer into an
    /// attributed string and written as Office Open XML.
    static func exportWord(_ draft: ArtifactDraft, onError: @escaping (String) -> Void) {
        guard ArtifactPrint.canExportWord(draft) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ArtifactPrint.wordFileName(for: draft)
        panel.allowedContentTypes = [UTType(filenameExtension: "docx") ?? .data]
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try wordData(markdown: draft.content, title: draft.title).write(to: url, options: .atomic)
            } catch {
                artifactExportLog.error("Export as Word failed: \(error.localizedDescription, privacy: .private)")
                onError("Export failed: \(error.localizedDescription)")
            }
        }
    }

    static func wordData(markdown: String, title: String) throws -> Data {
        let html = Data(ArtifactPrint.documentPage(markdown: markdown, title: title).utf8)
        let text = try NSAttributedString(
            data: html,
            options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil
        )
        return try text.data(
            from: NSRange(location: 0, length: text.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]
        )
    }
}
