#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WatchtowerChatText
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
    /// The attachment chips, and the gap between them.
    static let chipsInset: CGFloat = Spacing.medium
    static let attachmentChipSpacing: CGFloat = Spacing.compact
    /// The composer's notice shows as the status line's error above the field; nothing shows under it.
    static let noticeAsStatus = true
    /// The routing accessory sits under the field.
    static let accessoryAboveField = false
    /// The routing accessory's inset and the gap under its pill.
    static let routingInset: CGFloat = Spacing.large
    static let routingBottom: CGFloat = Spacing.compact
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

/// The paperclip menu's paste item (#2201 §4): titled by what ⌘V would do with the clipboard now.
enum ComposerPasteMenu {
    /// The item while the clipboard holds nothing the field takes (disabled).
    static let unavailableTitle = "Paste from clipboard"
    static let attachTitle = "Attach files…"

    /// nil → nothing usable: the item is disabled. `fileCount` is the number of Finder files.
    static func title(for action: PasteAction?, fileCount: Int) -> String? {
        switch action {
        case nil: nil
        case .attachImage: "Paste screenshot"
        case .attachFiles: fileCount == 1 ? "Paste 1 file" : "Paste \(fileCount) files"
        case .attachPDF: "Paste PDF"
        case .insertText: "Paste text"
        }
    }

    /// What ⌘V would do with `pasteboard`, nil when it holds nothing usable. Read only when the menu opens (a
    /// click), never polled.
    static func action(in pasteboard: NSPasteboard) -> PasteAction? {
        let action = PastedContent.action(from: pasteboard)
        if case .insertText = action, pasteboard.string(forType: .string)?.isEmpty != false { return nil }
        return action
    }
}

/// The Workchat's paperclip (`ChatComposerFieldConfig.pasteMenu`): "Paste …" and "Attach files…" at the click.
@MainActor
enum ComposerAttachMenu {
    static func show(paste: @escaping () -> Void, attach: @escaping () -> Void) {
        let action = ComposerPasteMenu.action(in: .general)
        var fileCount = 0
        if case .attachFiles(let urls) = action { fileCount = urls.count }
        let title = ComposerPasteMenu.title(for: action, fileCount: fileCount)
        let picker = Picker()
        let menu = NSMenu()
        menu.autoenablesItems = false
        let pasteItem = NSMenuItem(title: title ?? ComposerPasteMenu.unavailableTitle,
                                   action: #selector(Picker.pick(_:)), keyEquivalent: "v")
        pasteItem.target = picker
        pasteItem.isEnabled = title != nil
        pasteItem.tag = Picker.pasteTag
        menu.addItem(pasteItem)
        let attachItem = NSMenuItem(title: ComposerPasteMenu.attachTitle, action: #selector(Picker.pick(_:)),
                                    keyEquivalent: "")
        attachItem.target = picker
        attachItem.tag = Picker.attachTag
        menu.addItem(attachItem)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        switch picker.picked {
        case Picker.pasteTag: paste()
        case Picker.attachTag: attach()
        default: break
        }
    }

    /// The chosen item's tag, read once the menu closes (`popUp` returns after it).
    private final class Picker: NSObject {
        static let pasteTag = 1
        static let attachTag = 2
        var picked: Int?

        @objc func pick(_ sender: NSMenuItem) {
            picked = sender.tag
        }
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

extension View {
    /// The routing pill's menu: the Mac's borderless button, sized to its label.
    func routingPillMenuStyle() -> some View {
        menuStyle(.borderlessButton).fixedSize()
    }
}
#endif
