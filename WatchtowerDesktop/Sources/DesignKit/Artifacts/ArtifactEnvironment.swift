import SwiftUI

/// Where a card is drawn: the Inbox (buttons work) or the automation
/// editor's Look preview (every button drawn but disabled; links still open).
public enum ArtifactRenderMode: Equatable, Sendable {
    case inbox, preview

    /// The help text of a button drawn in `.preview`.
    public static let previewButtonHelp = "Buttons work in the Inbox"
}

/// Sub-project B's seam on a list row with a `ref` (spec "Contract with
/// sub-project B", 3). The defaults draw every row and no native action.
public struct ArtifactRefHooks {
    /// False hides the row; a list whose rows are all hidden shows its `empty` text.
    public var isOpen: (ArtifactRef) -> Bool
    /// Drawn at the row's trailing edge; B disables it in `.preview`.
    public var nativeActions: (ArtifactRef, ArtifactRenderMode) -> AnyView?
    /// The recipe's row actions of these kinds are not drawn on that row.
    public var nativeKinds: (ArtifactRef) -> Set<ArtifactActionKind>

    public init(
        isOpen: @escaping (ArtifactRef) -> Bool = { _ in true },
        nativeActions: @escaping (ArtifactRef, ArtifactRenderMode) -> AnyView? = { _, _ in nil },
        nativeKinds: @escaping (ArtifactRef) -> Set<ArtifactActionKind> = { _ in [] }
    ) {
        self.isOpen = isOpen
        self.nativeActions = nativeActions
        self.nativeKinds = nativeKinds
    }
}

/// What the app owns and DesignKit cannot see, injected through one
/// environment value (`\.artifactEnvironment`). The defaults draw a card
/// on its own (the gallery, the shots): inline markdown, initials, presses
/// that do nothing, every target button idle.
public struct ArtifactEnvironment {
    /// A text block's markdown; the app passes its chat renderer (link rules).
    public var markdown: (String) -> AnyView
    /// A person's `slack_user` resolved from the local `users` table; nil draws initials.
    public var avatar: (String) -> AnyView?
    /// A press, by its index in the card's flattened action list. A target
    /// button calls it in every state but creating; the host reads the
    /// button's state to decide (propose, open the approval card, try
    /// again, open the task).
    public var onAction: (Int) -> Void
    public var refHooks: ArtifactRefHooks
    /// The state of the target button at a flattened index.
    public var targetButtonState: (Int) -> ArtifactTargetButtonState
    /// Whether the button at a flattened index can be pressed in `.inbox`
    /// now: the host disables a Reply already sent, a link its rules refuse,
    /// a press while one is under way, a kind it does not press yet.
    public var isActionEnabled: (Int) -> Bool

    public init(
        markdown: @escaping (String) -> AnyView = Self.inlineMarkdown,
        avatar: @escaping (String) -> AnyView? = { _ in nil },
        onAction: @escaping (Int) -> Void = { _ in },
        refHooks: ArtifactRefHooks = ArtifactRefHooks(),
        targetButtonState: @escaping (Int) -> ArtifactTargetButtonState = { _ in .idle },
        isActionEnabled: @escaping (Int) -> Bool = { _ in true }
    ) {
        self.markdown = markdown
        self.avatar = avatar
        self.onAction = onAction
        self.refHooks = refHooks
        self.targetButtonState = targetButtonState
        self.isActionEnabled = isActionEnabled
    }

    /// Inline-only markdown; text that does not parse shows as written.
    public static func inlineMarkdown(_ text: String) -> AnyView {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let attributed = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        return AnyView(Text(attributed).fixedSize(horizontal: false, vertical: true))
    }
}

extension EnvironmentValues {
    @Entry public var artifactEnvironment = ArtifactEnvironment()
}
