import SwiftUI
import WatchtowerCore

/// Where a briefing item's deep link goes. `AppState.openBriefingLink`
/// carries it out; the sections only emit it.
enum BriefingLink: Equatable {
    /// A track, or the tracks list when the item names none.
    case track(Int?)
    /// A digest, or the digests list.
    case digest(Int?)
    /// A person, or the people list.
    case person(String?)
    /// A workbench's board, or the Workbench tab.
    case workbench(Int64?)
    case target(Int)

    /// The link of an attention item's `source_type`/`source_id`; nil for a
    /// type with nowhere to go.
    init?(sourceType: String?, sourceID: String?) {
        switch sourceType {
        case "track": self = .track(sourceID.flatMap { Int($0) })
        case "digest": self = .digest(sourceID.flatMap { Int($0) })
        case "people": self = .person(sourceID)
        // A workbench; the stored source_type predates the rename (spec 2026-10-02 A1).
        case "project": self = .workbench(sourceID.flatMap { Int64($0) })
        default: return nil
        }
    }
}

/// What a briefing item's **Make a Task** makes a target from (R9).
enum BriefingTaskSource: Equatable {
    case attention(AttentionItem)
    case coaching(CoachingItem)
}

/// A briefing's sections — Needs you, Your day, What happened, Team pulse,
/// Coaching — with their deep links, for the Inbox's Your day card. No
/// header and no sheet: the card owns the header, and an item's
/// **Make a Task** creates the target at once (`onMakeTask`, which returns
/// the failure to show, or nil). A section with nothing in it is not drawn.
struct BriefingSectionsView: View {
    let briefing: Briefing
    var onOpen: (BriefingLink) -> Void = { _ in }
    var onMakeTask: (BriefingTaskSource) async -> String? = { _ in nil }

