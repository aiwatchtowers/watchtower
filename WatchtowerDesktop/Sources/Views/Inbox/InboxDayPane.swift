import SwiftUI
import WatchtowerCore

/// What the Morning brief's pane reads besides its day (`ActionStripActionsView`
/// fills it from the view model): the stepper and History, today's Waiting
/// on you and Moved overnight, their links and the `?`. The defaults (tests,
/// design shots) draw a stepper that goes nowhere and no links.
struct InboxBriefControls {
    /// `InboxBriefDays.history`, newest first.
    var history: [InboxDayCard] = []
    /// ‹ has a day to go to (`InboxBriefDays.step` is not nil).
    var canStepOlder = false
    /// `ActionStripViewModel.briefHistoryShown`.
    var historyShown: Binding<Bool> = .constant(false)
    var onStep: (InboxBriefDays.Step) -> Void = { _ in }
    /// A History pick (`showBriefDay`).
    var onPick: (String) -> Void = { _ in }
    /// `InboxBriefLayout.waitingOnYou` of the feed's open messages.
    var waitingOnYou: [HomeFeedInboxRow] = []
    /// `InboxBriefLayout.movedOvernight` of the feed's tracks.
    var movedOvernight: [InboxTrackCard] = []
    /// "All in Waiting for me": selects that entry; nil = no link.
    var onAllWaiting: (() -> Void)?
    /// "Track my threads": opens that entry; nil = no link.
    var onTrackMyThreads: (() -> Void)?
    /// The reaction commands' `?`; nil draws none.
    var onReactionCommands: (() -> Void)?
}

/// The Inbox's Morning brief (spec "One brief row", §6.3, R3, R10, the
/// mockup's order): the pane header with the day stepper, **History**,
/// **Discuss in Chat** and the `?`; then the lead with **Start here** (the
/// first three attention items), **Your day** (the plan and the brief's
/// day items), today's **Waiting on you** and **Moved overnight**, and the
/// rest of the brief (More for today, What happened, Team pulse, Coaching).
/// In the folder model nothing pins a day card, so it has no Done (ask #607).
/// Opening the card marks its briefing read (`ActionStripViewModel.select`),
/// not this view.
/// Today with nothing yet (the list's placeholder card) says when the brief
/// comes and offers **Make today's brief and plan**; today's plan without a
/// brief offers **Make today's brief** (G4: the old Briefings and Day Plan
/// screens' Generate buttons). Both run the CLI, so they need the owner
/// (OWNER-02). A half whose feature is off (Settings → Features) is never
/// offered: the placeholder then makes only the other one.
/// The reading pane's `InboxCardColumn` scrolls and pads the card.
struct InboxDayPane: View {
    let card: InboxDayCard
    /// "YYYY-MM-DD": only today's card offers Add and Regenerate (R10).
    let today: String
    @Bindable var plan: DayPlanViewModel
    /// Regenerate runs the `day-plan` CLI, which needs the owner (OWNER-02).
    let owner: Owner
    /// The header's Discuss in Chat; the pane takes no environment, so
    /// tests drive it with a closure.
    let onCommand: (InboxCardCommand) -> Void
    let onOpenSource: (DayPlanItem) -> Void
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
    /// The inline row open when the card shows (a design shot opens one).
    var initialRow: InboxDayPlanRow?
    /// The briefing and day-plan features are on (`InboxFeedSnapshot`).
    var briefingOn = true
    var dayPlanOn = true
    /// The stepper, History, today's people and threads (`InboxBriefControls`).
    var controls = InboxBriefControls()

