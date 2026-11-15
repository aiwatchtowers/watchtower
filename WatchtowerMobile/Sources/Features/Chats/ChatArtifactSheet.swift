import SwiftUI
import UIKit
import WatchtowerChatText

/// What an artifact's buttons do (mockup 3b, CHAT-05): only open or copy. Email opens Mail (`mailto:`), an event
/// opens the Google Calendar template, Slack copies the text and opens the Slack app; Copy and Share are on every
/// kind. No case writes anywhere. Pure.
struct ChatArtifactActions: Equatable {
    enum Effect: Equatable {
        case open(URL)
        case copyThenOpen(text: String, url: URL?)
        case copy(String)
        case share(String)
    }

    struct Button: Equatable, Identifiable {
        let title: String
        let symbol: String
        let effect: Effect
        /// The kind's own button (blue in 3b); Copy and Share are plain.
        let isPrimary: Bool

        var id: String { title }
    }

    static let openInMail = "Open in Mail"
    static let openInCalendar = "Open in Google Calendar"
    static let openInSlack = "Copy & open Slack"
    static let copy = "Copy"
    static let share = "Share"

    let buttons: [Button]

    init(_ artifact: ChatArtifactContent, timeZone: TimeZone = .current) {
        var buttons: [Button] = []
        switch artifact.kind {
        case "email":
            buttons.append(Button(title: Self.openInMail, symbol: "envelope", effect: Self.effect(
                ArtifactLinks.mailto(meta: artifact.meta, body: artifact.content)), isPrimary: true))
        case "event":
            var meta = artifact.meta
            meta["title"] = artifact.title
            buttons.append(Button(title: Self.openInCalendar, symbol: "calendar.badge.plus", effect: Self.effect(
                ArtifactLinks.calendarTemplate(meta: meta, body: artifact.content, timeZone: timeZone)), isPrimary: true))
        case "slack":
            buttons.append(Button(title: Self.openInSlack, symbol: "number", effect: .copyThenOpen(
                text: artifact.content, url: ArtifactLinks.slack(meta: artifact.meta)), isPrimary: true))
        default:
            break
        }
        let text = Self.text(artifact)
        buttons.append(Button(title: Self.copy, symbol: "doc.on.doc", effect: .copy(text), isPrimary: false))
        buttons.append(Button(title: Self.share, symbol: "square.and.arrow.up", effect: .share(text), isPrimary: false))
        self.buttons = buttons
    }

    private static func effect(_ link: ArtifactLink) -> Effect {
        switch link {
        case let .open(url): .open(url)
        case let .copyThenOpen(text, url): .copyThenOpen(text: text, url: url)
        }
    }

    /// What Copy and Share carry: the fields that make the artifact, then its text (the Mac's export).
    static func text(_ artifact: ChatArtifactContent) -> String {
        let fields: [(String, String?)] = switch artifact.kind {
        case "email": [("To", artifact.meta["to"]), ("Cc", artifact.meta["cc"]), ("Subject", artifact.meta["subject"])]
        case "event":
            [("Title", artifact.title), ("Start", artifact.meta["start"]), ("End", artifact.meta["end"]),
             ("Attendees", artifact.meta["attendees"]), ("Location", artifact.meta["location"])]
        default: []
        }
        let lines = fields.compactMap { name, value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return "\(name): \(value)"
        }
        return lines.isEmpty ? artifact.content : lines.joined(separator: "\n") + "\n\n" + artifact.content
    }

    /// The labelled fields the sheet shows above the text (mockup 3b).
    static func fields(_ artifact: ChatArtifactContent) -> [(label: String, value: String)] {
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
    static func markdown(_ artifact: ChatArtifactContent) -> String {
        guard artifact.kind == "code" else { return artifact.content }
        return "```\(artifact.meta["language"] ?? "")\n\(artifact.content)\n```"
    }
}

/// The artifact sheet (mockup 3b): an email's, an event's or a Slack message's fields and text; a document, table
/// or code as Markdown; a page in the sandboxed web view; the kind's open button, Copy and Share.
struct ChatArtifactSheet: View {
    static let bodyLabel = "Body"

    let artifact: ChatArtifactContent
    let host: TowerHost
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let actions = ChatArtifactActions(artifact)
        NavigationStack {
            VStack(spacing: 0) {
                content
                buttons(actions)
            }
            .navigationTitle(artifact.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Text("v\(artifact.version)").font(TypeScale.meta).foregroundStyle(.secondary)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close")
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        if artifact.kind == "html", !artifact.contentCut {
            SandboxedArtifactWebView(html: artifact.content)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.regular) {
                    if artifact.contentCut {
                        Text(ChatText.openToSeeAll(host)).font(TypeScale.meta).foregroundStyle(.secondary)
                    }
                    let fields = ChatArtifactActions.fields(artifact)
                    if !fields.isEmpty {
                        VStack(alignment: .leading, spacing: Spacing.compact) {
                            ForEach(fields, id: \.label) { field in
                                Text(field.label).font(TypeScale.meta).foregroundStyle(.secondary)
                                Text(field.value).font(TypeScale.rowTitle).textSelection(.enabled)
                            }
                            Text(Self.bodyLabel).font(TypeScale.meta).foregroundStyle(.secondary)
                            Text(artifact.content).font(TypeScale.rowTitle).textSelection(.enabled)
                        }
                        .padding(Spacing.cozy)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Fill.card, in: RoundedRectangle(cornerRadius: Radius.container, style: .continuous))
                    } else {
                        ChatMarkdownView(text: ChatArtifactActions.markdown(artifact)).textSelection(.enabled)
                    }
                }
                .padding(Spacing.large)
            }
        }
    }

    private func buttons(_ actions: ChatArtifactActions) -> some View {
        HStack(spacing: Spacing.regular) {
            ForEach(actions.buttons) { button in
                switch button.effect {
                case let .share(text):
                    ShareLink(item: text) { Text(button.title) }
                        .buttonStyle(ChatCardButtonStyle(fill: Fill.card, label: .primary))
                default:
                    Button(button.title) { perform(button.effect) }
                        .buttonStyle(ChatCardButtonStyle(
                            fill: button.isPrimary ? .accentColor : Fill.card, label: button.isPrimary ? .white : .primary
                        ))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.large)
        .padding(.vertical, Spacing.regular)
        .background(alignment: .top) { Divider() }
    }

    /// Opens or copies; nothing else.
    private func perform(_ effect: ChatArtifactActions.Effect) {
        switch effect {
        case let .open(url):
            openURL(url)
        case let .copyThenOpen(text, url):
            UIPasteboard.general.string = text
            if let url { openURL(url) }
        case let .copy(text):
            UIPasteboard.general.string = text
        case .share:
            break
        }
    }
}
