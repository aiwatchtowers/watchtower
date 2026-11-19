import SwiftUI
import WatchtowerChatText
import WatchtowerDesign

/// How one surface sets up the composer field.
public struct ChatComposerFieldConfig {
    public var placeholder: String
    /// The field grows to this height, then scrolls (the main chat about 40 % of the window, Discuss 120).
    public var maxHeight: CGFloat = 120
    /// The dictation target the field writes into (`"chat.workspace"`, each embedded surface's id); nil: no mic.
    public var dictationTargetID: String?
    /// Why this provider takes no images or PDFs (U1): the paperclip picks text files only, with this help; a
    /// dropped or pasted image or PDF is not added and the reason shows. nil: it takes them.
    public var attachUnavailableReason: String?
    /// Why this provider takes images but no PDFs. nil: it takes them.
    public var pdfUnavailableReason: String?
    /// Content outside the text that is also sent (the quote batch, the Workchat's files): Send is on with an
    /// empty field.
    public var hasPendingContent = false
    /// The field takes the keyboard as it is made (the ⌘/ panel).
    public var autoFocus = false
    /// Each new value puts the keyboard in the field, caret at the end.
    public var focusRequest: UUID?
    /// Send is off whatever the field holds (the chat cannot be reached, or it is gone); the text stays.
    public var sendBlocked = false
    /// The round button is Send whenever there is something to send, even while the agent works (Stop only with
    /// nothing to send): the Workchat, whose agent takes a line mid-turn. false: Stop while streaming (the AI chat).
    public var sendWhileStreaming = false
    /// A pasted image or long text goes into the field as a token (`[Image #1]`, `[Pasted text #2 +42 lines]`,
    /// `ComposerPasteRoute`) through `onInlinePaste`: the Workchat. false: a chip and the "Attach as file" offer
    /// (the AI chat). A dropped or picked file is a chip either way.
    public var inlinePastes = false
    /// The kind of each token number that has a payload (`inlinePastes`): one Backspace removes such a token of that
    /// kind whole.
    public var livePastes: [Int: PasteKind] = [:]

    public init(
        placeholder: String,
        maxHeight: CGFloat = 120,
        dictationTargetID: String? = nil,
        attachUnavailableReason: String? = nil,
        pdfUnavailableReason: String? = nil,
        hasPendingContent: Bool = false,
        autoFocus: Bool = false,
        focusRequest: UUID? = nil,
        sendBlocked: Bool = false,
        sendWhileStreaming: Bool = false,
        inlinePastes: Bool = false,
        livePastes: [Int: PasteKind] = [:]
    ) {
        self.placeholder = placeholder
        self.maxHeight = maxHeight
        self.dictationTargetID = dictationTargetID
        self.attachUnavailableReason = attachUnavailableReason
        self.pdfUnavailableReason = pdfUnavailableReason
        self.hasPendingContent = hasPendingContent
        self.autoFocus = autoFocus
        self.focusRequest = focusRequest
        self.sendBlocked = sendBlocked
        self.sendWhileStreaming = sendWhileStreaming
        self.inlinePastes = inlinePastes
        self.livePastes = livePastes
    }
}

/// The one input row every chat uses, on the Mac and the phone: the attachment notices and chips, the paperclip,
/// the field (the platform's text view), dictation (`ChatComposerServices`) and the round Send/Stop. It holds no
/// model: it edits its binding and calls its closures.
public struct ChatComposerField: View {
    @Binding var text: String
    let isStreaming: Bool
    let config: ChatComposerFieldConfig
    let onSend: () -> Void
    var onStop: (() -> Void)?
    var onEscape: (() -> Void)?
    var onArrowUpWhenEmpty: (() -> Void)?
    var attachments: [ChatComposerAttachment]
    var attachmentProgress: AttachmentProgress
    var attachmentError: String?
    var onAttachFiles: (([URL]) -> Void)?
    var onPasteData: ((Data, String) async -> Bool)?
    /// `inlinePastes`: keeps a pasted image or long text and returns the token to insert at the paste; nil inserts
    /// nothing (the paste was not taken, and the owner's model says why).
    var onInlinePaste: ((InlinePaste) async -> String?)?
    var onRemoveAttachment: ((Int64) -> Void)?
    var onRetryAttachment: ((Int64) -> Void)?
    var onCursorChange: ((String, Int) -> Void)?
    var onPickerKey: ((ComposerPickerKey, String, Int) -> ComposerKeyResult)?
    /// The phone's paperclip: opens its attachment menu (the files come back through the shell, not `onAttachFiles`).
    var onAttachMenu: (() -> Void)?

