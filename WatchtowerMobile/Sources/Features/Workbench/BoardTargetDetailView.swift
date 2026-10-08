import SwiftUI

/// A board target, read-only: status, priority, progress, intent, branch
/// and PR, sub-targets, linked sessions, open asks and the comments.
struct BoardTargetDetailView: View {
    let replica: WorkbenchReplicaModel
    let targetID: Int64

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if let detail = BoardTargetDetailModel(targetID: targetID, snapshot: replica.snapshot, now: context.date) {
                content(detail)
            } else {
                ContentUnavailableView(
                    "Target not found",
                    systemImage: "circle.dashed",
                    description: Text("It is no longer on the board.")
                )
            }
        }
        .navigationTitle("#\(targetID)")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func content(_ detail: BoardTargetDetailModel) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(detail.title).font(.headline)
                    HStack(spacing: 6) {
                        Image(systemName: detail.row.statusGlyph).foregroundStyle(detail.row.statusTone.color)
                        Text(detail.statusLabel)
                        if let priority = detail.row.priorityLabel {
                            Text(priority)
                                .font(.caption.monospaced().weight(.semibold))
                                .foregroundStyle(detail.row.priorityTone.color)
                        }
                        if let progress = detail.row.progressText {
                            Text(progress).foregroundStyle(.secondary)
                        }
                    }
                    .font(.subheadline)
                }
            }
            if !detail.intent.isEmpty {
                Section("Intent") { Text(detail.intent) }
            }
            if !detail.branch.isEmpty || !detail.pr.isEmpty {
                Section("Code") {
                    if !detail.branch.isEmpty {
                        LabeledContent("Branch") { Text(detail.branch).font(.callout.monospaced()) }
                    }
                    if !detail.pr.isEmpty {
                        LabeledContent("PR", value: detail.pr.allSatisfy(\.isNumber) ? "#\(detail.pr)" : detail.pr)
                    }
                }
            }
            if !detail.asks.isEmpty {
                Section("Waiting for you") {
                    ForEach(detail.asks) { WaitingCardView(card: $0).listRowSeparator(.hidden) }
                }
            }
            if !detail.children.isEmpty {
                Section("Targets") {
                    ForEach(detail.children) { child in
                        NavigationLink(value: BoardTargetRoute(id: child.id)) { BoardRowView(row: child) }
                    }
                }
            }
            if !detail.sessions.isEmpty {
                Section("Sessions") {
                    ForEach(detail.sessions) { row in
                        NavigationLink(value: SessionRoute(id: row.id)) { SessionRowView(row: row) }
                    }
                }
            }
            if !detail.comments.isEmpty {
                Section("Comments") {
                    ForEach(detail.comments) { comment in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(comment.author).font(.caption.weight(.semibold))
                                Text(comment.age).font(.caption).foregroundStyle(.secondary)
                                if comment.isResolved {
                                    Text("Resolved").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Text(comment.body).font(.subheadline)
                        }
                        .padding(.leading, comment.isReply ? 16 : 0)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}
