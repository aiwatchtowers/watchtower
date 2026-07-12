import SwiftUI
import AppKit

// MARK: - SituationReviewPane
//
// The rich single-situation review screen on the right of the Dashboard's
// master-detail split (modeled on CatchUpReviewPane). Shows kind/priority
// badges, the title, a Sources block (Target/Track navigation + newest-signal
// Slack link), the secretary card (why-it-matters callout, summary,
// chronology), the member-signal originals with per-bubble Slack links, and a
// bottom action bar (👍/👎 + teaching comment, Snooze, Target, Track, Dismiss,
// Done). All mutating actions are delegated to the owning DashboardView.
struct SituationReviewPane: View {
    @Environment(AppState.self) private var appState

    let situation: Situation
    let memberSignals: [InboxItem]
    let memberSignalsLoaded: Bool
    var senderName: (InboxItem) -> String = { _ in "" }
    var channelName: (InboxItem) -> String = { _ in "" }
    /// Builds a Slack deep link for a member signal; nil hides the affordance.
    var slackURL: (InboxItem) -> URL? = { _ in nil }
    let onDone: () -> Void
    let onDismiss: () -> Void
    let onKeepOpen: () -> Void
    let onSnooze: (SnoozeOption) -> Void
    let onFeedback: (Int, String) -> Void
    /// Disables the Target button while its async prefill is being built.
    var isCreatingTarget: Bool = false
    let onCreateTarget: () -> Void
    let onCreateTrack: () -> Void
    let onOpenTarget: (Int) -> Void
    let onOpenTrack: (Int) -> Void

    @State private var comment: String = ""

