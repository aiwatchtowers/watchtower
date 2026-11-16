import SwiftUI
import UniformTypeIdentifiers
import AppKit
import WatchtowerCore
import ChatUI
import WatchtowerChatText

/// The input row of `ChatComposerBar` — the one text input every chat uses
/// (Enter sends, Shift+Enter newline, Esc stops, dictation, attachments).
struct ChatComposerField: View {
    @Binding var text: String
    let isStreaming: Bool
    let onSend: () -> Void
    var onStop: (() -> Void)?
    var placeholder: String = "Ask about your workspace..."
    /// nil → no mic button (the defaulted-member precedent, so no call site breaks).
    var dictationTargetID: String?
    /// Main-chat composer grows to ~40% of the window; Discuss chats keep 120.
    var maxHeight: CGFloat = 120
    var onEscape: (() -> Void)?
    /// ↑ in an empty field (main chat: edit the last message).
    var onArrowUpWhenEmpty: (() -> Void)?
    /// Every attachment param defaults to inert (nil closures, empty array),
    /// so a Discuss chat that never wires attachments renders no paperclip
    /// and accepts no drop/paste — the pre-Task-21 behavior, unchanged.
    var attachments: [ChatAttachment] = []
    var attachmentError: String?
    var onAttachFiles: (([URL]) -> Void)?
    /// A paste that became a file (screenshot, PDF data, long text) with its
    /// name; true once attached (board #534). nil → ⌘V always inserts text.
    var onPasteData: ((Data, String) async -> Bool)?
    var onRemoveAttachment: ((Int64) -> Void)?
    var attachmentProgress = AttachmentProgress()
    /// Why this provider takes no images or PDFs (its capability row, U1):
    /// the paperclip stays and picks text files only, with this help; a
    /// dropped or pasted image or PDF is not added and the reason shows as
    /// a caption. nil = it takes them.
    var attachUnavailableReason: String?
    /// Why this provider takes images but no PDFs: a dropped, pasted or
    /// picked PDF is not added and the reason shows. nil = it takes them.
    var pdfUnavailableReason: String?
    /// Called with the full text and the caret (UTF-16 offset) on every edit
    /// or caret move — the @/ pickers' input. nil for a surface with no
    /// picker (the Discuss-chat default).
    var onCursorChange: ((String, Int) -> Void)?
    /// Offered Up/Down/Enter/Tab/Esc first while a picker may be open;
    /// `consumed == false` falls through to the normal handling (Enter
    /// sends, Esc stops).
    var onPickerKey: ((ComposerPickerKey, String, Int) -> ComposerKeyResult)?
    /// Content outside the text field that is also sent (the main chat's
    /// quote batch): enables Send with an empty field. Defaults to none, so
    /// every other call site is unchanged.
    var hasPendingContent = false
    /// Focus the input when it is created (the ⌘/ popup).
    var autoFocus = false
    /// Each new value puts the keyboard in the field, caret at the end.
    var focusRequest: UUID?
    @Environment(\.dictationCenter) private var dictationCenter

    var body: some View {
        ChatComposerFieldContent(
            text: $text,
            isStreaming: isStreaming,
            onSend: onSend,
            onStop: onStop,
            placeholder: placeholder,
            dictationTargetID: dictationTargetID,
            dictationCenter: dictationCenter,
            maxHeight: maxHeight,
            onEscape: onEscape,
            onArrowUpWhenEmpty: onArrowUpWhenEmpty,
            attachments: attachments,
            attachmentError: attachmentError,
            onAttachFiles: onAttachFiles,
            onPasteData: onPasteData,
            onRemoveAttachment: onRemoveAttachment,
            attachmentProgress: attachmentProgress,
            attachUnavailableReason: attachUnavailableReason,
            pdfUnavailableReason: pdfUnavailableReason,
            onCursorChange: onCursorChange,
            onPickerKey: onPickerKey,
            hasPendingContent: hasPendingContent,
            autoFocus: autoFocus,
            focusRequest: focusRequest
        )
    }
}

