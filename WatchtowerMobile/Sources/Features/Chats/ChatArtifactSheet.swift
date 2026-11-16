import SwiftUI
import UIKit
import WatchtowerChatText

/// The sheet's buttons come from the one table both apps' viewers draw (`WatchtowerChatText.ChatArtifactActions`,
/// unified chat ruling F20); the phone's artifact is read through these adapters. CHAT-05: only open or copy.
extension ChatArtifactContent {
    var draft: ArtifactDraft {
        ArtifactDraft(key: key, kind: kind, title: title, meta: meta, content: content, isComplete: true)
    }
}

extension ChatArtifactActions {
    init(_ artifact: ChatArtifactContent, timeZone: TimeZone = .current) {
        self.init(artifact.draft, timeZone: timeZone)
    }

    static func fields(_ artifact: ChatArtifactContent) -> [(label: String, value: String)] {
        fields(artifact.draft)
    }

    static func markdown(_ artifact: ChatArtifactContent) -> String {
        markdown(artifact.draft)
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