    @Environment(\.chatUIStyle) private var style
    @Environment(\.chatComposerServices) private var services
    @State private var inputHeight: CGFloat = 22
    /// The text of a long paste the field offers to attach as a file instead; nil once acted on, or once the field
    /// no longer holds it.
    @State private var longPaste: LongPaste?
    /// The U1 reason after a refused drop or paste; cleared on the next accepted one.
    @State private var refusedNotice: String?

    public init(
        text: Binding<String>,
        isStreaming: Bool,
        config: ChatComposerFieldConfig,
        onSend: @escaping () -> Void,
        onStop: (() -> Void)? = nil,
        onEscape: (() -> Void)? = nil,
        onArrowUpWhenEmpty: (() -> Void)? = nil,
        attachments: [ChatComposerAttachment] = [],
        attachmentProgress: AttachmentProgress = .init(),
        attachmentError: String? = nil,
        onAttachFiles: (([URL]) -> Void)? = nil,
        onPasteData: ((Data, String) async -> Bool)? = nil,
        onRemoveAttachment: ((Int64) -> Void)? = nil,
        onRetryAttachment: ((Int64) -> Void)? = nil,
        onCursorChange: ((String, Int) -> Void)? = nil,
        onPickerKey: ((ComposerPickerKey, String, Int) -> ComposerKeyResult)? = nil,
        onInlinePaste: ((InlinePaste) async -> String?)? = nil
    ) {
        _text = text
        self.isStreaming = isStreaming
        self.config = config
        self.onSend = onSend
        self.onStop = onStop
        self.onEscape = onEscape
        self.onArrowUpWhenEmpty = onArrowUpWhenEmpty
        self.attachments = attachments
        self.attachmentProgress = attachmentProgress
        self.attachmentError = attachmentError
        self.onAttachFiles = onAttachFiles
        self.onPasteData = onPasteData
        self.onRemoveAttachment = onRemoveAttachment
        self.onRetryAttachment = onRetryAttachment
        self.onCursorChange = onCursorChange
        self.onPickerKey = onPickerKey
        self.onInlinePaste = onInlinePaste
    }

    /// The same field whose paperclip opens the shell's own attachment menu (the phone).
    func attachMenu(_ action: (() -> Void)?) -> Self {
        var copy = self
        copy.onAttachMenu = action
        return copy
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            if let refusedNotice {
                Text(refusedNotice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, ComposerMetrics.inset)
            }
            if let attachmentError {
                Text(attachmentError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, ComposerMetrics.inset)
            }
            if attachmentProgress.sendWaits {
                Text("Sending once the files are attached…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, ComposerMetrics.inset)
            }
            if !attachments.isEmpty || !attachmentProgress.isEmpty {
                AttachmentChipsView(attachments: attachments, onRemove: onRemoveAttachment, onRetry: onRetryAttachment,
                                    progress: attachmentProgress)
                    .padding(.horizontal, ComposerMetrics.chipsInset)
            }
            if let longPaste, onPasteData != nil {
                LongPasteOffer(characterCount: longPaste.text.count, onAttach: attachLongPaste) { self.longPaste = nil }
                    .padding(.horizontal, ComposerMetrics.inset)
            }
            row
        }
        .onChange(of: text) {
            if let longPaste, !longPaste.isIntact() { self.longPaste = nil }
        }
        .composerFileDrop(enabled: onAttachFiles != nil, accept: acceptDropped)
    }

    private var row: some View {
        HStack(alignment: .bottom, spacing: ComposerMetrics.rowSpacing) {
            if let onAttachFiles {
                ComposerAttachButton(help: attachHelp) {
                    ComposerFilePanel.pick(attach: config.attachUnavailableReason, pdf: config.pdfUnavailableReason,
                                           onAttachFiles)
                }
            } else if let onAttachMenu {
                ComposerAttachButton(help: attachHelp, action: onAttachMenu)
            }
            dictated(style.composerFieldBackground(AnyView(input)))
            switch buttonMode {
            case .sendButton(let active):
                style.sendStopButton(isStreaming: false, active: active, action: onSend)
            case .stopButton(let active):
                style.sendStopButton(isStreaming: true, active: active) { onStop?() }
            }
        }
        .padding(.horizontal, ComposerMetrics.rowInset)
        .padding(.vertical, ComposerMetrics.rowVertical)
    }

