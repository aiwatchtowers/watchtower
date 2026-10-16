import SwiftUI
import WatchtowerCore

/// A subagent's run: the task it was given, what it said on the way and its
/// final report, read once when the sheet opens.
struct SessionChatSubagentSheet: View {
    let store: SessionFeedStore
    let entry: SessionFeedEntry
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [SessionFeedEntry] = []
    @State private var loading = true
    @State private var error: String?

    private var subagent: SessionFeedSubagent? { entry.subagent }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(subagent?.type.isEmpty == false ? subagent?.type ?? "" : "Subagent").font(.headline)
                    if let description = subagent?.description, !description.isEmpty {
                        Text(description).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            content
        }
        .frame(minWidth: 480, minHeight: 420)
        .task(id: entry.id) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error {
            Text(error).foregroundStyle(.secondary).padding().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if entries.isEmpty {
            Text("Nothing recorded for this subagent").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, item in
                        if let heading = heading(index) {
                            Text(heading).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        SessionChatRow(entry: item)
                    }
                }
                .padding(14)
            }
        }
    }

    /// The first owner line is the task given; the last agent line of a run
    /// with more than one is its report.
    private func heading(_ index: Int) -> String? {
        let item = entries[index]
        if index == 0, item.kind == "owner" { return "Task" }
        let agents = entries.filter { $0.kind == "agent" }
        if agents.count > 1, item.id == agents.last?.id { return "Report" }
        return nil
    }

    private func load() async {
        loading = true
        error = nil
        do {
            entries = try await store.subagentFeed(entry.subagent?.toolUseID ?? "")
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
        loading = false
    }
}
