import SwiftUI
import WatchtowerChatText
import WatchtowerDesign

/// The artifact viewer shared by both apps (the Mac's inspector hosts it, the phone shows it in a sheet): the fields
/// and text of an email, an event or a Slack message; a document, table or code as Markdown; a page in the sandboxed
/// web view; the kind's open button, Copy and Share, and on the Mac Print, Present and Open in Window.
public struct ArtifactViewer: View {
    let artifact: ChatArtifactContent
    let openURL: (URL) -> Void
    let copy: (String) -> Void
    @Environment(\.chatUIStyle) private var style
    @Environment(\.chatHostText) private var hostText

    public init(artifact: ChatArtifactContent, openURL: @escaping (URL) -> Void, copy: @escaping (String) -> Void) {
        self.artifact = artifact
        self.openURL = openURL
        self.copy = copy
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            header
            ForEach(ChatArtifactActions.fields(artifact.draft), id: \.label) { field in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                    Text(field.label).font(.caption).foregroundStyle(.secondary)
                    Text(field.value).font(.callout).textSelection(.enabled)
                }
            }
            content
            if artifact.contentCut {
                Text(hostText.artifactCut).font(.caption).foregroundStyle(.secondary)
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
            ForEach(ChatArtifactActions(artifact.draft).buttons) { button in
                choiceButton(button)
            }
            ArtifactViewerExtras(artifact: artifact)
        }
    }

    @ViewBuilder private func choiceButton(_ choice: ChatArtifactActions.Button) -> some View {
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
                if let markdown = ChatArtifactActions.markdown(artifact.draft) {
                    ChatAnswerText(text: markdown, isFinal: artifact.isComplete, isOwner: false)
                        .textSelection(.enabled)
                } else {
                    // Code no Markdown fence can hold: the text as it is, line endings and blank edges kept.
                    Text(verbatim: artifact.content)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
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

extension ArtifactViewer {
    /// The SF Symbol of an artifact kind, as its card in the feed shows it (the Mac's artifact panel header too).
    public static func icon(for kind: String) -> String { ArtifactPartView.icon(for: kind) }
}
