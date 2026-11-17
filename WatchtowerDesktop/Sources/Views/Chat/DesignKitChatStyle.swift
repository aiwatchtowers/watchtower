import AppKit
import ChatUI
import DesignKit
import SwiftUI
import WatchtowerChatText
import WatchtowerCore

/// The Mac's controls for the shared chat views (unified chat spec §14, D18): ChatUI draws its buttons, cards and
/// chips through this style, so the chat looks like the rest of the app (DesignKit's kit styles and card).
struct DesignKitChatStyle: ChatUIStyle {
    /// Which Mac surface draws: each keeps the look it had before it came onto ChatUI (unified chat T12, spec §2 "a
    /// move, not a redesign").
    enum Look {
        /// The main chat (ChatUI's own row look).
        case standard
        /// The embedded assistant chats: the blue owner bubble, an icon Copy and caption shown on hover (and on the
        /// last row), the accent question card.
        case embedded
        /// Workchat: the tinted owner bubble, a time line under each message, the accent question card.
        case workchat
        /// The owner-ask drawer: the accent question card.
        case ask
    }

    var look: Look = .standard

    func primaryButton(_ title: String, action: @escaping () -> Void) -> AnyView {
        AnyView(Button(title, action: action).buttonStyle(.kitPrimary))
    }

    func secondaryButton(_ title: String, action: @escaping () -> Void) -> AnyView {
        AnyView(Button(title, action: action).buttonStyle(.kitQuiet))
    }

    func card<C: View>(@ViewBuilder _ content: () -> C) -> AnyView {
        AnyView(content().padding(Spacing.cozy).frame(maxWidth: .infinity, alignment: .leading).card())
    }

    func chip(_ title: String) -> AnyView {
        AnyView(Chip(text: title, color: .secondary))
    }

    /// The Mac's multi-line comment editor: Return is a new line, ⌘↩ sends a complete card.
    func questionOtherField(text: Binding<String>, placeholder: String, onSubmit: (() -> Void)?) -> AnyView {
        AnyView(CommentTextEditor(text: text, placeholder: placeholder, onSubmit: onSubmit))
    }

    func ownerBubble(_ content: AnyView) -> AnyView {
        switch look {
        case .standard, .ask:
            PlainChatUIStyle().ownerBubble(content)
        case .embedded:
            AnyView(HStack(spacing: 0) {
                Spacer(minLength: Spacing.hero)
                content
                    .padding(.horizontal, Spacing.medium + Spacing.tight)
                    .padding(.vertical, Spacing.cozy)
                    .foregroundStyle(.white)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: Radius.bubble))
            })
        case .workchat:
            AnyView(HStack(spacing: 0) {
                Spacer(minLength: Spacing.hero + Spacing.regular)
                content
                    .padding(.horizontal, Spacing.cozy)
                    .padding(.vertical, Spacing.compact)
                    .background(Color.accentColor.opacity(ChipTint.fillOpacity),
                                in: RoundedRectangle(cornerRadius: Radius.container, style: .continuous))
            })
        }
    }

    func copyButton(_ action: @escaping () -> Void) -> AnyView {
        guard look == .embedded else { return secondaryButton("Copy", action: action) }
        return AnyView(Button(action: action) { Image(systemName: "doc.on.doc") }
            .buttonStyle(.borderless)
            .help("Copy message")
            .accessibilityLabel("Copy message"))
    }

    var actionsOnHover: Bool { look == .embedded }

    var rowSpacing: CGFloat {
        switch look {
        case .standard, .ask: Spacing.regular
        case .embedded: Spacing.small
        case .workchat: Spacing.tight
        }
    }

    var actionsSpacing: CGFloat { look == .embedded ? Spacing.cozy : Spacing.regular }

    func questionCard(_ content: AnyView) -> AnyView {
        guard look != .standard else { return card { content } }
        return AnyView(
            content
                .padding(Spacing.medium)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(Fill.cardOpacity), in: RoundedRectangle(cornerRadius: Radius.container))
                .overlay(RoundedRectangle(cornerRadius: Radius.container)
                    .strokeBorder(Color.accentColor.opacity(Self.questionStrokeOpacity), lineWidth: Stroke.hairline))
        )
    }

    /// The accent question card's outline, as the app's card drew it.
    private static let questionStrokeOpacity = 0.25

    func recommendedMark(_ title: String) -> AnyView {
        guard look != .standard else { return chip(title) }
        return AnyView(
            Text(title)
                .font(.caption2.weight(.medium))
                .padding(.horizontal, Spacing.small + 1)
                .padding(.vertical, Stroke.hairline * 2)
                .background(Color.accentColor.opacity(Self.recommendedFillOpacity), in: Capsule())
        )
    }

    private static let recommendedFillOpacity = 0.15

    var actionsOnCompleteRepliesOnly: Bool { look == .embedded }

    var stepsFirst: Bool { look == .embedded }

    /// The embedded chats' step line: the catalog's icon and label from the call's arguments.
    func stepLine(_ step: ChatStepLine, turnRunning: Bool) -> AnyView? {
        guard look == .embedded else { return nil }
        return AnyView(EmbeddedStepRow(step, turnRunning: turnRunning))
    }

    /// The Chats panel keeps the row it had before the unified chat (spec §2, final review I5).
    func listRow(_ content: ChatListRowContent) -> AnyView? {
        AnyView(ChatSidebarRow(content: content))
    }

    /// The embedded chats' error line: the reason and its detail on a red tint, Retry on the right; a reply stopped by
    /// the subscription quota is the provider-fallback card with "Review actions".
    func errorCard(_ content: ChatErrorCardContent) -> AnyView? {
        guard look == .embedded else { return nil }
        if content.code == "quota_exhausted" {
            return AnyView(ChatRoutingStatusView(preview: ProviderFallbackPreview(state: .stopped),
                                                 onAction: content.reviewActions))
        }
        return AnyView(
            HStack(spacing: Spacing.regular) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Tone.error)
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    Text(content.message).font(.callout)
                    if let detail = content.detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                Spacer()
                if let retry = content.retry {
                    Button("Retry", action: retry)
                }
            }
            .padding(Spacing.regular)
            .background(Tone.error.opacity(Self.errorFillOpacity), in: RoundedRectangle(cornerRadius: Radius.row))
            // The app's row drew an empty answer body before a failed reply's card: the same gap under the steps.
            .padding(.top, content.replyHasText ? 0 : Spacing.small)
        )
    }

    private static let errorFillOpacity = 0.08
}

