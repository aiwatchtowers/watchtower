import SwiftUI
import WatchtowerCore

/// A person's card: work topics and how to work with them, never activity
/// scores or judgments (#1769, A12). Stop card for this person asks first,
/// in place of the card.
struct PersonDetailView: View {
    let card: PeopleCard
    let userName: String
    let history: [PeopleCard]
    let userNameResolver: (String) -> String
    var onClose: (() -> Void)?
    var isCurrentUser: Bool = false
    var profile: UserProfile?
    var onUpdateConnections: (([String], [String], String) -> Void)?
    var allCards: [PeopleCard] = []
    var dbManager: DatabaseManager?
    /// Runs Stop card for this person; nil hides the action.
    var onStopCard: (() -> Void)?
    /// Dismisses `actionError`.
    var onDismissError: (() -> Void)?
    var isStopPending = false
    /// The last Stop card failure for this person.
    var actionError: String?
    /// The Stop card confirm is open (a design shot opens it directly).
    @State var confirmingStop = false

    @State private var selectedTab = 0  // 0 = Overview, 1 = Connections
    @State private var expertiseTags: [String] = []

    private var displayName: String { "@\(userName)" }

    var body: some View {
        VStack(spacing: 0) {
            if isCurrentUser {
                KitSegmentedPicker(title: PeopleCardCopy.viewPickerTitle, selection: $selectedTab, segments: [
                    KitSegment(value: 0, title: PeopleCardCopy.overviewTab),
                    KitSegment(value: 1, title: PeopleCardCopy.connectionsTab)
                ])
                .padding(.horizontal, Spacing.page)
                .padding(.top, Spacing.medium)
                .padding(.bottom, Spacing.small)
            }

            if selectedTab == 0 || !isCurrentUser {
                overviewContent
            } else {
                ConnectionsView(
                    profile: profile,
                    allCards: allCards,
                    userNameResolver: userNameResolver,
                    onUpdateConnections: onUpdateConnections
                )
            }
        }
        .detailBackground()
    }