/// The input row's actual rendering, split from `ChatComposerField` so it reads no
/// custom `@Environment` — ViewInspector cannot resolve those without a real
/// render pass (the `TrayMenuView`/`TrayMenuContent` precedent); tests drive
/// this view with an explicit center.
struct ChatComposerFieldContent: View {
    @Binding var text: String
    let isStreaming: Bool
    let onSend: () -> Void
    var onStop: (() -> Void)?
    var placeholder: String
    var dictationTargetID: String?
    var dictationCenter: DictationCenter?
    var maxHeight: CGFloat = 120
    var onEscape: (() -> Void)?
    var onArrowUpWhenEmpty: (() -> Void)?
    var attachments: [ChatAttachment] = []
    var attachmentError: String?
    var onAttachFiles: (([URL]) -> Void)?
    var onPasteData: ((Data, String) async -> Bool)?
    var onRemoveAttachment: ((Int64) -> Void)?
    var attachmentProgress = AttachmentProgress()
    /// Why this provider takes no images or PDFs (its capability row, U1):
    /// the paperclip stays and picks text files only, with this help; a
    /// dropped or pasted image or PDF is not added and the reason shows as
    /// a caption. nil = it takes them.
    var attachUnavailableReason: String?
    /// As `ChatComposerField.pdfUnavailableReason`.
    var pdfUnavailableReason: String?
    var onCursorChange: ((String, Int) -> Void)?
    var onPickerKey: ((ComposerPickerKey, String, Int) -> ComposerKeyResult)?
    var hasPendingContent = false
    var autoFocus = false
    var focusRequest: UUID?
    @State private var inputHeight: CGFloat = 22
    /// The text of a long paste the field offers to attach as a file
    /// instead; nil once acted on, or once the field no longer holds it.
    @State private var longPaste: LongPaste?
    /// The U1 reason after a refused drop or paste; cleared on the next
    /// accepted one.
    @State private var refusedNotice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let refusedNotice {
                Text(refusedNotice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Spacing.large)
            }
            if let attachmentError {
                Text(attachmentError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, Spacing.large)
            }
            if attachmentProgress.sendWaits {
                Text("Sending once the files are attached…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Spacing.large)
            }
            if !attachments.isEmpty || !attachmentProgress.isEmpty {
                AttachmentChipsView(attachments: attachments, onRemove: onRemoveAttachment, progress: attachmentProgress)
                    .padding(.horizontal, Spacing.medium)
            }
            if let longPaste, onPasteData != nil {
                LongPasteOffer(characterCount: longPaste.text.count, onAttach: attachLongPaste) { self.longPaste = nil }
                    .padding(.horizontal, Spacing.large)
            }
            row
        }
        .onChange(of: text) {
            if let longPaste, !longPaste.isIntact() { self.longPaste = nil }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let onAttachFiles else { return false }
            let dropped = urls.filter(\.isFileURL)
            let files = dropped.filter { refusal($0) == nil }
            refusedNotice = dropped.lazy.compactMap(refusal).first
            guard !files.isEmpty else { return false }
            onAttachFiles(files)
            return true
        }
    }

    private var row: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if let onAttachFiles {
                Button {
                    pickFiles(onAttachFiles)
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Attach files")
                .help(attachHelp)
                .padding(.bottom, 6)
            }

            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(.placeholder)
                        .padding(.leading, 5)
                        .padding(.top, 4)
                        .allowsHitTesting(false)
                }

                ExpandingTextInput(
                    text: $text,
                    height: $inputHeight,
                    maxHeight: maxHeight,
                    onEscape: onEscape,
                    onArrowUpWhenEmpty: onArrowUpWhenEmpty,
                    onPasteData: pastableData,
                    onAttachFiles: attachableFiles,
                    onLongTextPaste: offerLongPaste,
                    onCursorChange: onCursorChange,
                    onPickerKey: onPickerKey,
                    autoFocus: autoFocus,
                    focusRequest: focusRequest
                ) {
                    guard canSend else { return }
                    onSend()
                }
                .frame(height: inputHeight)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color(.textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(Color(.separatorColor).opacity(0.3), lineWidth: 0.5)
            )
            // "" is a sentinel for a nil dictationTargetID: it never matches a
            // real activeTargetID, so a mic-less input never lights up.
            .dictationHighlight(targetID: dictationTargetID ?? "", center: dictationCenter, cornerRadius: 18)

            if let id = dictationTargetID, let center = dictationCenter {
                DictationButton(text: $text, mode: .chat, targetID: id, center: center)
            }

            Button {
                if isStreaming {
                    onStop?()
                } else {
                    onSend()
                }
            } label: {
                Image(systemName: isStreaming ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(buttonActive ? Color.accentColor : Color(.tertiaryLabelColor))
            }
            .buttonStyle(.borderless)
            .disabled(!buttonActive)
            .accessibilityLabel(isStreaming ? "Stop" : "Send")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// The paperclip's help: what the picker takes, and why not more.
    private var attachHelp: String {
        if let reason = attachUnavailableReason { return "Attach text files. " + reason }
        if let reason = pdfUnavailableReason { return "Attach images or text files. " + reason }
        return "Attach images, PDFs or text files"
    }

    private var refusesSome: Bool { attachUnavailableReason != nil || pdfUnavailableReason != nil }

    private func refusal(_ url: URL) -> String? {
        Self.refusal(of: Self.kind(url), attach: attachUnavailableReason, pdf: pdfUnavailableReason)
    }

    /// onAttachFiles without the files the provider refuses (U1: images and
    /// PDFs; a PDF from an images-only provider): a pasted Finder file of
    /// those kinds is not added, and the reason shows.
    private var attachableFiles: (([URL]) -> Void)? {
        guard let onAttachFiles, refusesSome else { return onAttachFiles }
        return { urls in
            let files = urls.filter { refusal($0) == nil }
            refusedNotice = urls.lazy.compactMap(refusal).first
            if !files.isEmpty { onAttachFiles(files) }
        }
    }

    /// onPasteData refusing the pasted bytes the provider refuses, with the
    /// reason.
    private var pastableData: ((Data, String) async -> Bool)? {
        guard let onPasteData, refusesSome else { return onPasteData }
        return { data, name in
            let byName = Self.kind(URL(fileURLWithPath: name))
            let kind: BinaryKind? = if byName == .pdf || data.starts(with: [0x25, 0x50, 0x44, 0x46]) {
                .pdf
            } else if byName == .image || NSImage(data: data) != nil {
                .image
            } else {
                nil
            }
            if let reason = Self.refusal(of: kind, attach: attachUnavailableReason, pdf: pdfUnavailableReason) {
                refusedNotice = reason
                return false
            }
            refusedNotice = nil
            return await onPasteData(data, name)
        }
    }

    enum BinaryKind { case image, pdf }

    /// An image or a PDF, by the file's type; nil for anything else.
    static func kind(_ url: URL) -> BinaryKind? {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return nil }
        if type.conforms(to: .pdf) { return .pdf }
        return type.conforms(to: .image) ? .image : nil
    }

    /// An image or a PDF, by the file's type.
    static func isBinary(_ url: URL) -> Bool { kind(url) != nil }

    /// Why an attachment of `kind` is refused: a provider with no binary
    /// attachments refuses both kinds (U1), an images-only one refuses
    /// PDFs; nil when it is taken.
    static func refusal(of kind: BinaryKind?, attach: String?, pdf: String?) -> String? {
        switch kind {
        case .image: attach
        case .pdf: attach ?? pdf
        case nil: nil
        }
    }

    private func pickFiles(_ onAttachFiles: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        let textTypes: [UTType] = [.text, .json, .xml, .yaml, .commaSeparatedText, .sourceCode]
        if attachUnavailableReason != nil {
            panel.message = "Attach text files"
            panel.allowedContentTypes = textTypes
        } else if pdfUnavailableReason != nil {
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

    private func offerLongPaste(_ paste: LongPaste) {
        longPaste = paste
    }

    private func attachLongPaste() {
        defer { longPaste = nil }
        guard let longPaste, let onPasteData else { return }
        Task { await longPaste.attach(using: onPasteData) }
    }

    /// A message may carry only attachments, or only pending quotes (no text).
    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty || hasPendingContent
    }

    private var buttonActive: Bool {
        isStreaming ? onStop != nil : canSend
    }
}