    @State private var openRow: InboxDayPlanRow?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.page) {
            header
            if showsNothingReady {
                InboxDayNothingReady(
                    owner: owner,
                    briefing: briefing,
                    plan: plan,
                    emptyState: emptyState,
                    briefingOn: briefingOn,
                    dayPlanOn: dayPlanOn,
                    onMake: { Task { await makeBriefAndPlan() } },
                    onOpenConnections: onOpenConnections
                )
            }
            if let briefing = card.briefing {
                leadCard(briefing)
            } else if showsPlan, briefingOn, card.date == today, owner.isKnown, let briefing {
                InboxDayBriefRow(briefing: briefing) { Task { await makeBrief() } }
            }
            yourDay
            if card.date == today {
                waitingOnYou
                movedOvernight
            }
            if let briefing = card.briefing {
                BriefingSectionsView(briefing: briefing,
                                     parts: [.attention(from: InboxBriefLayout.topCount, limit: nil),
                                             .whatHappened, .teamPulse, .coaching],
                                     onOpen: onOpenBriefingLink, onMakeTask: onMakeTask)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: card.date) {
            openRow = initialRow
            await plan.loadFor(date: card.date)
        }
    }

    // MARK: - The mockup's sections

    /// The brief's lead line over **Start here**, its first three attention
    /// items with their own actions.
    @ViewBuilder
    private func leadCard(_ briefing: Briefing) -> some View {
        let lead = InboxBriefLayout.lead(briefing)
        if lead != nil || !InboxBriefLayout.startHere(briefing).isEmpty {
            VStack(alignment: .leading, spacing: Spacing.medium) {
                if let lead {
                    Text(lead)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(Spacing.medium)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card()
                }
                BriefingSectionsView(briefing: briefing,
                                     parts: [.attention(from: 0, limit: InboxBriefLayout.topCount)],
                                     onOpen: onOpenBriefingLink, onMakeTask: onMakeTask)
            }
        }
    }

    /// **Your day**: the plan (with "N conflicts" when it has them) and the
    /// brief's day items. The view model holds one date; until it has read
    /// this card's, the plan waits rather than show another day. Today with
    /// no plan yet still shows it, to make one.
    @ViewBuilder
    private var yourDay: some View {
        let items = card.briefing?.parsedYourDay ?? []
        if showsPlan || !items.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.regular) {
                HStack(spacing: Spacing.regular) {
                    SectionHeader(title: "Your day", systemImage: "calendar")
                    if showsPlan, plan.hasConflicts {
                        Chip(text: Self.conflictsLabel(plan.timeblocks), color: Tone.error)
                    }
                }
                if showsPlan {
                    InboxDayPlanBlock(
                        plan: plan,
                        isToday: card.date == today,
                        owner: owner,
                        openRow: $openRow,
                        onOpenSource: onOpenSource
                    )
                }
                if let briefing = card.briefing, !items.isEmpty {
                    BriefingSectionsView(briefing: briefing, parts: [.yourDay], onOpen: onOpenBriefingLink,
                                         onMakeTask: onMakeTask, showsTitles: false)
                }
            }
        }
    }

    /// "1 conflict", "3 conflicts": the plan's time blocks that overlap
    /// another one, at least one (the plan says it has conflicts; a clash
    /// with a calendar event alone has no block pair to count).
    static func conflictsLabel(_ timeblocks: [DayPlanItem]) -> String {
        let count = max(1, overlappingPairs(timeblocks))
        return count == 1 ? "1 conflict" : "\(count) conflicts"
    }

    private static func overlappingPairs(_ timeblocks: [DayPlanItem]) -> Int {
        let spans = timeblocks.compactMap { item -> (Date, Date)? in
            guard let start = item.startTime, let end = item.endTime, end > start else { return nil }
            return (start, end)
        }
        var pairs = 0
        for (index, span) in spans.enumerated() {
            for other in spans.dropFirst(index + 1) where span.0 < other.1 && other.0 < span.1 {
                pairs += 1
            }
        }
        return pairs
    }

    /// Today's **Waiting on you**: the three newest open messages, a link to
    /// Waiting for me; left out when nothing waits.
    @ViewBuilder
    private var waitingOnYou: some View {
        let rows = controls.waitingOnYou
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.regular) {
                sectionHeader("Waiting on you", icon: "person.2", link: "All in Waiting for me",
                              action: controls.onAllWaiting)
                VStack(alignment: .leading, spacing: Spacing.regular) {
                    ForEach(rows, id: \.item.id) { row in
                        messageRow(row)
                    }
                }
                .padding(Spacing.medium)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
            }
        }
    }

    private func messageRow(_ row: HomeFeedInboxRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text([row.who, row.whereText].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.callout.weight(.medium))
                Text(InboxRowText.preview(row.item.snippet))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: Spacing.regular)
            Text(InboxRowTime.label(row.stamp, now: Date(), calendar: .current))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    /// Today's **Moved overnight**: up to three threads with news, a link to
    /// Track my threads; left out when none moved.
    @ViewBuilder
    private var movedOvernight: some View {
        let tracks = controls.movedOvernight
        if !tracks.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.regular) {
                sectionHeader("Moved overnight", icon: "checklist", link: "Track my threads",
                              action: controls.onTrackMyThreads)
                VStack(alignment: .leading, spacing: Spacing.regular) {
                    ForEach(tracks, id: \.track.id) { card in
                        Text(card.track.text)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(Spacing.medium)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
            }
        }
    }

    private func sectionHeader(_ title: String, icon: String, link: String, action: (() -> Void)?) -> some View {
        HStack(spacing: Spacing.regular) {
            SectionHeader(title: title, systemImage: icon)
            Spacer()
            if let action {
                Button(link, action: action)
                    .buttonStyle(.kitQuiet)
                    .controlSize(.small)
            }
        }
    }

    private var showsPlan: Bool {
        guard plan.loadedDate == card.date, !showsNothingReady else { return false }
        return plan.plan != nil || (card.date == today && owner.isKnown && dayPlanOn)
    }

    /// Today's card while it has neither a brief nor a plan.
    private var showsNothingReady: Bool {
        card.date == today && card.briefing == nil && plan.loadedDate == card.date && plan.plan == nil
    }

    /// **Make today's brief and plan**: `briefing generate`, then, unless the
    /// CLI refused it, `day-plan generate --date <today>`; then the Inbox
    /// re-reads. A refusal stays on the view models, shown inline. A half
    /// whose feature is off is skipped (**Make today's brief** / **plan**).
    func makeBriefAndPlan() async {
        guard let briefing, !briefing.isGenerating, !plan.isGenerating, briefingOn || dayPlanOn else { return }
        if briefingOn { await briefing.generateBriefing() }
        if dayPlanOn, !briefingOn || briefing.generateError == nil {
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

    /// The pane header: the stepper, **History**, **Discuss in Chat** (not
    /// on today's placeholder, which has nothing to discuss yet) and the `?`.
    /// The day card has no source link and no Hand to Agent….
    private var header: some View {
        InboxPaneHeader(tile: InboxTile(kind: .brief), title: "Morning brief",
                        subtitle: Self.subtitle(card)) {
            InboxBriefStepper(date: card.date, canStepOlder: controls.canStepOlder,
                              canStepNewer: card.date < today, onStep: controls.onStep)
            InboxBriefHistoryButton(days: controls.history, shownDate: card.date,
                                    isShown: controls.historyShown, onPick: controls.onPick)
            if !card.isEmpty {
                Button("Discuss in Chat") {
                    let subject = InboxCardSubject(day: card, items: plan.loadedDate == card.date ? plan.items : [])
                    onCommand(.chat(subject, message: InboxCardTexts.discussMessage(subject)))
                }
                .buttonStyle(.kitQuiet)
            }
            if let onReactionCommands = controls.onReactionCommands {
                InboxReactionCommandsButton(action: onReactionCommands)
            }
        }
    }

    /// "Wednesday, 11 November · written 08:02" (the briefing's local write
    /// time); the day alone before a briefing exists.
    static func subtitle(_ card: InboxDayCard) -> String {
        let day = dayFormatter.date(from: card.date).map(longFormatter.string(from:)) ?? card.date
        guard let written = card.briefing.flatMap({ AutomationDates.parse($0.createdAt) }) else { return day }
        return "\(day) · written \(timeFormatter.string(from: written))"
    }

    /// "Wed 22 Oct" for "2026-10-22"; the raw string when it does not parse.
    static func dateLabel(_ date: String) -> String {
        guard let day = dayFormatter.date(from: date) else { return date }
        return labelFormatter.string(from: day)
    }

    private static let longFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, d MMMM"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

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

/// Today's card before its brief and plan exist. Per half: a fresh install
/// (the feature not ready yet) gets the briefing's first-run copy and its
/// readiness line; an established one only says when today's comes (owner,
/// ask #299, from the old Day Plan screen). Then **Make today's brief and
/// plan**, its progress and any CLI refusal. With no owner, the OWNER-02
/// message and no time promised (the daemon makes neither without one).
struct InboxDayNothingReady: View {
    let owner: Owner
    let briefing: BriefingViewModel?
    @Bindable var plan: DayPlanViewModel
    let emptyState: EmptyStateContext
    var briefingOn = true
    var dayPlanOn = true
    let onMake: () -> Void
    let onOpenConnections: () -> Void

    /// The Make button's title: only the halves whose feature is on.
    static func makeTitle(briefingOn: Bool, dayPlanOn: Bool) -> String {
        switch (briefingOn, dayPlanOn) {
        case (true, false): "Make today's brief"
        case (false, true): "Make today's plan"
        default: "Make today's brief and plan"
        }
    }

    static func todaysBriefLine(hour: Int) -> String {
        "Today's brief at or after \(String(format: "%02d:00", hour))"
    }

    static func todaysPlanLine(hour: Int) -> String {
        "Today's plan at or after \(String(format: "%02d:00", hour))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            Text("Nothing is ready for today yet.")
                .font(.headline)
            if briefingOn {
                half(.briefing, copyKey: "briefings",
                     established: Self.todaysBriefLine(hour: emptyState.briefingHour))
            }
            if dayPlanOn {
                half(.dayPlan, copyKey: "dayPlan", established: Self.todaysPlanLine(hour: emptyState.briefingHour))
            }
            if !owner.isKnown {
                NoOwnerEmptyState(openConnections: onOpenConnections)
            } else if let briefing {
                makeControls(briefing)
            }
        }
    }

    /// One half's "when": the established line, or the first-run copy.
    @ViewBuilder
    private func half(_ feature: ReadinessFeature, copyKey: String, established: String) -> some View {
        let readiness = emptyState.readiness(feature)
        if readiness == .ready {
            if owner.isKnown {
                Text(established)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else if let copy = EmptyStateCopyTable.copy(
            for: copyKey, briefingHour: emptyState.briefingHour
        ) {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(copy.title).font(.callout.weight(.medium))
                Text(copy.landsHere)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let line = FeatureEmptyState<EmptyView>.readinessLine(readiness) {
                    Text(line).font(.callout)
                }
            }
        }
    }

    @ViewBuilder
    private func makeControls(_ briefing: BriefingViewModel) -> some View {
        let running = briefing.isGenerating || plan.isGenerating
        HStack(spacing: Spacing.regular) {
            Button(Self.makeTitle(briefingOn: briefingOn, dayPlanOn: dayPlanOn), action: onMake)
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
