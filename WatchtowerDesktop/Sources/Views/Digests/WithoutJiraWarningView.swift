import SwiftUI

/// Warning cards for channels that have digests but no linked Jira issues.
struct WithoutJiraWarningView: View {
    let warnings: [WithoutJiraRow]

    var body: some View {
        if !warnings.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Untracked Discussions", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.orange)

                ForEach(warnings) { warning in
                    HStack(spacing: 8) {
                        Image(systemName: "number")
                            .font(.caption)
                            .foregroundStyle(.orange)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("#\(warning.channelName)")
                                .font(.caption)
                                .fontWeight(.medium)

                            Text("discussed \(warning.distinctDays) days (\(warning.messageCount) messages), no Jira issue")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
}
