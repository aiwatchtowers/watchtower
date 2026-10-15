import SwiftUI
import WatchtowerCore

/// Home's Getting ready zone: the features still preparing, a Connect row per
/// missing source, and the first sync's line on top while it runs. No
/// counters: each card says only its own readiness.
struct GettingReadyZoneView: View {
    let zone: GettingReadyZone
    let firstSync: FirstSyncLine?
    let onLink: (HomeLink) -> Void
    let onHide: () -> Void

    init(
        zone: GettingReadyZone,
        firstSync: FirstSyncLine?,
        onLink: @escaping (HomeLink) -> Void,
        onHide: @escaping () -> Void
    ) {
        self.zone = zone
        self.firstSync = firstSync
        self.onLink = onLink
        self.onHide = onHide
    }

    var body: some View {
        switch zone {
        case .hidden:
            EmptyView()
        case .allReady:
            Label {
                Text("Everything's ready")
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        case let .shown(cards, sourceRows):
            shownZone(cards: cards, sourceRows: sourceRows)
        }
    }

    private func shownZone(cards: [GettingReadyCard], sourceRows: [GettingReadySourceRow]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HomeZoneHeader(title: "Getting ready", subtitle: "Watchtower is preparing these from your sources") {
                Button(action: onHide) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Hide")
                .accessibilityLabel("Hide Getting ready")
            }
            if let firstSync {
                FirstSyncBanner(line: firstSync)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12, alignment: .top)], spacing: 12) {
                ForEach(cards, id: \.feature) { card in
                    GettingReadyCardView(card: card, onLink: onLink)
                }
            }
            ForEach(sourceRows, id: \.source) { row in
                GettingReadySourceRowView(text: Self.connectLine(row), source: row.source, onLink: onLink)
            }
        }
    }

    /// "Connect Jira to get Boards, Workload, Blockers, Project Map and
    /// Releases": the tabs the row's features fill, each named once.
    static func connectLine(_ row: GettingReadySourceRow) -> String {
        var titles: [String] = []
        for feature in row.features {
            for tab in featureTabs(for: feature) where !titles.contains(tab.title) {
                titles.append(tab.title)
            }
        }
        return "Connect \(row.source.displayName) to get \(joinedNames(titles))"
    }

    /// Jira fills five tabs; every other feature its Open's tab.
    private static func featureTabs(for feature: ReadinessFeature) -> [SidebarDestination] {
        feature == .jira
            ? [.boards, .workload, .blockers, .projectMap, .releases]
            : [AppState.homeDestination(for: feature)]
    }

    /// "A", "A and B", "A, B and C".
    private static func joinedNames(_ items: [String]) -> String {
        guard let last = items.last, items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }
}

/// The first sync's title and heartbeat, highlighted above the cards.
private struct FirstSyncBanner: View {
    let line: FirstSyncLine

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(line.title)
                    .fontWeight(.semibold)
                Text(line.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(shape.fill(Color.accentColor.opacity(0.08)))
        .overlay(shape.strokeBorder(Color.accentColor.opacity(0.25)))
    }
}

/// One feature: its name, what it makes, and its readiness.
struct GettingReadyCardView: View {
    let card: GettingReadyCard
    let onLink: (HomeLink) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(card.copy.title)
                .font(.headline)
            Text(card.copy.whatItIs)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            readiness
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(HomeCardBackground())
    }

    @ViewBuilder
    private var readiness: some View {
        if card.readiness == .ready {
            HStack(spacing: 8) {
                HomeStatusDot(color: Self.color(card.tone))
                Text("Ready")
                    .font(.callout)
                Spacer(minLength: 0)
                Button("Open") { onLink(.feature(card.feature)) }
                    .buttonStyle(.link)
            }
        } else if let readiness = card.readiness {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                HomeStatusDot(color: Self.color(card.tone))
                Text(FeatureReadiness.line(readiness))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    static func color(_ tone: ReadinessTone) -> Color {
        switch tone {
        case .ready: .green
        case .preparing: .blue
        case .waiting: .gray
        case .error: .orange
        }
    }
}

/// "Connect <Source> to get …" with its Connect button, dashed.
private struct GettingReadySourceRowView: View {
    let text: String
    let source: ReadinessSource
    let onLink: (HomeLink) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(text)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Connect \(source.displayName)") { onLink(.connect(source)) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(HomeCardBackground(dashed: true))
    }
}