    private var overviewContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.large) {
                header
                if let actionError {
                    WriteErrorBanner(message: actionError) { onDismissError?() }
                }
                if confirmingStop {
                    stopConfirm
                } else {
                    Text(PeopleCardCopy.basisLine(messages: card.messageCount, channels: card.channelsActive))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if isCurrentUser { profileContextSection }
                    insufficientDataBanner
                    summarySection
                    decisionRoleSection
                    communicationGuideSection
                    listSection(PeopleCardCopy.tacticsTitle, "lightbulb", card.parsedTactics)
                    listSection(PeopleCardCopy.accomplishmentsTitle, "checkmark.circle", card.parsedAccomplishments)
                    listSection(PeopleCardCopy.highlightsTitle, "star", card.parsedHighlights)
                    expertiseSection
                    historySection
                }
            }
            .controlSize(.small)
            .padding(Spacing.page)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .task(id: card.userID) {
            loadExpertise()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
            Text(displayName).font(.title2.weight(.semibold))
            Text(PeopleCardCopy.period(from: card.periodFromDate, to: card.periodToDate))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: Spacing.medium)
            if let onStopCard, !confirmingStop {
                Button(PeopleCardCopy.stopCard) { confirmingStop = true }
                    .buttonStyle(.kitQuiet)
                    .disabled(isStopPending)
            }
            if let onClose {
                Button { onClose() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.kitIcon(isOn: false))
                    .help(PeopleCardCopy.close)
            }
        }
    }

    // MARK: - Stop card confirm

    private var stopConfirm: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            Text(PeopleCardCopy.stopTitle(name: displayName)).font(.headline)
            Text(PeopleCardCopy.stopBody(name: displayName))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Spacing.regular) {
                Spacer()
                Button(PeopleCardCopy.cancel) { confirmingStop = false }
                    .buttonStyle(.kitSecondary)
                    .keyboardShortcut(.cancelAction)
                Button(PeopleCardCopy.stopConfirm) {
                    confirmingStop = false
                    onStopCard?()
                }
                .buttonStyle(.kitDestructive)
                .disabled(isStopPending)
            }
        }
        .padding(Spacing.medium)
        .card()
    }

    // MARK: - Profile Context (My Card only)

    @ViewBuilder
    private var profileContextSection: some View {
        if let profile, !profile.customPromptContext.isEmpty {
            PeopleSection(title: PeopleCardCopy.profileContextTitle, icon: "brain") {
                Text(profile.customPromptContext).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var insufficientDataBanner: some View {
        if card.isInsufficientData {
            Label(PeopleCardCopy.insufficientData, systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var summarySection: some View {
        if !card.summary.isEmpty {
            Text(card.summary).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var decisionRoleSection: some View {
        if !card.decisionRole.isEmpty || !card.decisionStyle.isEmpty {
            PeopleSection(title: PeopleCardCopy.decisionRoleTitle, icon: "arrow.triangle.branch") {
                if !card.decisionRole.isEmpty {
                    Chip(text: card.decisionRole, color: Tone.status("blue"))
                }
                if !card.decisionStyle.isEmpty {
                    Text(card.decisionStyle).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var communicationGuideSection: some View {
        if !card.communicationGuide.isEmpty {
            PeopleSection(title: PeopleCardCopy.guideTitle, icon: "bubble.left.and.text.bubble.right") {
                Text(card.communicationGuide).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func listSection(_ title: String, _ icon: String, _ items: [String]) -> some View {
        if !items.isEmpty {
            PeopleSection(title: title, icon: icon) {
                ForEach(items, id: \.self) { item in
                    Text("• " + item).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Expertise (Jira)

    /// The Jira components and labels of the person's issues. No per-person
    /// counts, cycle time or velocity (#1769, A12).
    @ViewBuilder
    private var expertiseSection: some View {
        let tags = expertiseTags
        if !tags.isEmpty {
            PeopleSection(title: PeopleCardCopy.expertiseTitle, icon: "tag") {
                FlowLayout(spacing: Spacing.compact) {
                    ForEach(tags, id: \.self) { tag in
                        Chip(text: tag, color: Tone.status("purple"))
                    }
                }
            }
        }
    }

    private func loadExpertise() {
        guard JiraQueries.isConnected(), let db = dbManager else {
            expertiseTags = []
            return
        }
        let now = Date()
        let from = Calendar.current.date(byAdding: .day, value: -30, to: now) ?? now
        do {
            let stats = try db.dbPool.read { database in
                try JiraQueries.fetchDeliveryStats(database, slackID: card.userID, from: from, to: now)
            }
            expertiseTags = stats.components + stats.labels
        } catch {
            expertiseTags = []
        }
    }

    // MARK: - History

    @ViewBuilder
    private var historySection: some View {
        if history.count > 1 {
            PeopleSection(title: PeopleCardCopy.historyTitle, icon: "clock") {
                ForEach(history) { entry in
                    HStack(spacing: Spacing.regular) {
                        Text(PeopleCardCopy.period(from: entry.periodFromDate, to: entry.periodToDate))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if !entry.decisionRole.isEmpty {
                            Text(entry.decisionRole).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

/// The person view after Stop card for this person: no card, and the way
/// back (#1769, A14).
struct PersonStoppedView: View {
    let userName: String
    var onClose: (() -> Void)?
    let onMakeAgain: () -> Void
    var onDismissError: (() -> Void)?
    var isPending = false
    var actionError: String?

    var body: some View {
        let name = "@\(userName)"
        VStack(alignment: .leading, spacing: Spacing.large) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                Text(name).font(.title2.weight(.semibold))
                Spacer(minLength: Spacing.medium)
                if let onClose {
                    Button { onClose() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.kitIcon(isOn: false))
                        .help(PeopleCardCopy.close)
                }
            }
            if let actionError {
                WriteErrorBanner(message: actionError) { onDismissError?() }
            }
            VStack(alignment: .leading, spacing: Spacing.regular) {
                Text(PeopleCardCopy.stoppedLine(name: name))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(PeopleCardCopy.makeAgain, action: onMakeAgain)
                    .buttonStyle(.kitSecondary)
                    .disabled(isPending)
            }
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .padding(Spacing.page)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .detailBackground()
    }
}

// MARK: - Supporting Views

/// A titled card section of the People screens.
struct PeopleSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            Label(title, systemImage: icon).font(.subheadline.weight(.semibold))
            content
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}
