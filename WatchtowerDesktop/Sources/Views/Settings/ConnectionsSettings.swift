import SwiftUI
import WatchtowerCore

/// Settings → Connections: the services live in the main window's
/// Connections tab now; this tab only points there.
struct ConnectionsSettings: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: Spacing.medium) {
            Image(systemName: SidebarDestination.connections.icon)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Slack, Google, Jira and your other accounts are in the Connections tab of the main window.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: PaneWidth.narrowPage)
            Button("Open Connections") {
                appState.openConnections()
                appState.bringMainWindowForward()
            }
            .buttonStyle(.kitPrimary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The line over a connection the organization's policy forbids (#608): its
/// accounts stay but no longer sync, and their data is kept.
struct SourceBlockedNotice: View {
    static let title = "Blocked by your organization"

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Label(Self.title, systemImage: "lock.fill")
                .font(.callout.weight(.medium))
            Text("Your organization's policy does not allow this source. Existing accounts stop syncing and keep their data; "
                + "nothing new can be connected.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .padding(.horizontal, Spacing.page)
        .padding(.top, Spacing.medium)
    }
}
