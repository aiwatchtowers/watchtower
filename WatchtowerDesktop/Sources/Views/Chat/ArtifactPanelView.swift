import SwiftUI
import WatchtowerCore

struct ArtifactPanelView: View {
    @Bindable var model: ArtifactPanelModel
    let gmailConnected: Bool
    let slackLinks: SlackLinkResolver?
    /// No answer is streaming (the chat refuses a second turn anyway).
    let canSendComments: Bool
    var expand: ChatInspectorExpandButton?
    /// "Send N comments" — the chat sends them as the owner's message.
    let onSendComments: () -> Void
    var onClose: () -> Void

    @State private var notice: String?
    /// Bumped by Reload on an html artifact.
    @State private var htmlReload = 0
    /// The comment list is open. Survives new comments, versions and
    /// launches; a click on a highlight opens it on that thread.
    @AppStorage("chat.artifact.commentsVisible") private var showComments = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let error = model.errorMessage ?? notice {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(model.errorMessage != nil ? .red : .secondary)
                    .padding(8)
            }
            content
            Divider()
            toolbar
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: ArtifactCardView.icon(for: model.displayed?.kind ?? "document"))
            Text(model.displayed?.title ?? model.key)
                .font(.headline)
                .lineLimit(1)
            if model.selectedArtifact?.edited == true && model.liveDraft == nil {
                Text("edited").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.canComment && !isHTML {
                Toggle(isOn: $showComments) {
                    Label(commentsLabel, systemImage: "sidebar.right")
                }
                .toggleStyle(.button)
                .buttonStyle(.borderless)
                .disabled(model.comments.comments.isEmpty)
                .help(commentsHelp)
                .accessibilityLabel("Comments")
            }
            if model.versions.count > 1 {
                Picker("Version", selection: $model.selectedVersion) {
                    Text("Latest").tag(Int?.none)
                    ForEach(model.versions) { version in
                        Text("v\(version.version)").tag(Optional(version.version))
                    }
                }
                .labelsHidden()
                .frame(width: 100)
            }
            if let expand { expand }
            Button(action: onClose) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Close")
                .accessibilityLabel("Close")
        }
        .padding(10)
    }

    /// An html artifact renders as a page: no passage comments on it.
    private var isHTML: Bool { model.displayed?.kind == "html" }

    /// The threads the list shows outside its Outdated/Resolved groups.
    private var commentCount: Int {
        model.comments.unsent.count + model.comments.sent.count
    }

    private var commentsLabel: String {
        commentCount == 0 ? "Comments" : "Comments (\(commentCount))"
    }

    private var commentsHelp: String {
        if model.comments.comments.isEmpty { return "Select a passage to comment on it" }
        return showComments ? "Hide the comments" : "Show the comments"
    }

    @ViewBuilder
    private var content: some View {
        if model.isEditing {
            TextEditor(text: $model.editText)
                .font(.system(.body, design: .monospaced))
                .padding(6)
        } else if let draft = model.displayed, draft.kind == "html", draft.isComplete {
            // Sandboxed: no network, no bridge, links open nothing (#535).
            SandboxedHTMLView(content: .page(draft.content), reloadToken: htmlReload)
        } else if model.canComment, let rendered = model.comments.rendered, !rendered.text.isEmpty, let draft = model.displayed {
            // The latest version: one view to read and to comment on.
            ArtifactCommentsView(
                comments: model.comments, rendered: rendered, fields: ArtifactField.fields(of: draft),
                canSend: canSendComments, showsList: $showComments, onSend: onSendComments
            )
        } else if let draft = model.displayed {
            // A streaming draft or an older version.
            ScrollView {
                ArtifactContentView(draft: draft)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView("Nothing here yet", systemImage: "doc")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            if model.isEditing {
                Button("Save") { model.saveEdit() }.keyboardShortcut(.defaultAction)
                Button("Cancel") { model.cancelEdit() }
            } else if let draft = model.displayed {
                Button("Edit") { model.beginEdit() }.disabled(model.liveDraft != nil)
                Button("Copy") { run(.copy(draft.content)) }
                Button("Export…") {
                    ArtifactExporter.export(draft) { notice = $0 }
                }
                ForEach(ArtifactActions.kindActions(for: draft, gmailConnected: gmailConnected, slackLinks: slackLinks), id: \.title) { item in
                    Button { run(item.action) } label: { Label(item.title, systemImage: item.systemImage) }
                }
                .disabled(!draft.isComplete)
                if draft.kind == "html" {
                    htmlActions(draft)
                }
            }
            Spacer()
        }
        .padding(10)
    }

    /// View-only: Reload and a big window (Present = full screen at once).
    /// The page never goes to a browser or any networked app (CHAT-05).
    private func htmlActions(_ draft: ArtifactDraft) -> some View {
        Group {
            Button { htmlReload += 1 } label: { Label("Reload", systemImage: "arrow.clockwise") }
                .help("Load the page again")
            Button {
                HTMLPreviewWindow.show(.page(draft.content), title: draft.title, fullScreen: false)
            } label: { Label("Open in Window", systemImage: "macwindow") }
            Button {
                HTMLPreviewWindow.show(.page(draft.content), title: draft.title, fullScreen: true)
            } label: { Label("Present", systemImage: "play.rectangle") }
                .help("Full screen; the arrow keys page through a deck, Esc leaves")
        }
        .disabled(!draft.isComplete)
    }

    private func run(_ action: ArtifactAction) {
        let outcome = ArtifactActionPerformer.perform(action)
        if case .copyThenOpen(_, let url) = action, outcome.copied {
            notice = url == nil ? "Copied to the clipboard." : "Copied to the clipboard — paste it into the opened draft."
        } else if case .copy = action, outcome.copied {
            notice = "Copied to the clipboard."
        } else {
            notice = nil
        }
    }
}

private struct ArtifactContentView: View {
    let draft: ArtifactDraft

    var body: some View {
        switch draft.kind {
        case "table":
            CSVGridView(rows: CSVTable.parse(draft.content))
        case "code":
            MarkdownView(text: "````\(draft.meta["language"] ?? "")\n\(draft.content)\n````")
        case "html":
            // Still being written: its source; the page renders once complete.
            MarkdownView(text: "````html\n\(draft.content)\n````")
        case "email", "slack", "event":
            VStack(alignment: .leading, spacing: 8) {
                let header = ArtifactField.fields(of: draft)
                if !header.isEmpty {
                    ArtifactFieldsHeader(fields: header)
                    Divider()
                }
                Text(draft.content).textSelection(.enabled)
            }
        default:
            MarkdownView(text: draft.content)
        }
    }
}

private struct CSVGridView: View {
    let rows: [[String]]

    var body: some View {
        let width = rows.map(\.count).max() ?? 0
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(0..<width, id: \.self) { column in
                            Text(column < row.count ? row[column] : "")
                                .fontWeight(index == 0 ? .semibold : .regular)
                                .textSelection(.enabled)
                        }
                    }
                    if index == 0 { Divider() }
                }
            }
        }
    }
}
