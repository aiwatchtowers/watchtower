import SwiftUI

/// Right pane of the memory browser: frontmatter header, rendered body with
/// tappable wiki-links, backlinks, and vault git history for one node.
struct MemoryNodeDetailView: View {
    @Bindable var vm: MemoryViewModel
    let detail: MemoryNodeDetail

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if detail.node.isDisputed {
                    disputeBanner
                }
                Divider()
                MarkdownText(text: detail.renderedBody)
                if !detail.backlinks.isEmpty {
                    backlinksSection
                }
                if !detail.history.isEmpty {
                    historySection
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                MemoryTypeChip(type: detail.node.type)
                if detail.node.status != "active" {
                    Text(detail.node.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if detail.node.tier == "long" {
                    Text("long-term")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if detail.node.isBelief {
                    MemoryConfidenceBar(confidence: detail.node.confidence)
                        .frame(width: 80)
                    Text(String(format: "%.0f%% confidence", detail.node.confidence * 100))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("Edit") { vm.startEditing() }
                    .help("Edit the vault file (committed as owner-edit by the next memory run)")
            }
            Text(detail.node.id)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if !detail.aliases.isEmpty {
                aliasesRow
            }
        }
    }

    private var aliasesRow: some View {
        HStack(spacing: 4) {
            Text("aka")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            ForEach(detail.aliases, id: \.self) { alias in
                Text(alias)
                    .font(.caption2.monospaced())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(Capsule())
            }
        }
    }

    private var disputeBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.bubble")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Dispute pending")
                    .font(.callout)
                    .fontWeight(.semibold)
                if let reason = detail.node.disputeReason, !reason.isEmpty {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("The secretary flagged this for your attention — expect a dashboard item.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Backlinks

    private var backlinksSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Linked from")
            ForEach(detail.backlinks) { backlink in
                Button {
                    Task { await vm.select(id: backlink.id) }
                } label: {
                    HStack(spacing: 6) {
                        MemoryTypeChip(type: backlink.type)
                        Text(backlink.title)
                            .font(.callout)
                            .foregroundStyle(Color.accentColor)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 4)
    }

    // MARK: - History

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("History")
            ForEach(detail.history) { commit in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(commit.day)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Text(commit.subject)
                        .font(.caption)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.top, 4)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .kerning(0.5)
    }
}

/// Whole-file owner-edit editor (MEM-03). Raw markdown including frontmatter —
/// the same contract as editing the vault in Obsidian.
struct MemoryNodeEditorSheet: View {
    @Bindable var vm: MemoryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(vm.detail?.node.displayTitle ?? "Edit node")
                    .font(.headline)
                Spacer()
            }
            TextEditor(text: $vm.editorText)
                .font(.body.monospaced())
                .frame(minWidth: 560, minHeight: 380)
            if let error = vm.editorError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Text("""
            Saved edits are committed as owner-edit by the next memory run. \
            Keep the frontmatter fences intact — a malformed file is quarantined (skipped, not deleted).
            """)
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { vm.cancelEditing() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { Task { await vm.saveEdit() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
    }
}