    @State private var makingTask = false
    @State private var makeTaskError: String?
    @State private var jiraConnected = false
    @State private var jiraSiteURL: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.page) {
            if let makeTaskError {
                WriteErrorBanner(message: makeTaskError) { self.makeTaskError = nil }
            }
            needsYouSection
            yourDaySection
            whatHappenedSection
            teamPulseSection
            coachingSection
        }
        .task { await loadJiraConfig() }
    }

    /// Jira link badges need the connection and site; both are read off the
    /// main thread (a directory listing and a database read), once per
    /// appearance.
    private func loadJiraConfig() async {
        jiraConnected = await Task.detached { JiraQueries.isConnected() }.value
        jiraSiteURL = await JiraConfigHelper.siteURL()
    }

    private func makeTask(_ source: BriefingTaskSource) {
        guard !makingTask else { return }
        makingTask = true
        Task {
            makeTaskError = await onMakeTask(source)
            makingTask = false
        }
    }

    private func makeTaskButton(_ source: BriefingTaskSource) -> some View {
        Button("Make a Task") { makeTask(source) }
            .buttonStyle(.kitQuiet)
            .controlSize(.small)
            .disabled(makingTask)
    }

    // MARK: - Needs you

    @ViewBuilder
    private var needsYouSection: some View {
        let items = briefing.parsedAttention
        if !items.isEmpty {
            section("Needs you", icon: "exclamationmark.triangle.fill") {
                ForEach(items) { item in
                    VStack(alignment: .trailing, spacing: Spacing.small) {
                        attentionCard(item)
                        if item.suggestTarget == true {
                            makeTaskButton(.attention(item))
                        }
                    }
                }
            }
        }
    }

    private func attentionCard(_ item: AttentionItem) -> some View {
        let link = BriefingLink(sourceType: item.sourceType, sourceID: item.sourceID)
        return itemButton(link) {
            HStack(alignment: .top, spacing: Spacing.regular) {
                priorityIcon(item.priority)
                VStack(alignment: .leading, spacing: Spacing.small) {
                    itemText(item.text)
                    if let reason = item.reason, !reason.isEmpty {
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: Spacing.small) {
                        if let sourceType = item.sourceType {
                            sourceLabel(type: sourceType)
                        }
                        jiraKeyBadges(in: item.text)
                        if let reason = item.reason {
                            jiraKeyBadges(in: reason)
                        }
                    }
                }
                Spacer()
                if link != nil { chevron }
            }
        }
    }

    // MARK: - Your day

    @ViewBuilder
    private var yourDaySection: some View {
        let items = briefing.parsedYourDay
        if !items.isEmpty {
            section("Your day", icon: "calendar") {
                ForEach(items) { item in
                    yourDayCard(item)
                }
            }
        }
    }

    private func yourDayCard(_ item: YourDayItem) -> some View {
        let link: BriefingLink? = item.targetID.map { .target($0) } ?? item.trackID.map { .track($0) }
        return itemButton(link) {
            HStack(alignment: .top, spacing: Spacing.regular) {
                priorityIcon(item.priority)
                VStack(alignment: .leading, spacing: Spacing.small) {
                    itemText(item.text)
                    HStack(spacing: Spacing.compact) {
                        if let status = item.status, !status.isEmpty {
                            Chip(text: status.capitalized, color: status == "active" ? Tone.success : .secondary)
                        }
                        if let ownership = item.ownership, !ownership.isEmpty {
                            Text(ownership).font(.caption2).foregroundStyle(.secondary)
                        }
                        if let due = item.dueDate, !due.isEmpty {
                            Label(due, systemImage: "clock").font(.caption2).foregroundStyle(.secondary)
                        }
                        jiraKeyBadges(in: item.text)
                    }
                }
                Spacer()
                if link != nil { chevron }
            }
        }
    }

    // MARK: - What happened

    @ViewBuilder
    private var whatHappenedSection: some View {
        let items = briefing.parsedWhatHappened
        if !items.isEmpty {
            section("What happened", icon: "newspaper.fill") {
                ForEach(items) { item in
                    whatHappenedCard(item)
                }
            }
        }
    }

    private func whatHappenedCard(_ item: WhatHappenedItem) -> some View {
        let link = item.digestID.map { BriefingLink.digest($0) }
        return itemButton(link) {
            VStack(alignment: .leading, spacing: Spacing.small) {
                HStack(spacing: Spacing.compact) {
                    if let channel = item.channelName, !channel.isEmpty {
                        Text("#\(channel)").font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
                    }
                    if let itemType = item.itemType, !itemType.isEmpty {
                        Chip(text: itemType, color: .secondary)
                    }
                    if let importance = item.importance, !importance.isEmpty {
                        Text(importance.capitalized).font(.caption2).foregroundStyle(Tone.priority(importance))
                    }
                    Spacer()
                    if link != nil { chevron }
                }
                itemText(item.text)
            }
        }
    }

    // MARK: - Team pulse

    @ViewBuilder
    private var teamPulseSection: some View {
        let items = briefing.parsedTeamPulse
        if !items.isEmpty {
            section("Team pulse", icon: "heart.text.square.fill") {
                ForEach(items) { item in
                    teamPulseCard(item)
                }
            }
        }
    }

    private func teamPulseCard(_ item: TeamPulseItem) -> some View {
        let link = item.userID.map { BriefingLink.person($0) }
        return itemButton(link) {
            HStack(alignment: .top, spacing: Spacing.regular) {
                signalIcon(item.signalType)
                VStack(alignment: .leading, spacing: Spacing.small) {
                    itemText(item.text)
                    if let detail = item.detail, !detail.isEmpty {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                    if let signal = item.signalType, !signal.isEmpty {
                        Chip(text: signal.replacingOccurrences(of: "_", with: " ").capitalized, color: .secondary)
                    }
                }
                Spacer()
                if link != nil { chevron }
            }
        }
    }

    // MARK: - Coaching

    @ViewBuilder
    private var coachingSection: some View {
        let items = briefing.parsedCoaching
        if !items.isEmpty {
            section("Coaching", icon: "lightbulb.fill") {
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: Spacing.regular) {
                        Image(systemName: "lightbulb.fill").font(.caption).foregroundStyle(Tone.amber)
                        VStack(alignment: .leading, spacing: Spacing.small) {
                            itemText(item.text)
                            if let category = item.category, !category.isEmpty {
                                Chip(text: category.capitalized, color: Tone.amber)
                            }
                        }
                        Spacer()
                        makeTaskButton(.coaching(item))
                    }
                    .padding(Spacing.cozy)
                    .card()
                }
            }
        }
    }

    // MARK: - Parts

    private func section<Content: View>(
        _ title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            SectionHeader(title: title, systemImage: icon)
            content()
        }
    }

    /// An item's card; pressing it follows `link` when there is one.
    private func itemButton<Label: View>(_ link: BriefingLink?, @ViewBuilder label: () -> Label) -> some View {
        Button {
            if let link { onOpen(link) }
        } label: {
            label()
                .padding(Spacing.cozy)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .card()
        }
        .buttonStyle(.plain)
    }

    private func itemText(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.primary).multilineTextAlignment(.leading)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
    }

    private func priorityIcon(_ priority: String?) -> some View {
        let icon = switch priority {
        case "high": "exclamationmark.circle.fill"
        case "low": "arrow.down.circle.fill"
        default: "minus.circle.fill"
        }
        return Image(systemName: icon).font(.caption).foregroundStyle(Tone.priority(priority ?? "medium"))
    }

    private func sourceLabel(type: String) -> some View {
        let (icon, label): (String, String) = switch type {
        case "track": ("checklist", "Track")
        case "digest": ("newspaper", "Digest")
        case "people": ("person.2", "Person")
        case "project": ("folder", "Workbench")
        default: ("questionmark.circle", type)
        }
        return Label(label, systemImage: icon).font(.caption2).foregroundStyle(.tertiary)
    }

    private func signalIcon(_ signalType: String?) -> some View {
        let (icon, color): (String, Color) = switch signalType {
        case "volume_spike": ("arrow.up.circle.fill", Tone.warning)
        case "volume_drop": ("arrow.down.circle.fill", Color.accentColor)
        case "new_red_flag": ("flag.fill", Tone.error)
        case "highlight": ("star.fill", Tone.amber)
        case "conflict": ("bolt.fill", Tone.error)
        default: ("circle.fill", .secondary)
        }
        return Image(systemName: icon).font(.caption).foregroundStyle(color)
    }

    private func jiraKeyBadges(in text: String) -> some View {
        JiraKeyLinkBadgesView(text: text, siteURL: jiraSiteURL, isConnected: jiraConnected)
    }
}
