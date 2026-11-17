#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WatchtowerDesign

/// The Mac's layout of the shared composer (the look it had before the composer moved into ChatUI).
enum ComposerMetrics {
    /// The gap between the composer's lines.
    static let stack: CGFloat = 4
    /// The composer's own padding (none: each line insets itself).
    static let padding: CGFloat = 0
    /// The state line, the notices, the status line and the long-paste offer.
    static let inset: CGFloat = Spacing.large
    /// The quote batch.
    static let quoteInset: CGFloat = 16
    /// The input row and the chips row.
    static let rowInset: CGFloat = 12
    static let rowVertical: CGFloat = 8
    static let rowSpacing: CGFloat = 6
    /// The attachment chips.
    static let chipsInset: CGFloat = Spacing.medium
    /// The composer's notice shows as the status line's error above the field; nothing shows under it.
    static let noticeAsStatus = true
    /// The routing accessory sits under the field.
    static let accessoryAboveField = false
}

enum ComposerPlatform {
    static func isImage(_ data: Data) -> Bool { NSImage(data: data) != nil }

    /// An image or a PDF, by the file extension's type.
    static func binaryKind(ofExtension ext: String) -> ComposerAttachmentRules.BinaryKind? {
        guard let type = UTType(filenameExtension: ext) else { return nil }
        if type.conforms(to: .pdf) { return .pdf }
        return type.conforms(to: .image) ? .image : nil
    }
}

/// The paperclip.
struct ComposerAttachButton: View {
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "paperclip")
                .font(.system(size: IconSize.composer))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Attach files")
        .help(help)
        .padding(.bottom, Spacing.compact)
    }
}

/// The open panel behind the paperclip: what it lets the owner pick follows the provider (U1).
enum ComposerFilePanel {
    @MainActor
    static func pick(attach: String?, pdf: String?, _ onAttachFiles: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        let textTypes: [UTType] = [.text, .json, .xml, .yaml, .commaSeparatedText, .sourceCode]
        if attach != nil {
            panel.message = "Attach text files"
            panel.allowedContentTypes = textTypes
        } else if pdf != nil {
            panel.message = "Attach images or text files"
            panel.allowedContentTypes = [.image] + textTypes
        } else {
            panel.message = "Attach images, PDFs or text files"
        }
        panel.begin { response in
            guard response == .OK else { return }
            onAttachFiles(panel.urls)
        }
    }
}

extension View {
    /// Dropped file URLs go to `accept` (false: not taken).
    func composerFileDrop(enabled: Bool, accept: @escaping ([URL]) -> Bool) -> some View {
        dropDestination(for: URL.self) { urls, _ in accept(urls) }
    }
}
#endif
