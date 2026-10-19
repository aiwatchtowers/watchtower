import SwiftUI
import WatchtowerCore

/// Home's Getting ready zone, compact: "N of M ready" in the header, one row
/// per feature still preparing, the ready ones on one line of links, a
/// Connect row per missing source, and the first sync's line on top while it
/// runs.
struct GettingReadyZoneView: View {
    let zone: GettingReadyZone
    let firstSync: FirstSyncLine?
    let digestsTurnOn: DigestsTurnOnState
    let onLink: (HomeLink) -> Void
    let onHide: () -> Void

    init(
        zone: GettingReadyZone,
        firstSync: FirstSyncLine?,
        digestsTurnOn: DigestsTurnOnState = .idle,
        onLink: @escaping (HomeLink) -> Void,
        onHide: @escaping () -> Void
    ) {
        self.zone = zone
        self.firstSync = firstSync
        self.digestsTurnOn = digestsTurnOn
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
        let ready = cards.filter { $0.readiness == .ready }
        let offering = Self.digestsOfferingCards(cards, digestsTurnOn)
        return HomeZone(title: "Getting ready", detail: Self.progressDetail(ready: ready.count, of: cards.count)) {
            Button(action: onHide) {
                Label("Hide", systemImage: "xmark")
                    .labelStyle(.iconOnly)
            }
            .help("Hide")
            .accessibilityLabel("Hide Getting ready")
        } content: {
            if let firstSync {
                FirstSyncBanner(line: firstSync)
                    .homeZoneInset()
            }
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: Self.rowMinWidth), spacing: Spacing.page, alignment: .top)],
                alignment: .leading, spacing: 0
            ) {
                ForEach(cards.filter { $0.readiness != .ready }, id: \.feature) { card in
                    GettingReadyRowView(
                        card: card, digestsTurnOn: offering.contains(card.feature) ? digestsTurnOn : nil, onLink: onLink)
                }
            }
            if !ready.isEmpty {
                GettingReadyReadyLine(cards: ready, onLink: onLink)
            }
            ForEach(sourceRows, id: \.source) { row in
                GettingReadySourceRowView(text: Self.connectLine(row), source: row.source, onLink: onLink)
                    .homeZoneInset()
            }
        }
    }

    /// The narrowest a preparing row gets before the grid drops a column.
    static let rowMinWidth: CGFloat = 320

    /// "6 of 11 ready"; no cards (only Connect rows) shows none.
    static func progressDetail(ready: Int, of total: Int) -> String? {
        total > 0 ? "\(ready) of \(total) ready" : nil
    }

    /// The cards that may offer the Slack Digests Turn on: each one waiting
    /// on it, but a failed Turn on's error and Try again only once, on the
    /// first card it concerns (#575).
    static func digestsOfferingCards(_ cards: [GettingReadyCard], _ state: DigestsTurnOnState) -> Set<ReadinessFeature> {
        let concerned = cards.filter { $0.feature.runsOnlyWithDigests && $0.readiness != nil && $0.readiness != .ready }
        guard state.error != nil else { return Set(concerned.map(\.feature)) }
        return Set(concerned.prefix(1).map(\.feature))
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
        return "\(row.source.actionTitle) to get \(joinedNames(titles))"
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

/// The Slack Digests Turn on as a Home card shows it (#575): the same
/// progress, busy and error the tabs' empty states show.
struct DigestsTurnOnState: Equatable {
    /// Some empty-state Turn on is running (one at a time).
    var busy = false
    /// The running one is Slack Digests.
    var isTurningOn = false
    /// `AppState.emptyStateTurnOnError(for: "slack-digests")`.
    var error: String?

    static let idle = Self()
}

/// One feature still preparing, on one line: its status dot, name and
/// readiness line, and the fix when there is one (Turn on Slack Digests,
/// Open Connections, Choose Jira boards). What it makes is the row's tooltip.
struct GettingReadyRowView: View {
    let card: GettingReadyCard
    /// nil: this card offers no Slack Digests Turn on (another card carries it).
    let digestsTurnOn: DigestsTurnOnState?
    let onLink: (HomeLink) -> Void

    init(card: GettingReadyCard, digestsTurnOn: DigestsTurnOnState? = .idle, onLink: @escaping (HomeLink) -> Void) {
        self.card = card
        self.digestsTurnOn = digestsTurnOn
        self.onLink = onLink
    }

    /// Slack Digests' id when this card offers to turn it on: the feature
    /// waits on it, or its Turn on failed and only a retry restarts
    /// (`FeatureReadiness.turnOnFeatureID`, as the tabs do).
    private var digestsTurnOnID: String? {
        guard let digestsTurnOn, card.feature.runsOnlyWithDigests, card.readiness != .ready, card.readiness != nil else {
            return nil
        }
        let id = FeatureReadiness.turnOnFeatureID(
            for: card.feature, readiness: card.readiness, digestsTurnOnFailed: digestsTurnOn.error != nil)
        return id == ReadinessFeature.digests.featureID ? id : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                HomeStatusDot(color: Self.color(card.tone))
                Text(card.copy.title)
                    .fontWeight(.semibold)
                if let readiness = card.readiness {
                    Text(FeatureReadiness.line(readiness))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
                fix
            }
            if digestsTurnOnID != nil, let error = digestsTurnOn?.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Tone.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, Spacing.compact)
        .homeZoneInset()
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(card.copy.whatItIs)
    }

    @ViewBuilder
    private var fix: some View {
        if let featureID = digestsTurnOnID, let digestsTurnOn {
            if digestsTurnOn.isTurningOn {
                ProgressView().controlSize(.small)
            }
            Button(digestsTurnOn.error == nil ? "Turn on Slack Digests" : "Try again") {
                onLink(.turnOn(featureID: featureID))
            }
            .buttonStyle(.link)
            .disabled(digestsTurnOn.busy)
        }
        if case .needsSource(let source) = card.readiness, source.isOwnerIdentity || source == .jiraBoards {
            // No owner yet (OWNER-02): the fix is in Settings →
            // Connections. No Jira board picked (#572): Boards.
            Button(source.isOwnerIdentity ? "Open Connections" : source.actionTitle) {
                onLink(.connect(source))
            }
            .buttonStyle(.link)
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

/// "Ready: Briefing · Day plan · …": the ready features on one wrapping
/// line, each a link that opens it.
private struct GettingReadyReadyLine: View {
    let cards: [GettingReadyCard]
    let onLink: (HomeLink) -> Void

    var body: some View {
        FlowLayout(spacing: Spacing.medium) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                HomeStatusDot(color: GettingReadyRowView.color(.ready))
                Text("Ready")
                    .foregroundStyle(.secondary)
            }
            ForEach(cards, id: \.feature) { card in
                Button(card.copy.title) { onLink(.feature(card.feature)) }
                    .buttonStyle(.link)
                    .accessibilityLabel("Open \(card.copy.title)")
            }
        }
        .padding(.vertical, Spacing.compact)
        .homeZoneInset()
    }
}

/// "Connect <Source> to get …" with its Connect button, dashed.
private struct GettingReadySourceRowView: View {
    let text: String
    let source: ReadinessSource
    let onLink: (HomeLink) -> Void

    var body: some View {
        HStack(spacing: Spacing.medium) {
            Text(text)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(source.actionTitle) { onLink(.connect(source)) }
        }
        .padding(.horizontal, Spacing.large)
        .padding(.vertical, Spacing.cozy)
        .background(HomeDashedOutline())
    }
}
