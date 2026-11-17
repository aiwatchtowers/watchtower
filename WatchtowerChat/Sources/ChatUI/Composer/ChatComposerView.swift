import ChatWire
import SwiftUI
import WatchtowerChatText
import WatchtowerDesign

/// The shell's own files that go with the next send (the phone's staged files, uploaded by its client): the field's
/// chips show them with their upload state, Retry on a refused one.
public struct ChatComposerShellFiles {
    public let attachments: [ChatComposerAttachment]
    public let progress: AttachmentProgress
    public let onRemove: (Int64) -> Void
    public let onRetry: (Int64) -> Void

    public init(
        attachments: [ChatComposerAttachment],
        progress: AttachmentProgress,
        onRemove: @escaping (Int64) -> Void,
        onRetry: @escaping (Int64) -> Void
    ) {
        self.attachments = attachments
        self.progress = progress
        self.onRemove = onRemove
        self.onRetry = onRetry
    }
}

/// The main chat's composer on the Mac and the phone (unified chat spec §6.1, ask #1409): the state line when the
/// chat cannot be reached, the `@`/`/` picker over the field, the quote batch, the mention and skill chips, the
/// routing accessory slot, and the shared field (Enter sends, Esc stops, ↑ in an empty field edits the last message,
/// attachments, Send or Stop). The text stays until the engine applies the send (CHAT-01).
public struct ChatComposerView: View {
    @Bindable var model: ChatComposerModel
    let field: ChatComposerFieldConfig
    /// Opens the platform's file picker (the phone's attachment menu); nil hides the phone's paperclip.
    var onAttach: (() -> Void)?
    /// The routing accessory slot: the Mac's routing state and model pill (under the field). Nil fills it with the
    /// model and project chips of a new chat (the phone, over the field). T17 puts the shared routing view here.
    var accessory: AnyView?
    /// Files from the paperclip's open panel, a drop or a pasted Finder file (the Mac); nil: no paperclip, no drop.
    var onAttachFiles: (([URL]) -> Void)?
    /// A paste that becomes a file (an image, a PDF, a long text); true once attached. nil: ⌘V inserts text.
    var onPasteData: ((Data, String) async -> Bool)?
    /// The shell's own files (the phone); nil shows the model's attachments.
    var shellFiles: ChatComposerShellFiles?
    /// The shell's send (the Mac's landing and ⌘/ panel); nil sends the model.
    var onSend: (() -> Void)?
    /// The shell's own attachment error (the Mac's staging of a paste).
    var attachmentError: String?
    /// The caret at the last edit (UTF-16 offset): a mouse pick resolves the active `@`/`/` trigger at it.
    @State private var lastCursor = 0
    @Environment(\.chatUIStyle) private var style

    public init(
        model: ChatComposerModel,
        field: ChatComposerFieldConfig,
        onAttach: (() -> Void)? = nil,
        accessory: AnyView? = nil,
        onAttachFiles: (([URL]) -> Void)? = nil,
        onPasteData: ((Data, String) async -> Bool)? = nil,
        shellFiles: ChatComposerShellFiles? = nil,
        onSend: (() -> Void)? = nil,
        attachmentError: String? = nil
    ) {
        self.model = model
        self.field = field
        self.onAttach = onAttach
        self.accessory = accessory
        self.onAttachFiles = onAttachFiles
        self.onPasteData = onPasteData
        self.shellFiles = shellFiles
        self.onSend = onSend
        self.attachmentError = attachmentError
    }

    private var conversation: ChatConversationModel { model.conversation }
    private var picker: ComposerPickerModel { model.picker }

