import SwiftUI
import WatchtowerCore

/// The Inbox's Your day card (spec §6.3, R3, R10): the day's plan on top,
/// its briefing below, either half alone when the day has only that one.
/// Header: **Discuss in Chat** and **Done** (Done unpins today's card, R3).
/// Opening the card marks its briefing read (`ActionStripViewModel.select`),
/// not this view.
struct InboxDayPane: View {
    let card: InboxDayCard
    /// "YYYY-MM-DD": only today's card offers Add and Regenerate (R10).
    let today: String
    @Bindable var plan: DayPlanViewModel
    /// Regenerate runs the `day-plan` CLI, which needs the owner (OWNER-02).
    let owner: Owner
    let onDone: () -> Void
    let onCommand: (InboxCardCommand) -> Void
    let onOpenSource: (DayPlanItem) -> Void
    /// The header's Discuss in Chat. Stands in for `InboxCommonRow` until
    /// the Inbox card commands take any card's subject (C1 Task 7).
    var onDiscuss: () -> Void = {}
    var onOpenBriefingLink: (BriefingLink) -> Void = { _ in }
    /// Returns the failure to show, or nil.
    var onMakeTask: (BriefingTaskSource) async -> String? = { _ in nil }

    @State private var openRow: InboxDayPlanRow?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.page) {
                header
                // The view model holds one date; until it has read this
                // card's, the plan half waits rather than show another day.
                // Today with no plan yet still shows it, to make one.
                if showsPlan {
                    InboxDayPlanBlock(
                        plan: plan,
                        isToday: card.date == today,
                        owner: owner,
                        openRow: $openRow,
                        onOpenSource: onOpenSource
                    )
                }
                if let briefing = card.briefing {
                    BriefingSectionsView(briefing: briefing, onOpen: onOpenBriefingLink, onMakeTask: onMakeTask)
                }
            }
            .padding(Spacing.page)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: card.date) {
            openRow = nil
            await plan.loadFor(date: card.date)
        }
    }

    private var showsPlan: Bool {
        guard plan.loadedDate == card.date else { return false }
        return plan.plan != nil || (card.date == today && owner.isKnown)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text("Your day").font(.headline)
                Text(Self.dateLabel(card.date)).font(.caption).foregroundStyle(.secondary)
                if let role = card.briefing?.role, !role.isEmpty {
                    Text(role).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Discuss in Chat", action: onDiscuss)
            Button("Done", action: onDone)
        }
        .buttonStyle(.kitQuiet)
        .controlSize(.small)
    }

    /// "Wed 22 Oct" for "2026-10-22"; the raw string when it does not parse.
    static func dateLabel(_ date: String) -> String {
        guard let day = dayFormatter.date(from: date) else { return date }
        return labelFormatter.string(from: day)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static let labelFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
