import SwiftUI
import WatchtowerCore

struct ArtifactPanelView: View {
    @Bindable var model: ArtifactPanelModel
    let gmailConnected: Bool
    let slackLinks: SlackLinkResolver?
    var onClose: () -> Void

    @State private var notice: String?

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
            Button(action: onClose) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Close")
                .accessibilityLabel("Close")
        }
        .padding(10)
    }

    @ViewBuilder
    private var content: some View {
        if model.isEditing {
            TextEditor(text: $model.editText)
                .font(.system(.body, design: .monospaced))
                .padding(6)
        } else if let draft = model.displayed {
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
            }
            Spacer()
        }
        .padding(10)
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
        case "email":
            fields([("To", draft.meta["to"]), ("Cc", draft.meta["cc"]), ("Subject", draft.meta["subject"])])
        case "slack":
            fields([("Channel", draft.meta["channel"] ?? draft.meta["permalink"])])
        case "event":
            fields([("Start", draft.meta["start"]), ("End", draft.meta["end"]),
                    ("Attendees", draft.meta["attendees"]), ("Location", draft.meta["location"])])
        default:
            MarkdownView(text: draft.content)
        }
    }

    private func fields(_ items: [(String, String?)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                ForEach(items.filter { !($0.1 ?? "").isEmpty }, id: \.0) { name, value in
                    GridRow {
                        Text(name).foregroundStyle(.secondary)
                        Text(value ?? "").textSelection(.enabled)
                    }
                }
            }
            Divider()
            Text(draft.content).textSelection(.enabled)
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
