#if os(iOS)
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WatchtowerDesign

/// The phone's layout of the shared composer (the look it had before the Mac's composer moved into ChatUI).
enum ComposerMetrics {
    static let stack: CGFloat = Spacing.small
    static let padding: CGFloat = Spacing.medium
    static let inset: CGFloat = 0
    static let quoteInset: CGFloat = 0
    static let rowInset: CGFloat = 0
    static let rowVertical: CGFloat = 0
    static let rowSpacing: CGFloat = Spacing.regular
    static let chipsInset: CGFloat = 0
    /// The gap between the draft's file pills (mockup 2b).
    static let attachmentChipSpacing: CGFloat = Spacing.small
    /// The composer's line (a hold, a refusal, the edit mode) shows under the field.
    static let noticeAsStatus = false
    /// The model and project chips sit over the field.
    static let accessoryAboveField = true
    /// The routing accessory's inset and the gap under its pill.
    static let routingInset: CGFloat = 0
    static let routingBottom: CGFloat = 0
}

enum ComposerPlatform {
    static func isImage(_ data: Data) -> Bool { UIImage(data: data) != nil }

    /// An image or a PDF, by the file extension's type.
    static func binaryKind(ofExtension ext: String) -> ComposerAttachmentRules.BinaryKind? {
        guard let type = UTType(filenameExtension: ext) else { return nil }
        if type.conforms(to: .pdf) { return .pdf }
        return type.conforms(to: .image) ? .image : nil
    }
}

/// The paperclip: opens the shell's attachment menu.
struct ComposerAttachButton: View {
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { Image(systemName: "paperclip") }
            .buttonStyle(.borderless)
            .accessibilityLabel("Attach")
    }
}

/// The phone picks files in its own menu (`onAttach`); there is no open panel.
enum ComposerFilePanel {
    @MainActor
    static func pick(attach: String?, pdf: String?, _ onAttachFiles: @escaping ([URL]) -> Void) {}
}

/// The phone has no long-paste offer: its field inserts every paste as text.
struct LongPasteOffer: View {
    let characterCount: Int
    let onAttach: () -> Void
    let onKeep: () -> Void

    var body: some View { EmptyView() }
}

extension View {
    /// The phone takes no drops into the composer.
    func composerFileDrop(enabled: Bool, accept: @escaping ([URL]) -> Bool) -> some View { self }
}

extension View {
    /// The routing pill's menu: the chip itself is the button.
    func routingPillMenuStyle() -> some View { self }
}
#endif
