import SwiftUI

// MARK: - DashboardView

/// The secretary Dashboard feed — a single rank-ordered list of `Situation`s
/// (clustered signals + target/track updates), replacing the old two-tier Inbox
/// feed. Row expansion, member-signal loading, and all mutating actions are
/// delegated to the `DashboardViewModel` passed in by the owning tab container
/// (`InboxFeedView`), mirroring how `InboxViewModel` is owned/passed there.
struct DashboardView: View {
    let vm: DashboardViewModel
    @State private var expandedSituationID: Situation.ID?
    @State private var memberSignalsCache: [Int: [InboxItem]] = [:]

    var body: some View {
        Group {
            if vm.situations.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(vm.situations) { situation in
                            situationRow(situation)
                        }

                        Button("Load more") { vm.loadMore() }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Nothing needs your attention")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Composed situations from Slack signals, targets, and tracks will appear here")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func situationRow(_ situation: Situation) -> some View {
        let isExpanded = expandedSituationID == situation.id

        return SituationCardView(
            situation: situation,
            isExpanded: isExpanded,
            memberSignals: memberSignalsCache[situation.id] ?? [],
            memberSignalsLoaded: memberSignalsCache[situation.id] != nil,
            senderName: { vm.senderName(for: $0) },
            channelName: { vm.channelName(for: $0) },
            onToggle: { toggleExpansion(situation) },
            onDone: { vm.done(situation) },
            onDismiss: { vm.dismiss(situation) },
            onSnooze: { option in vm.snooze(situation, until: SnoozeDates.until(option)) },
            onFeedback: { rating in vm.submitFeedback(situation, rating: rating) }
        )
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            isExpanded ? Color.accentColor.opacity(0.12) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .padding(.horizontal, 4)
    }

    private func toggleExpansion(_ situation: Situation) {
        if expandedSituationID == situation.id {
            expandedSituationID = nil
            return
        }
        // Lazy-load member signals on first expand; cache so collapsing and
        // re-expanding doesn't re-hit the DB (same idiom as InboxFeedView's
        // conversationCache for the legacy feed).
        if memberSignalsCache[situation.id] == nil {
            memberSignalsCache[situation.id] = vm.loadMemberSignals(situation.id)
        }
        expandedSituationID = situation.id
    }
}
