import SwiftUI

/// What Day Plan and Briefings show in place of Generate while no connected
/// account yields an owner identity (`AppState.owner`, OWNER-02): the CLI
/// would refuse the run with "no owner identity", so the screen says why up
/// front and points at the fix.
struct NoOwnerEmptyState: View {
    /// Opens Settings on the Connections tab.
    let openConnections: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Connect Slack, Google or Jira so Watchtower knows who you are")
                .font(.headline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Open Connections", action: openConnections)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
