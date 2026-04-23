import SwiftUI

/// Shows linked Jira issues (blocks, blocked by, relates to) for a given issue key.
struct JiraLinkedIssuesView: View {
    let issueKey: String
    let siteURL: String?
    @Environment(AppState.self) private var appState
    @State private var blocks: [JiraIssue] = []
    @State private var blockedBy: [JiraIssue] = []
    @State private var relatesTo: [JiraIssue] = []
    @State private var isLoaded = false

    var body: some View {
        if isLoaded && (blocks.isEmpty && blockedBy.isEmpty && relatesTo.isEmpty) {
            EmptyView()
        } else if isLoaded {
            VStack(alignment: .leading, spacing: 6) {
                linkSection(title: "Blocks", icon: "xmark.octagon.fill", color: .red, issues: blocks)
                linkSection(title: "Blocked by", icon: "exclamationmark.triangle.fill", color: .orange, issues: blockedBy)
                linkSection(title: "Relates to", icon: "link", color: .blue, issues: relatesTo)
            }
            .padding(.leading, 16)
        } else {
            Color.clear
                .frame(height: 0)
                .task { loadLinks() }
        }
    }

    @ViewBuilder
    private func linkSection(
        title: String,
        icon: String,
        color: Color,
        issues: [JiraIssue]
    ) -> some View {
        if !issues.isEmpty {
            LinkedIssueSection(
                title: title,
                icon: icon,
                color: color,
                issues: issues,
                siteURL: siteURL
            )
        }
    }

    private func loadLinks() {
        guard let dbManager = appState.databaseManager else {
            isLoaded = true
            return
        }
        let result = try? dbManager.dbPool.read { db in
            try JiraQueries.fetchLinkedIssuesGrouped(db, issueKey: issueKey)
        }
        if let result {
            blocks = result.blocks
            blockedBy = result.blockedBy
            relatesTo = result.relatesTo
        }
        isLoaded = true
    }
}

// MARK: - Linked Issue Section with disclosure

private struct LinkedIssueSection: View {
    let title: String
    let icon: String
    let color: Color
    let issues: [JiraIssue]
    let siteURL: String?

    @State private var showAll = false
    private let compactLimit = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(color)
                Text("(\(issues.count))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            let displayedIssues = showAll ? issues : Array(issues.prefix(compactLimit))
            ForEach(displayedIssues, id: \.key) { issue in
                JiraBadgeView(
                    issue: issue,
                    siteURL: siteURL
                )
            }

            if issues.count > compactLimit && !showAll {
                Button {
                    withAnimation { showAll = true }
                } label: {
                    Text("Show all \(issues.count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