extension View {
    /// The shared chat views with the Mac's controls and artifact presentation.
    func macChatStyle(hooks: ChatMacArtifactHooks, look: DesignKitChatStyle.Look = .standard) -> some View {
        environment(\.chatUIStyle, DesignKitChatStyle(look: look))
            .environment(\.chatHostText, .mac)
            .environment(\.chatMacArtifactHooks, hooks)
    }
}

extension ChatHostText {
    /// The Mac's own lines: the chat runs on this Mac (#1783 is the phone's rule).
    static let mac = ChatHostText(
        messageCut: "This message is cut here; the whole text is on your Mac.",
        artifactCut: "This artifact is cut here; the whole text is on your Mac.",
        chooseSlackWorkspace: "Choose a workspace on the Mac before approving"
    )
}

extension ChatMacArtifactHooks {
    /// The app's artifact presentation (ruling F20): the sandboxed web view, the print panel, and the preview window
    /// (Present is full screen). Each only shows or prints a page (CHAT-05).
    @MainActor static var app: ChatMacArtifactHooks {
        ChatMacArtifactHooks(
            htmlView: { html in AnyView(SandboxedHTMLView(content: .page(html))) },
            print: { artifact in
                ArtifactPrinter.print(artifact.draft, window: NSApp.keyWindow ?? NSApp.mainWindow) { _ in }
            },
            present: { artifact in
                HTMLPreviewWindow.show(.page(artifact.content), title: artifact.title, fullScreen: true)
            },
            openInWindow: { artifact in
                HTMLPreviewWindow.show(.page(artifact.content), title: artifact.title, fullScreen: false)
            }
        )
    }
}

// MARK: - The composer (#1822 T13): the Mac's look from before the composer moved into ChatUI, on every look.

extension DesignKitChatStyle {
    /// The Mac composer's own values with no kit token (kept from before the move, so it looks the same).
    private static let importingChipOpacity = 0.08
    private static let pickerSelectedOpacity = 0.18
    private static let composerChipVertical: CGFloat = 3
    private static let pickerRowVertical: CGFloat = 5

