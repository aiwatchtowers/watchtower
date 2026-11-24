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
    /// Set: the menu `ComposerAttachMenu` opens under this button.
    var anchor: ComposerMenuAnchor?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "paperclip")
                .font(.system(size: IconSize.composer))
                .foregroundStyle(.secondary)
        }
        .background { if let anchor { ComposerMenuAnchorView(anchor: anchor) } }
        .buttonStyle(.borderless)
        .accessibilityLabel("Attach files")
        .help(help)
        .padding(.bottom, Spacing.compact)
    }
}

/// What the paperclip menu may look at on the clipboard (#2201 §4): the advertised types and how many items carry
/// a file URL — never the content, which only the Paste action reads (`PastingTextView.paste(_:)`), so opening the
/// menu cannot trigger the system's paste-privacy prompt.
protocol PasteboardAdvert {
    var advertisedTypes: [String] { get }
    /// Items carrying `public.file-url` (one per Finder file).
    var fileItemCount: Int { get }
}

extension NSPasteboard: PasteboardAdvert {
    var advertisedTypes: [String] { types?.map(\.rawValue) ?? [] }
    var fileItemCount: Int { pasteboardItems?.filter { $0.types.contains(.fileURL) }.count ?? 0 }
}

/// The paperclip menu's paste item (#2201 §4): titled by what the clipboard advertises.
enum ComposerPasteMenu {
    /// The item while the clipboard holds nothing the field takes (disabled).
    static let unavailableTitle = "Paste from clipboard"
    static let attachTitle = "Attach files…"

    /// nil → nothing usable: the item is disabled. `fileCount` is the number of Finder files (0: unknown).
    static func title(for action: PasteAction?, fileCount: Int) -> String? {
        switch action {
        case nil: nil
        case .attachImage: "Paste screenshot"
        case .attachFiles:
            switch fileCount {
            case ...0: "Paste files"
            case 1: "Paste 1 file"
            default: "Paste \(fileCount) files"
            }
        case .attachPDF: "Paste PDF"
        case .insertText: "Paste text"
        }
    }

    /// Types a Finder copy advertises: either one means files, even when the items cannot be counted.
    private static let fileTypes = [NSPasteboard.PasteboardType.fileURL.rawValue, "NSFilenamesPboardType"]

    /// What ⌘V would most likely do, from the advertised types alone; nil when nothing usable is advertised. The
    /// one guess: text beside an image is the image when a URL type is there too (a browser's "Copy Image" puts
    /// the image's link beside it), otherwise the text — `PasteClassifier` decides for real on the paste.
    static func action(advertised: some PasteboardAdvert) -> PasteAction? {
        let types = advertised.advertisedTypes
        if types.contains(where: fileTypes.contains) { return .attachFiles([]) }
        let hasText = types.contains(NSPasteboard.PasteboardType.string.rawValue)
        let hasImage = types.contains(where: PasteClassifier.isImageType)
        let hasLink = types.contains(NSPasteboard.PasteboardType.URL.rawValue)
        if hasText, !(hasImage && hasLink) { return .insertText(offerAsFile: false) }
        if hasImage { return .attachImage }
        if types.contains(PasteClassifier.pdfType) { return .attachPDF }
        return nil
    }
}

/// Where the paperclip's menu opens: the button's own view, set by `ComposerAttachButton`.
final class ComposerMenuAnchor {
    weak var view: NSView?
}

/// The Workchat's paperclip (`ChatComposerFieldConfig.pasteMenu`): "Paste …" and "Attach files…", under the
/// paperclip. The paste item's title comes from the clipboard's advertised types; its action asks the field to
/// paste, which reads the content.
@MainActor
final class ComposerAttachMenu: NSObject {
    let menu = NSMenu()
    private let paste: () -> Void
    private let attach: () -> Void

    init(advertised: some PasteboardAdvert, paste: @escaping () -> Void, attach: @escaping () -> Void) {
        self.paste = paste
        self.attach = attach
        super.init()
        let action = ComposerPasteMenu.action(advertised: advertised)
        let title = ComposerPasteMenu.title(for: action, fileCount: advertised.fileItemCount)
        menu.autoenablesItems = false
        let pasteItem = NSMenuItem(title: title ?? ComposerPasteMenu.unavailableTitle,
                                   action: #selector(pastePicked), keyEquivalent: "v")
        pasteItem.target = self
        pasteItem.isEnabled = title != nil
        menu.addItem(pasteItem)
        let attachItem = NSMenuItem(title: ComposerPasteMenu.attachTitle, action: #selector(attachPicked),
                                    keyEquivalent: "")
        attachItem.target = self
        menu.addItem(attachItem)
    }

    @objc private func pastePicked() { paste() }
    @objc private func attachPicked() { attach() }

    /// Opens under the paperclip (at the mouse when the button's view is gone); returns once it closes.
    static func show(anchor: ComposerMenuAnchor, paste: @escaping () -> Void, attach: @escaping () -> Void) {
        let control = ComposerAttachMenu(advertised: NSPasteboard.general, paste: paste, attach: attach)
        if let view = anchor.view {
            let below = NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY + Spacing.small : -Spacing.small)
            control.menu.popUp(positioning: nil, at: below, in: view)
        } else {
            control.menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }
}

/// Hands the paperclip's view to its `ComposerMenuAnchor`.
private struct ComposerMenuAnchorView: NSViewRepresentable {
    let anchor: ComposerMenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        anchor.view = view
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
