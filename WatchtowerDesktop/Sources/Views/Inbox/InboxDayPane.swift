import SwiftUI
import WatchtowerCore

/// The Inbox's Your day card (spec §6.3, R3, R10): the day's plan on top,
/// its briefing below, either half alone when the day has only that one.
/// Header: **Discuss in Chat** and **Done** (Done unpins today's card, R3).
/// Opening the card marks its briefing read (`ActionStripViewModel.select`),
/// not this view.
/// Today with nothing yet (the list's placeholder card) says when the brief
/// comes and offers **Make today's brief and plan**; today's plan without a
/// brief offers **Make today's brief** (G4: the old Briefings and Day Plan
/// screens' Generate buttons). Both run the CLI, so they need the owner
/// (OWNER-02).
struct InboxDayPane: View {
    let card: InboxDayCard
    /// "YYYY-MM-DD": only today's card offers Add and Regenerate (R10).
    let today: String
    @Bindable var plan: DayPlanViewModel
    /// Regenerate runs the `day-plan` CLI, which needs the owner (OWNER-02).
    let owner: Owner
    let onDone: () -> Void
    /// The header's Discuss in Chat (`InboxCommonRow`); the pane takes no
    /// environment, so tests drive it with a closure.
    let onCommand: (InboxCardCommand) -> Void
    let onOpenSource: (DayPlanItem) -> Void
    var navScreens: Set<String> = []
    var workbenches: [Workbench] = []
    var isWriting = false
    var onOpenBriefingLink: (BriefingLink) -> Void = { _ in }
    /// Returns the failure to show, or nil.
    var onMakeTask: (BriefingTaskSource) async -> String? = { _ in nil }
    /// AppState's briefing view model, whose `briefing generate` survives
    /// leaving the Inbox; nil (no CLI) hides the Make buttons.
    var briefing: BriefingViewModel?
    /// When the brief comes (readiness, hour) on today's empty card.
    var emptyState: EmptyStateContext = .neutral
    var onOpenConnections: () -> Void = {}
    /// The Inbox re-reads once a Make run ended.
    var onMade: () async -> Void = {}

    @State private var openRow: InboxDayPlanRow?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.page) {
                header
                if showsNothingReady {
                    InboxDayNothingReady(
                        owner: owner,
                        briefing: briefing,
                        plan: plan,
                        emptyState: emptyState,
                        onMake: { Task { await makeBriefAndPlan() } },
                        onOpenConnections: onOpenConnections
                    )
                }
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
                } else if showsPlan, card.date == today, owner.isKnown, let briefing {
                    InboxDayBriefRow(briefing: briefing) { Task { await makeBrief() } }
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
        guard plan.loadedDate == card.date, !showsNothingReady else { return false }
        return plan.plan != nil || (card.date == today && owner.isKnown)
    }

    /// Today's card while it has neither a brief nor a plan.
    private var showsNothingReady: Bool {
        card.date == today && card.briefing == nil && plan.loadedDate == card.date && plan.plan == nil
    }

    /// **Make today's brief and plan**: `briefing generate`, then, unless the
    /// CLI refused it, `day-plan generate --date <today>`; then the Inbox
    /// re-reads. A refusal stays on the view models, shown inline.
    func makeBriefAndPlan() async {
        guard let briefing, !briefing.isGenerating, !plan.isGenerating else { return }
        await briefing.generateBriefing()
        if briefing.generateError == nil {
            // By date: the owner may have opened another day meanwhile.
            await plan.regenerate(feedback: nil, date: today)
        }
        await onMade()
    }

    /// **Make today's brief** on a plan-only card.
    func makeBrief() async {
        guard let briefing, !briefing.isGenerating else { return }
        await briefing.generateBriefing()
        await onMade()
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
            InboxCommonRow(
                subject: InboxCardSubject(day: card, items: plan.loadedDate == card.date ? plan.items : []),
                link: nil,
                navScreens: navScreens,
                workbenches: workbenches,
                isWriting: isWriting,
                showsHandToAgent: false,
                onCommand: onCommand
            ) {
                Button("Done", action: onDone)
            }
        }
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

/// Today's card before its brief and plan exist: when the brief comes (the
/// Day filter's readiness copy), then **Make today's brief and plan**, its
/// progress and any CLI refusal; with no owner, the OWNER-02 message instead.
struct InboxDayNothingReady: View {
    let owner: Owner
    let briefing: BriefingViewModel?
    @Bindable var plan: DayPlanViewModel
    let emptyState: EmptyStateContext
    let onMake: () -> Void
    let onOpenConnections: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            Text("Nothing is ready for today yet.")
                .font(.headline)
            if let copy = EmptyStateCopyTable.copy(
                for: InboxFilter.day.emptyCopyKey,
                briefingHour: emptyState.briefingHour, dayPlanHour: emptyState.dayPlanHour
            ) {
                Text(copy.landsHere)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let line = FeatureEmptyState<EmptyView>.readinessLine(emptyState.readiness(.briefing)) {
                Text(line).font(.callout)
            }
            if !owner.isKnown {
                NoOwnerEmptyState(openConnections: onOpenConnections)
            } else if let briefing {
                makeControls(briefing)
            }
        }
    }

    @ViewBuilder
    private func makeControls(_ briefing: BriefingViewModel) -> some View {
        let running = briefing.isGenerating || plan.isGenerating
        HStack(spacing: Spacing.regular) {
            Button("Make today's brief and plan", action: onMake)
                .buttonStyle(.kitPrimary)
                .disabled(running)
            if running {
                ProgressView().controlSize(.small)
                Text(briefing.isGenerating ? "Making today's brief…" : "Making today's plan…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        if let error = briefing.generateError ?? plan.generationError {
            Text(error)
                .font(.caption)
                .foregroundStyle(Tone.error)
                .textSelection(.enabled)
        }
    }
}

/// Today's plan without a brief: **Make today's brief**, its progress and any
/// CLI refusal.
struct InboxDayBriefRow: View {
    let briefing: BriefingViewModel
    let onMake: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            SectionHeader(title: "Brief", systemImage: "sun.max")
            Text("No brief for today yet.")
                .font(.callout)
                .foregroundStyle(.tertiary)
            HStack(spacing: Spacing.regular) {
                Button("Make today's brief", action: onMake)
                    .buttonStyle(.kitSecondary)
                    .controlSize(.small)
                    .disabled(briefing.isGenerating)
                if briefing.isGenerating {
                    ProgressView().controlSize(.small)
                }
            }
            if let error = briefing.generateError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Tone.error)
                    .textSelection(.enabled)
            }
        }
    }
}
