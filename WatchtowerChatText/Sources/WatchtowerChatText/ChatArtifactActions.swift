import Foundation

/// An artifact viewer's buttons, the one table both apps' viewers draw (unified chat spec §6.1, ruling F20): the
/// kind's own button from `ArtifactActions.kindActions` (the Mac's panel adds Gmail when connected and its own Slack
/// resolver; a viewer without them gets Mail and the artifact's permalink or the Slack app), then Copy and Share on
/// every kind. CHAT-05: only open or copy — no case writes anywhere. Pure.
public struct ChatArtifactActions: Equatable {
    public enum Effect: Equatable {
        case open(URL)
        case copyThenOpen(text: String, url: URL?)
        case copy(String)
        case share(String)
    }

    public struct Button: Equatable, Identifiable {
        public let title: String
        public let symbol: String
        public let effect: Effect
        /// The kind's own button; Copy and Share are plain.
        public let isPrimary: Bool

        public var id: String { title }
    }

    public static let copy = "Copy"
    public static let share = "Share"

    public let buttons: [Button]

    public init(_ draft: ArtifactDraft, timeZone: TimeZone = .current) {
        let own = ArtifactActions.kindActions(
            for: draft, gmailConnected: false,
            slackTarget: draft.kind == "slack" ? ArtifactLinks.slack(meta: draft.meta) : nil, timeZone: timeZone
        )
        let text = Self.text(draft)
        buttons = own.map { Button(title: $0.title, symbol: $0.systemImage, effect: Self.effect($0.action), isPrimary: true) }
            + [Button(title: Self.copy, symbol: "doc.on.doc", effect: .copy(text), isPrimary: false),
               Button(title: Self.share, symbol: "square.and.arrow.up", effect: .share(text), isPrimary: false)]
    }

    private static func effect(_ action: ChatArtifactAction) -> Effect {
        switch action {
        case let .open(url): .open(url)
        case let .copyThenOpen(text, url): .copyThenOpen(text: text, url: url)
        case let .copy(text): .copy(text)
        }
    }

    /// What Copy and Share carry: the fields that make the artifact, then its text (the Mac's export contents).
    public static func text(_ draft: ArtifactDraft) -> String {
        ArtifactActions.exportFile(for: draft).contents
    }

    /// The labelled fields a viewer shows above the text.
    public static func fields(_ draft: ArtifactDraft) -> [(label: String, value: String)] {
        let meta = draft.meta
        let pairs: [(String, String?)] = switch draft.kind {
        case "email": [("To", meta["to"]), ("Cc", meta["cc"]), ("Subject", meta["subject"])]
        case "event": [("Start", meta["start"]), ("End", meta["end"]), ("Location", meta["location"]), ("Attendees", meta["attendees"])]
        case "slack": [("Channel", meta["channel"])]
        default: []
        }
        return pairs.compactMap { label, value in
            guard let value, !value.isEmpty else { return nil }
            return (label, value)
        }
    }

    /// The text a Markdown kind renders: code in a fence of its language.
    public static func markdown(_ draft: ArtifactDraft) -> String {
        guard draft.kind == "code" else { return draft.content }
        return "```\(draft.meta["language"] ?? "")\n\(draft.content)\n```"
    }
}
