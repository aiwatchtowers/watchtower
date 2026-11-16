import SwiftUI
import WatchtowerChatText
import WatchtowerDesign

/// What an artifact's buttons do (CHAT-05): only open or copy. Email opens Mail (`mailto:`), an event opens the Google
/// Calendar template, Slack copies the text and opens the Slack app; Copy and Share are on every kind. No case writes
/// anywhere. Pure.
public struct ChatArtifactActions: Equatable {
    public enum Effect: Equatable {
        case open(URL)
        case copyThenOpen(text: String, url: URL?)
        case copy(String)
        case share(String)
    }

    public struct Choice: Equatable, Identifiable {
        public let title: String
        public let symbol: String
        public let effect: Effect
        /// The kind's own button; Copy and Share are plain.
        public let isPrimary: Bool

        public var id: String { title }
    }

    public static let openInMail = "Open in Mail"
    public static let openInCalendar = "Open in Google Calendar"
    public static let openInSlack = "Copy & open Slack"
    public static let copy = "Copy"
    public static let share = "Share"

    public let choices: [Choice]

    public init(_ artifact: ChatArtifactContent, timeZone: TimeZone = .current) {
        var choices: [Choice] = []
        switch artifact.kind {
        case "email":
            choices.append(Choice(title: Self.openInMail, symbol: "envelope", effect: Self.effect(
                ArtifactLinks.mailto(meta: artifact.meta, body: artifact.content)), isPrimary: true))
        case "event":
            var meta = artifact.meta
            meta["title"] = artifact.title
            choices.append(Choice(title: Self.openInCalendar, symbol: "calendar.badge.plus", effect: Self.effect(
                ArtifactLinks.calendarTemplate(meta: meta, body: artifact.content, timeZone: timeZone)), isPrimary: true))
        case "slack":
            choices.append(Choice(title: Self.openInSlack, symbol: "number", effect: .copyThenOpen(
                text: artifact.content, url: ArtifactLinks.slack(meta: artifact.meta)), isPrimary: true))
        default:
            break
        }
        let text = Self.text(artifact)
        choices.append(Choice(title: Self.copy, symbol: "doc.on.doc", effect: .copy(text), isPrimary: false))
        choices.append(Choice(title: Self.share, symbol: "square.and.arrow.up", effect: .share(text), isPrimary: false))
        self.choices = choices
    }

    private static func effect(_ link: ArtifactLink) -> Effect {
        switch link {
        case let .open(url): .open(url)
        case let .copyThenOpen(text, url): .copyThenOpen(text: text, url: url)
        }
    }

    /// What Copy and Share carry: the fields that make the artifact, then its text.
    public static func text(_ artifact: ChatArtifactContent) -> String {
        let lines = textFields(artifact).compactMap { name, value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return "\(name): \(value)"
        }
        return lines.isEmpty ? artifact.content : lines.joined(separator: "\n") + "\n\n" + artifact.content
    }

    private static func textFields(_ artifact: ChatArtifactContent) -> [(String, String?)] {
        switch artifact.kind {
        case "email": [("To", artifact.meta["to"]), ("Cc", artifact.meta["cc"]), ("Subject", artifact.meta["subject"])]
        case "event":
            [("Title", artifact.title), ("Start", artifact.meta["start"]), ("End", artifact.meta["end"]),
             ("Attendees", artifact.meta["attendees"]), ("Location", artifact.meta["location"])]
        default: []
        }
    }

    /// The labelled fields the viewer shows above the text.
    public static func fields(_ artifact: ChatArtifactContent) -> [(label: String, value: String)] {
        let pairs: [(String, String?)] = switch artifact.kind {
        case "email": [("To", artifact.meta["to"]), ("Cc", artifact.meta["cc"]), ("Subject", artifact.meta["subject"])]
        case "event":
            [("Start", artifact.meta["start"]), ("End", artifact.meta["end"]), ("Location", artifact.meta["location"]),
             ("Attendees", artifact.meta["attendees"])]
        case "slack": [("Channel", artifact.meta["channel"])]
        default: []
        }
        return pairs.compactMap { label, value in
            guard let value, !value.isEmpty else { return nil }
            return (label, value)
        }
    }

    /// The text a Markdown kind renders: code in a fence of its language.
    public static func markdown(_ artifact: ChatArtifactContent) -> String {
        guard artifact.kind == "code" else { return artifact.content }
        return "```\(artifact.meta["language"] ?? "")\n\(artifact.content)\n```"
    }
}

/// The artifact viewer shared by both apps (the Mac's inspector hosts it, the phone shows it in a sheet): the fields
/// and text of an email, an event or a Slack message; a document, table or code as Markdown; a page in the sandboxed
/// web view; the kind's open button, Copy and Share, and on the Mac Print, Present and Open in Window.
public struct ArtifactViewer: View {
    public static let cutLine = "This artifact is cut here; the whole text is on your Mac."

    let artifact: ChatArtifactContent
    let openURL: (URL) -> Void
    let copy: (String) -> Void
    @Environment(\.chatUIStyle) private var style

    public init(artifact: ChatArtifactContent, openURL: @escaping (URL) -> Void, copy: @escaping (String) -> Void) {
        self.artifact = artifact
        self.openURL = openURL
        self.copy = copy
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            header
            ForEach(ChatArtifactActions.fields(artifact), id: \.label) { field in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                    Text(field.label).font(.caption).foregroundStyle(.secondary)
                    Text(field.value).font(.callout).textSelection(.enabled)
                }
            }
            content
            if artifact.contentCut {
                Text(Self.cutLine).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(Spacing.large)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("chat.artifactViewer")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(artifact.title).font(.headline)
                Text("\(ArtifactPartView.kindLabel(artifact.kind)) · v\(artifact.version)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: Spacing.regular)
            ForEach(ChatArtifactActions(artifact).choices) { choice in
                choiceButton(choice)
            }
            ArtifactViewerExtras(artifact: artifact)
        }
    }

    @ViewBuilder private func choiceButton(_ choice: ChatArtifactActions.Choice) -> some View {
        switch choice.effect {
        case .share(let text):
            ShareLink(item: text) { Label(choice.title, systemImage: choice.symbol) }
        case .open(let url):
            style.secondaryButton(choice.title) { openURL(url) }
        case let .copyThenOpen(text, url):
            style.secondaryButton(choice.title) {
                copy(text)
                if let url { openURL(url) }
            }
        case .copy(let text):
            style.secondaryButton(choice.title) { copy(text) }
        }
    }

    @ViewBuilder private var content: some View {
        switch artifact.kind {
        case "html":
            ChatArtifactHTMLView(html: artifact.content)
                .frame(minHeight: PaneWidth.narrowPage)
        case "table":
            ArtifactTable(rows: CSVTable.parse(artifact.content))
        default:
            ScrollView {
                ChatAnswerText(text: ChatArtifactActions.markdown(artifact), isFinal: artifact.isComplete, isOwner: false)
                    .textSelection(.enabled)
            }
        }
    }
}

/// A table artifact: its CSV as a grid, the first row as the header.
private struct ArtifactTable: View {
    let rows: [[String]]

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Grid(alignment: .leading, horizontalSpacing: Spacing.medium, verticalSpacing: Spacing.compact) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(cell).font(index == 0 ? .callout.weight(.semibold) : .callout).textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(Spacing.regular)
        }
    }
}