    // Discuss chat state lives on the pane (not the in-scroll section) because
    // its input bar must dock OUTSIDE the ScrollView — ChatInput's nested
    // NSScrollView collapses inside a SwiftUI ScrollView. Reset per situation
    // by the `.id(situation.id)` DashboardView applies at the pane's call
    // site — an .id inside this body would only reset children, not this
    // @State, leaking one situation's conversation into the next.
    @State private var discussExpanded = false
    @State private var discussVM: SituationChatViewModel?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if situation.hasSuggestedResolution {
                        suggestedResolutionBanner
                    }
                    header
                    sourcesSection
                    secretaryCardOrPlaceholder
                    memberSignalsSection
                    if let dbManager = appState.databaseManager {
                        SituationDiscussSection(
                            situation: situation,
                            memberSignals: memberSignals,
                            dbManager: dbManager,
                            isExpanded: $discussExpanded,
                            chatVM: $discussVM
                        )
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if discussExpanded, let discussVM {
                Divider()
                SituationDiscussInputBar(chatVM: discussVM)
            }

            Divider()
            actionBar
        }
    }

    // MARK: - Suggested resolution banner (DASH-07)

    private var suggestedResolutionBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("The secretary believes this is resolved", systemImage: "checkmark.circle")
                .font(.headline)
                .foregroundStyle(.green)
            Text(situation.suggestedResolution)
                .font(.callout)
            HStack(spacing: 8) {
                Button("Done") { onDone() }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                Button("Keep open") { onKeepOpen() }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                kindBadge
                priorityBadge
                Spacer()
                if let date = situation.lastSignalDate {
                    Text(date, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Text(situation.title)
                .font(.largeTitle.bold())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var kindBadge: some View {
        let info = kindBadgeInfo
        return Text(info.label)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(info.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(info.color.opacity(0.12), in: Capsule())
    }

    private var kindBadgeInfo: (label: String, color: Color) {
        switch situation.kind {
        case .external:      return ("Signal", .secondary)
        case .targetUpdate:  return ("Target", .blue)
        case .trackUpdate:   return ("Track", .purple)
        case .mixed:         return ("Mixed", .orange)
        }
    }

    private var priorityBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(priorityColor)
                .frame(width: 8, height: 8)
            Text(situation.priority.capitalized)
                .font(.caption)
                .foregroundStyle(priorityColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(priorityColor.opacity(0.1), in: Capsule())
    }

    private var priorityColor: Color {
        switch situation.priority {
        case "high": return .red
        case "medium": return .orange
        default: return .blue
        }
    }

    // MARK: - Sources (первоисточники: Target/Track navigation + newest Slack link)

    @ViewBuilder
    private var sourcesSection: some View {
        let hasAny = situation.targetID != nil || situation.trackID != nil || newestMemberSignalURL != nil
        if hasAny {
            VStack(alignment: .leading, spacing: 8) {
                Text("Sources")
                    .font(.headline)

                if let targetID = situation.targetID {
                    sourceRow(symbol: "checkmark.circle", color: .blue,
                              title: "Target #\(targetID)", subtitle: "Target") {
                        onOpenTarget(targetID)
                    }
                }
                if let trackID = situation.trackID {
                    sourceRow(symbol: "point.topleft.down.curvedto.point.bottomright.up", color: .purple,
                              title: "Track #\(trackID)", subtitle: "Track") {
                        onOpenTrack(trackID)
                    }
                }
                if let url = newestMemberSignalURL {
                    sourceRow(symbol: "arrow.up.right.square", color: .green,
                              title: "Newest message in Slack", subtitle: "Slack") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    private func sourceRow(
        symbol: String,
        color: Color,
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.caption)
                    .foregroundStyle(color)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    /// Member signals arrive oldest-first (SituationQueries.memberSignals), so
    /// the last element is the newest — same rule the old card header used.
    private var newestMemberSignalURL: URL? {
        guard memberSignalsLoaded, let newest = memberSignals.last else { return nil }
        return slackURL(newest)
    }

    // MARK: - Secretary card

    @ViewBuilder
    private var secretaryCardOrPlaceholder: some View {
        if situation.hasCard {
            cardSection
        } else if situation.cardStatus == .failed {
            Text("Context unavailable — will retry")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Preparing context…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var cardSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !situation.whyMatters.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lightbulb.fill")
                        .foregroundStyle(.yellow)
                        .font(.callout)
                    Text(situation.whyMatters)
                        .font(.callout)
                        .textSelection(.enabled)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            if !situation.summary.isEmpty {
                cardParagraph(title: "Summary", text: situation.summary)
            }
            if !situation.chronology.isEmpty {
                cardParagraph(title: "Chronology", text: situation.chronology)
            }
        }
    }

    private func cardParagraph(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            Text(text)
                .font(.body)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Member signals (same bubble shape the old card used)

    @ViewBuilder
    private var memberSignalsSection: some View {
        Divider()
        if !memberSignalsLoaded {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading signals…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if memberSignals.isEmpty {
            Text("No member signals recorded.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(memberSignals) { item in
                    memberSignalBubble(item)
                }
            }
        }
    }

    private func memberSignalBubble(_ item: InboxItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text("\(senderName(item)) · \(channelName(item))")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Text(item.messageDate, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                if let url = slackURL(item) {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Open in Slack")
                }
            }
            .padding(.top, 6)
            Text(item.snippet)
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Action bar

    private var actionBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    onFeedback(1, comment)
                    comment = ""
                } label: {
                    Image(systemName: "hand.thumbsup")
                }
                .buttonStyle(.bordered)
                .help("Helpful")

                Button {
                    onFeedback(-1, comment)
                    comment = ""
                } label: {
                    Image(systemName: "hand.thumbsdown")
                }
                .buttonStyle(.bordered)
                .help("Not helpful")

                TextField("Comment to teach the secretary…", text: $comment)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 8) {
                Menu {
                    Button("1 hour") { onSnooze(.oneHour) }
                    Button("Till tomorrow") { onSnooze(.tillTomorrow) }
                    Button("Till Monday") { onSnooze(.tillMonday) }
                } label: {
                    Label("Snooze", systemImage: "moon.zzz")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Button(action: onCreateTarget) {
                    Label("Target", systemImage: "checkmark.circle")
                }
                .buttonStyle(.bordered)
                .disabled(isCreatingTarget)

                Button(action: onCreateTrack) {
                    Label("Track", systemImage: "binoculars")
                }
                .buttonStyle(.bordered)

                Button("Dismiss", role: .destructive, action: onDismiss)
                    .buttonStyle(.bordered)

                Spacer()

                Button {
                    onDone()
                } label: {
                    Label("Done", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(12)
    }
}