    public var body: some View {
        VStack(alignment: .leading, spacing: ComposerMetrics.stack) {
            if let content = model.stateLine {
                ChatStateLineView(content: content) { conversation.performStateAction() }
                    .padding(.horizontal, ComposerMetrics.inset)
            }
            if picker.isOpen {
                ComposerPickerList(items: picker.items, selectedIndex: picker.selectedIndex) { index in
                    if let edit = picker.accept(index: index, text: model.draft, cursor: lastCursor) {
                        model.draft = edit.text
                        lastCursor = edit.cursor
                    }
                }
            }
            if !model.quotes.isEmpty {
                QuoteBatchView(
                    quotes: model.quotes,
                    onEditComment: { id, comment in
                        if let index = model.quotes.firstIndex(where: { $0.id == id }) { model.quotes[index].comment = comment }
                    },
                    onRemove: { id in model.quotes.removeAll { $0.id == id } }
                )
            }
            if ComposerMetrics.accessoryAboveField { accessorySlot }
            ComposerChipsRow(
                mentions: picker.mentions,
                skill: picker.skill,
                onRemoveMention: { picker.removeMention($0) },
                onRemoveSkill: { picker.clearSkill() }
            )
            ChatComposerBar(status: status, input: input) {
                if !ComposerMetrics.accessoryAboveField { accessorySlot }
            }
            if !ComposerMetrics.noticeAsStatus, let line = model.line {
                Text(line).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(ComposerMetrics.padding)
        .accessibilityIdentifier("chat.composer")
    }

    /// The Mac shows the composer's notice as the status line's error over the field; the phone shows its line under.
    private var status: ChatComposerStatus? {
        guard ComposerMetrics.noticeAsStatus else { return nil }
        return (model.notice ?? conversation.notice).map(ChatComposerStatus.error)
    }

    private var input: ChatComposerField {
        var config = field
        config.hasPendingContent = config.hasPendingContent || !model.quotes.isEmpty
        config.sendBlocked = config.sendBlocked || !model.canSend
        let canStop = conversation.canStop
        return ChatComposerField(
            text: $model.draft,
            isStreaming: conversation.isTurnRunning || model.isSending,
            config: config,
            onSend: send,
            onStop: canStop ? { Task { await conversation.cancelTurn() } } : nil,
            onEscape: { Task { await conversation.cancelTurn() } },
            onArrowUpWhenEmpty: { model.beginEditingLast() },
            attachments: shellFiles?.attachments ?? model.attachments,
            attachmentProgress: shellFiles?.progress ?? AttachmentProgress(
                importing: model.importing, removing: model.removing, sendWaits: model.isWaitingForAttachments
            ),
            attachmentError: attachmentError,
            onAttachFiles: onAttachFiles,
            onPasteData: onPasteData,
            onRemoveAttachment: shellFiles?.onRemove ?? { id in Task { await model.removeAttachment(id) } },
            onRetryAttachment: shellFiles?.onRetry,
            onCursorChange: { text, cursor in
                lastCursor = cursor
                picker.update(text: text, cursor: cursor)
            },
            onPickerKey: { key, text, cursor in picker.handle(key, text: text, cursor: cursor) }
        )
        .attachMenu(onAttach)
    }

    private func send() {
        if let onSend {
            onSend()
        } else {
            Task { await model.send() }
        }
    }

    /// The routing accessory slot: the shell's accessory, else a new chat's model and project chips.
    @ViewBuilder private var accessorySlot: some View {
        if let accessory {
            accessory
        } else {
            newChatChips
        }
    }

    /// The model and project chips (a menu each on a new chat, locked text once it is saved).
    @ViewBuilder private var newChatChips: some View {
        if let modelChip = model.modelChip, let projectChip = model.projectChip, let choices = model.newChatChoices {
            HStack(spacing: Spacing.compact) {
                if modelChip.editable {
                    Menu {
                        ForEach(Array(ChatComposerModel.modelOptions(choices.models).enumerated()), id: \.offset) { _, option in
                            Button(option.label) { model.routing = option.routing }
                        }
                    } label: { style.chip(modelChip.label + " ⌄") }
                    .accessibilityIdentifier("chat.composer.model")
                } else {
                    style.chip(modelChip.label)
                }
                if projectChip.editable {
                    Menu {
                        Button(ChatComposerModel.noProject) { model.projectID = nil }
                        ForEach(choices.projects) { project in Button(project.name) { model.projectID = project.id } }
                    } label: { style.chip(projectChip.label + " ⌄") }
                    .accessibilityIdentifier("chat.composer.project")
                } else {
                    style.chip(projectChip.label)
                }
            }
        }
    }
}