    func composerFieldBackground(_ field: AnyView) -> AnyView {
        AnyView(
            field
                .padding(.horizontal, Spacing.regular)
                .padding(.vertical, Spacing.compact)
                .background(RoundedRectangle(cornerRadius: Radius.pill).fill(Color(.textBackgroundColor)))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.pill)
                        .strokeBorder(Color(.separatorColor).opacity(ChipTint.strokeOpacity), lineWidth: Stroke.hairline)
                )
        )
    }

    func sendStopButton(isStreaming: Bool, active: Bool, action: @escaping () -> Void) -> AnyView {
        AnyView(
            Button(action: action) {
                Image(systemName: isStreaming ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .font(.system(size: IconSize.composerLarge))
                    .foregroundStyle(active ? Color.accentColor : Color(.tertiaryLabelColor))
            }
            .buttonStyle(.borderless)
            .disabled(!active)
            .accessibilityLabel(isStreaming ? "Stop" : "Send")
        )
    }

    func attachmentChip(_ chip: ChatAttachmentChipContent) -> AnyView {
        guard chip.state != .importing else {
            // A file being stored (board #670): shown at once, with progress.
            return AnyView(
                HStack(spacing: Spacing.small) {
                    ProgressView().controlSize(.mini)
                    Text(chip.name).lineLimit(1).truncationMode(.middle)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Spacing.regular)
                .padding(.vertical, Spacing.small)
                .background(Color.secondary.opacity(Self.importingChipOpacity), in: Capsule())
            )
        }
        return AnyView(
            HStack(spacing: Spacing.small) {
                Image(systemName: chip.icon)
                Text(chip.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let retry = chip.onRetry {
                    Button("Retry", action: retry).buttonStyle(.borderless)
                }
                if let remove = chip.onRemove {
                    Button(action: remove) {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(chip.name)")
                    .help("Remove \(chip.name)")
                    .disabled(chip.removeDisabled)
                }
            }
            .font(.caption)
            .padding(.horizontal, Spacing.regular)
            .padding(.vertical, Spacing.small)
            .background(Color.secondary.opacity(Fill.selectedOpacity), in: Capsule())
        )
    }

    func composerChip(_ chip: ChatComposerChipContent) -> AnyView {
        AnyView(
            HStack(spacing: Spacing.small) {
                Image(systemName: chip.icon)
                Text(chip.title).lineLimit(1)
                Button(action: chip.onRemove) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Remove \(chip.title)")
                    .accessibilityLabel("Remove \(chip.title)")
            }
            .font(.caption)
            .padding(.horizontal, Spacing.regular)
            .padding(.vertical, Self.composerChipVertical)
            .background(Capsule().fill(Fill.selected))
        )
    }

    func quoteRow(_ quote: ChatQuoteDraft, comment: Binding<String>, onRemove: @escaping () -> Void) -> AnyView {
        AnyView(
            HStack(alignment: .top, spacing: Spacing.regular) {
                VStack(alignment: .leading, spacing: Spacing.small) {
                    Text("\u{201C}\(quote.quote)\u{201D}")
                        .font(.caption)
                        .italic()
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    TextField("Comment (optional)", text: comment)
                        .textFieldStyle(.roundedBorder)
                        .font(.callout)
                }
                Button(action: onRemove) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .help("Remove quote")
                    .accessibilityLabel("Remove quote")
            }
            .padding(Spacing.regular)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: Radius.row))
        )
    }

    func pickerList(_ rows: [ComposerPickerItem], selected: Int, onPick: @escaping (Int) -> Void) -> AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    Button { onPick(index) } label: {
                        HStack(spacing: Spacing.regular) {
                            Image(systemName: row.icon).frame(width: 18)
                            Text(row.title).lineLimit(1)
                            Text(row.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, Spacing.cozy)
                        .padding(.vertical, Self.pickerRowVertical)
                        .background(index == selected ? Color.accentColor.opacity(Self.pickerSelectedOpacity) : .clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(RoundedRectangle(cornerRadius: Radius.row).fill(Color(.windowBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: Radius.row).strokeBorder(Color(.separatorColor)))
            .padding(.horizontal, Spacing.medium)
        )
    }
}

extension ChatComposerServices {
    /// The Mac's dictation around a composer field: the highlight of the field being dictated into and the mic
    /// button, both on the environment's `DictationCenter` (none in tests and previews: the field alone).
    static let mac = mac(center: nil)

    /// The same with an explicit center (tests: ViewInspector cannot resolve the environment's center there).
    static func mac(center: DictationCenter?) -> ChatComposerServices {
        ChatComposerServices { field, text, targetID in
            AnyView(MacDictatedField(field: field, text: text, targetID: targetID, explicitCenter: center))
        }
    }
}

/// The field with the dictation highlight, then the mic button.
private struct MacDictatedField: View {
    let field: AnyView
    @Binding var text: String
    let targetID: String
    let explicitCenter: DictationCenter?
    @Environment(\.dictationCenter) private var environmentCenter

    private var center: DictationCenter? { explicitCenter ?? environmentCenter }

    var body: some View {
        HStack(alignment: .bottom, spacing: Spacing.compact) {
            field.dictationHighlight(targetID: targetID, center: center, cornerRadius: Radius.pill)
            if let center {
                DictationButton(text: $text, mode: .chat, targetID: targetID, center: center)
            }
        }
    }
}

extension View {
    /// A composer with the Mac's look and dictation, on any surface (the shared field reads both from the
    /// environment).
    func macComposerStyle() -> some View {
        environment(\.chatUIStyle, DesignKitChatStyle())
            .environment(\.chatComposerServices, .mac)
    }
}