    private var input: some View {
        ChatComposerTextInput(
            text: $text,
            height: $inputHeight,
            placeholder: config.placeholder,
            maxHeight: config.maxHeight,
            onEscape: onEscape,
            onArrowUpWhenEmpty: onArrowUpWhenEmpty,
            onPasteData: pastableData,
            onAttachFiles: attachableFiles,
            onLongTextPaste: { longPaste = $0 },
            onInlinePaste: config.inlinePastes ? onInlinePaste : nil,
            livePastes: config.livePastes,
            onCursorChange: onCursorChange,
            onPickerKey: onPickerKey,
            autoFocus: config.autoFocus,
            focusRequest: config.focusRequest,
            onSubmit: submit
        )
    }

    /// Enter: sends only what Send would.
    private func submit() {
        guard canSend else { return }
        onSend()
    }

    /// The field with the app's dictation around it, when the surface has a target and the app offers it.
    private func dictated(_ field: AnyView) -> AnyView {
        guard let id = config.dictationTargetID, let dictation = services.dictation else { return field }
        return dictation(field, $text, id)
    }

    private var attachHelp: String {
        ComposerAttachmentRules.attachHelp(attach: config.attachUnavailableReason, pdf: config.pdfUnavailableReason)
    }

    private var refusesSome: Bool { config.attachUnavailableReason != nil || config.pdfUnavailableReason != nil }

    private func refusal(_ url: URL) -> String? {
        ComposerAttachmentRules.refusal(of: ComposerAttachmentRules.kind(url), attach: config.attachUnavailableReason,
                                        pdf: config.pdfUnavailableReason)
    }

    /// A drop: file URLs only, without the kinds the provider refuses (their reason shows).
    private func acceptDropped(_ urls: [URL]) -> Bool {
        guard let onAttachFiles else { return false }
        let dropped = urls.filter(\.isFileURL)
        let files = dropped.filter { refusal($0) == nil }
        refusedNotice = dropped.lazy.compactMap(refusal).first
        guard !files.isEmpty else { return false }
        onAttachFiles(files)
        return true
    }

    /// onAttachFiles without the files the provider refuses (U1: images and PDFs; a PDF from an images-only
    /// provider): a pasted Finder file of those kinds is not added, and the reason shows.
    private var attachableFiles: (([URL]) -> Void)? {
        guard let onAttachFiles, refusesSome else { return onAttachFiles }
        return { urls in
            let files = urls.filter { refusal($0) == nil }
            refusedNotice = urls.lazy.compactMap(refusal).first
            if !files.isEmpty { onAttachFiles(files) }
        }
    }

    /// onPasteData refusing the pasted bytes the provider refuses, with the reason.
    private var pastableData: ((Data, String) async -> Bool)? {
        guard let onPasteData, refusesSome else { return onPasteData }
        let attach = config.attachUnavailableReason
        let pdf = config.pdfUnavailableReason
        return { data, name in
            let kind = ComposerAttachmentRules.kind(of: data, name: name, isImage: ComposerPlatform.isImage)
            if let reason = ComposerAttachmentRules.refusal(of: kind, attach: attach, pdf: pdf) {
                refusedNotice = reason
                return false
            }
            refusedNotice = nil
            return await onPasteData(data, name)
        }
    }

    private func attachLongPaste() {
        defer { longPaste = nil }
        guard let longPaste, let onPasteData else { return }
        Task { await longPaste.attach(using: onPasteData) }
    }

    /// A message may carry only attachments, or only pending content (no text).
    private var canSend: Bool {
        guard !config.sendBlocked else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
            || config.hasPendingContent
    }

    private var buttonMode: ComposerButtonMode {
        ComposerButtonMode.resolve(isStreaming: isStreaming, sendWhileStreaming: config.sendWhileStreaming,
                                   canSend: canSend, canStop: onStop != nil)
    }
}
