import SwiftUI
import WatchtowerCore

/// The inline row open under the day card's plan: one at a time, no sheet.
enum InboxDayPlanRow: Equatable {
    case add
    case regenerate
    case reset
}

/// The Your day card's plan (R10): the conflict warning, the items with
/// `DayPlanItemRow` (time blocks in time order, then the backlog), and on
/// today's card only the `+` (Add to the plan) and **Regenerate with
/// feedback…** and **Reset plan…**, each an inline row; with no plan yet,
/// **Make today's plan** (the Day Plan screen's footer, kept by G4).
/// Generate, regenerate and reset run the `day-plan` CLI, so they need the
/// owner (OWNER-02, the `DayPlanFooterBar` rule); adding an item is a local
/// write and does not.
struct InboxDayPlanBlock: View {
    @Bindable var plan: DayPlanViewModel
    let isToday: Bool
    let owner: Owner
    @Binding var openRow: InboxDayPlanRow?
    let onOpenSource: (DayPlanItem) -> Void

    var body: some View {
        if plan.plan == nil {
            noPlan
        } else {
            planBody
        }
    }

    /// Today's card before a plan exists: one button that makes it. A
    /// refusal (the CLI's stderr) shows inline.
    private var noPlan: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            HStack(spacing: Spacing.regular) {
                SectionHeader(title: "Plan", systemImage: "checklist")
                if plan.isGenerating {
                    ProgressView().controlSize(.small)
                }
            }
            Text("No plan for this day yet.")
                .font(.callout)
                .foregroundStyle(.tertiary)
            if let error = plan.generationError {
                errorText(error)
            }
            if isToday && owner.isKnown {
                Button("Make today's plan") { Task { await submitGenerate() } }
                    .buttonStyle(.kitSecondary)
                    .controlSize(.small)
                    .disabled(plan.isGenerating)
            }
        }
    }

    private var planBody: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            header
            if plan.hasConflicts {
                // A past day's plan is not regenerated or re-checked: the
                // warning stays, its actions go (an unknown owner hides them).
                DayPlanConflictBanner(
                    owner: isToday ? owner : .unknown,
                    summary: plan.plan?.conflictSummary,
                    onRegenerate: { openRow = .regenerate },
                    onCheckAgain: { Task { await plan.checkConflicts() } }
                )
            }
            items
            if openRow == nil, let error = plan.generationError {
                WriteErrorBanner(message: error) { plan.generationError = nil }
            }
            if isToday {
                todayActions
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Spacing.regular) {
            SectionHeader(title: "Plan", systemImage: "checklist")
            let progress = plan.progress
            if progress.total > 0 {
                Text("\(progress.done)/\(progress.total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if plan.isGenerating {
                ProgressView().controlSize(.small)
            }
            Spacer()
            if isToday {
                Button { openRow = .add } label: { Image(systemName: "plus") }
                    .buttonStyle(.kitIcon(isOn: false))
                    .help("Add to the plan")
                    .accessibilityLabel("Add to the plan")
            }
        }
    }

    // MARK: - Items

    @ViewBuilder
    private var items: some View {
        let rows = plan.allDayItems + plan.timeblocks + plan.backlogItems
        if rows.isEmpty {
            Text("Nothing in this plan yet.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { item in
                    HStack(spacing: 0) {
                        if let time = timeLabel(item) {
                            Text(time)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        DayPlanItemRow(
                            item: item,
                            onToggle: {
                                Task {
                                    if item.isDone {
                                        await plan.markPending(item)
                                    } else {
                                        await plan.markDone(item)
                                    }
                                }
                            },
                            onDelete: { Task { await plan.delete(item) } },
                            onNavigateSource: { onOpenSource(item) }
                        )
                    }
                }
            }
        }
    }

    /// "09:00–09:30" for a time block, "All day" for an all-day event, nil
    /// for the backlog.
    private func timeLabel(_ item: DayPlanItem) -> String? {
        guard item.kind == .timeblock else { return nil }
        if plan.allDayItems.contains(where: { $0.id == item.id }) { return "All day" }
        guard let start = item.startTime else { return nil }
        let from = start.formatted(date: .omitted, time: .shortened)
        guard let end = item.endTime else { return from }
        return "\(from)–\(end.formatted(date: .omitted, time: .shortened))"
    }

    // MARK: - Today's actions

    @ViewBuilder
    private var todayActions: some View {
        switch openRow {
        case .add:
            InboxDayPlanAddRow(plan: plan, planDate: plan.plan?.planDate ?? "") { openRow = nil }
        case .regenerate:
            regenerateRow
        case .reset:
            resetRow
        case nil:
            if owner.isKnown {
                HStack(spacing: Spacing.regular) {
                    Button("Regenerate with feedback…") { openRow = .regenerate }
                    Button("Reset plan…") { openRow = .reset }
                }
                .buttonStyle(.kitQuiet)
                .controlSize(.small)
                .disabled(plan.isGenerating)
            }
        }
    }

    private func errorText(_ error: String) -> some View {
        Text(error)
            .font(.caption)
            .foregroundStyle(Tone.error)
            .textSelection(.enabled)
    }

    /// The Day Plan screen's Reset plan, as an inline confirm row.
    private var resetRow: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            Text("Reset — today's plan is deleted, with the items you added. Your targets are not touched.")
                .font(.callout)
            if let error = plan.generationError {
                errorText(error)
            }
            HStack(spacing: Spacing.regular) {
                Button("Reset") { Task { await submitReset() } }
                    .buttonStyle(.kitDestructive)
                    .disabled(!owner.isKnown || plan.isGenerating)
                Button("Cancel") {
                    plan.generationError = nil
                    openRow = nil
                }
                .buttonStyle(.kitQuiet)
            }
        }
        .padding(Spacing.cozy)
        .card()
    }

    private var regenerateRow: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            TextField("What should change?", text: $plan.feedbackDraft)
                .textFieldStyle(.kit)
                .onSubmit { Task { await submitRegenerate() } }
            if let error = plan.generationError {
                errorText(error)
            }
            HStack(spacing: Spacing.regular) {
                Button("Regenerate") { Task { await submitRegenerate() } }
                    .buttonStyle(.kitPrimary)
                    .disabled(!canRegenerate)
                Button("Cancel") {
                    plan.generationError = nil
                    openRow = nil
                }
                .buttonStyle(.kitQuiet)
                if plan.isGenerating {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .padding(Spacing.cozy)
        .card()
    }

    private var canRegenerate: Bool {
        owner.isKnown && !plan.isGenerating
            && !plan.feedbackDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Regenerates with the draft. On success the row closes and the draft
    /// clears; a refusal (the CLI's stderr, e.g. a morning brief running
    /// now) keeps the row open with the draft and shows the text in it.
    func submitRegenerate() async {
        guard canRegenerate else { return }
        await plan.regenerate(feedback: plan.feedbackDraft)
        guard plan.generationError == nil else { return }
        plan.feedbackDraft = ""
        openRow = nil
    }

    /// Makes today's plan (`day-plan generate`, no feedback).
    func submitGenerate() async {
        guard isToday, owner.isKnown, !plan.isGenerating else { return }
        await plan.regenerate(feedback: nil)
    }

    /// Resets today's plan (`day-plan reset`). On success the row closes and
    /// the card offers Make today's plan; a refusal keeps the row and says why.
    func submitReset() async {
        guard isToday, owner.isKnown, !plan.isGenerating else { return }
        await plan.reset()
        guard plan.generationError == nil else { return }
        openRow = nil
    }
}

/// The plan's inline Add row: title, kind, the start and end of a time
/// block. Its drafts are its own; the times are taken on the plan's date
/// (the pickers only choose the hour and minute), an end before the start is
/// refused, and a failed add keeps the row and says why.
struct InboxDayPlanAddRow: View {
    @Bindable var plan: DayPlanViewModel
    /// "YYYY-MM-DD", the day the times fall on.
    let planDate: String
    let onClose: () -> Void

    @State private var title = ""
    @State private var kind: DayPlanItemKind = .timeblock
    @State private var start = Self.defaultStart()
    @State private var end = Self.defaultStart().addingTimeInterval(60 * 60)
    @State private var isAdding = false
    @State private var rowError: String?

    nonisolated static let endBeforeStart = "The end is before the start."

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            TextField("What needs to be done?", text: $title)
                .textFieldStyle(.kit)
                .onSubmit { Task { await add() } }
            HStack(spacing: Spacing.medium) {
                Picker("Kind", selection: $kind) {
                    Text("Time block").tag(DayPlanItemKind.timeblock)
                    Text("Backlog").tag(DayPlanItemKind.backlog)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                if kind == .timeblock {
                    DatePicker("Start", selection: $start, displayedComponents: [.hourAndMinute])
                        .labelsHidden()
                    Text("–").foregroundStyle(.secondary)
                    DatePicker("End", selection: $end, displayedComponents: [.hourAndMinute])
                        .labelsHidden()
                }
            }
            .controlSize(.small)
            if let error = rowError ?? plan.generationError {
                Text(error).font(.caption).foregroundStyle(Tone.error)
            }
            HStack(spacing: Spacing.regular) {
                Button("Add") { Task { await add() } }
                    .buttonStyle(.kitPrimary)
                    .disabled(isAdding || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel") {
                    plan.generationError = nil
                    onClose()
                }
                .buttonStyle(.kitQuiet)
            }
        }
        .padding(Spacing.cozy)
        .card()
    }

    private func add() async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isAdding, !trimmed.isEmpty else { return }
        var times: (Date, Date)?
        if kind == .timeblock {
            guard let range = Self.timeRange(on: planDate, start: start, end: end) else {
                rowError = Self.endBeforeStart
                return
            }
            times = range
        }
        rowError = nil
        isAdding = true
        defer { isAdding = false }
        plan.generationError = nil
        await plan.addManual(kind: kind, title: trimmed, startTime: times?.0, endTime: times?.1)
        guard plan.generationError == nil else { return }
        onClose()
    }

    /// `start`'s and `end`'s hour and minute on `day` ("YYYY-MM-DD", the
    /// current calendar's zone); nil when the end is not after the start.
    /// A day that does not parse keeps the pickers' own dates.
    nonisolated static func timeRange(
        on day: String,
        start: Date,
        end: Date,
        calendar: Calendar = .current
    ) -> (Date, Date)? {
        func onDay(_ time: Date) -> Date {
            let parts = day.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return time }
            var components = calendar.dateComponents([.hour, .minute], from: time)
            components.year = parts[0]
            components.month = parts[1]
            components.day = parts[2]
            return calendar.date(from: components) ?? time
        }
        let from = onDay(start)
        let to = onDay(end)
        return to > from ? (from, to) : nil
    }

    /// The top of the next hour, at the latest 22:00, so the default
    /// one-hour block ends on the same day.
    private static func defaultStart() -> Date {
        let calendar = Calendar.current
        let now = Date()
        let hour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        let latest = calendar.date(bySettingHour: 22, minute: 0, second: 0, of: now) ?? now
        return min(hour.addingTimeInterval(60 * 60), latest)
    }
}
