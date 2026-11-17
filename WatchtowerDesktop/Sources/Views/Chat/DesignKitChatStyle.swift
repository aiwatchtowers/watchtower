import AppKit
import ChatUI
import DesignKit
import SwiftUI
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
