import SwiftUI
import WatchtowerCore

/// The Connections tab's first screen: a banner per service that needs the
/// owner, a card per source, and the assistant's tools. A card opens the
/// service's detail.
struct ConnectionsOverview: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ConnectionsOverviewContent(summaries: appState.connectionSummaries) { appState.openConnections($0) }
    }
}

/// The overview over given summaries; `onOpen` opens a service's detail.
struct ConnectionsOverviewContent: View {
    let summaries: [ConnectionSummary]
    let onOpen: (ConnectionService) -> Void

    private static let columns = [GridItem(.adaptive(minimum: 240), spacing: Spacing.medium, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.large) {
                header
                ForEach(summaries.filter(\.needsAttention)) { summary in
                    ConnectionAttentionBanner(summary: summary) { onOpen(summary.service) }
                }
                group("Sources", ConnectionService.sources)
                group("Tools for AI", ConnectionService.aiTools)
            }
            .padding(Spacing.page)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        HStack {
            Text("Connections")
                .font(.title2.weight(.bold))
            Spacer()
            Menu {
                ForEach(summaries.filter { !$0.blocked }) { summary in
                    Button(summary.service.label) { onOpen(summary.service) }
                }
            } label: {
                Label("Connect…", systemImage: "plus")
            }
            .menuStyle(.button)
            .fixedSize()
        }
    }

    private func group(_ title: String, _ services: [ConnectionService]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            HomeZoneTitle(title: title)
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: Spacing.medium) {
                ForEach(summaries.filter { services.contains($0.service) }) { summary in
                    ConnectionCard(summary: summary) { onOpen(summary.service) }
                }
            }
        }
    }
}

/// One service on the overview: name and status mark, account count, one status line.
struct ConnectionCard: View {
    let summary: ConnectionSummary
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: Spacing.small) {
                HStack(spacing: Spacing.regular) {
                    Image(systemName: summary.service.icon)
                        .foregroundStyle(.secondary)
                    Text(summary.service.label)
                        .font(.headline)
                    Spacer()
                    ConnectionStatusMark(summary: summary)
                }
                Text(summary.countLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(summary.statusLine)
                    .font(.caption)
                    .foregroundStyle(summary.needsAttention ? AnyShapeStyle(Tone.error) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Spacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .card()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(summary.service.label): \(summary.countLine), \(summary.statusLine)")
    }
}

/// "Slack · acme: token expired" with Reconnect, which opens the service.
struct ConnectionAttentionBanner: View {
    let summary: ConnectionSummary
    let onReconnect: () -> Void

    var body: some View {
        HStack(spacing: Spacing.regular) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Tone.warning)
            Text(line)
                .font(.callout)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Reconnect", action: onReconnect)
                .buttonStyle(.kitSecondary)
        }
        .padding(Spacing.medium)
        .card()
    }

    private var line: String {
        guard let first = summary.problems.first else { return "\(summary.service.label) needs attention" }
        let more = summary.problems.count > 1 ? " (and \(summary.problems.count - 1) more)" : ""
        return "\(summary.service.label) · \(first.name): \(first.problem)\(more)"
    }
}
