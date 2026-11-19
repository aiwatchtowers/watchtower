import SwiftUI
import WatchtowerCore

/// The Inbox's Watchman entry (spec §10, mockups §11a): the nights on the
/// left, the selected night on the right; one column with menus below
/// `splitWidth`. Reads while on screen (`WatchmanJournalViewModel.watch`).
struct WatchmanJournalView: View {
    @Bindable var model: WatchmanJournalViewModel
    /// Rereads `watchman status` (the daemon line) with the journal.
    var readStatus: () async -> Void = {}

    var body: some View {
        WatchmanJournalContent(model: model, scrolls: true)
            .task { await model.watch(readStatus: readStatus) }
            .sheet(item: $model.correcting) { _ in WatchmanCorrectSheet(model: model) }
    }
}

/// The journal's layout without its reads; `scrolls: false` lays every
/// column out at its full height (the design shots).
struct WatchmanJournalContent: View {
    @Bindable var model: WatchmanJournalViewModel
    var scrolls = true

    /// The least width the nights list and the night side by side need.
    static let splitWidth = PaneWidth.sideListIdeal + PaneWidth.narrowPage

    var body: some View {
        ViewThatFits(in: .horizontal) {
            split.frame(minWidth: Self.splitWidth, idealWidth: Self.splitWidth, maxWidth: .infinity)
            narrow
        }
        .controlSize(.small)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .detailBackground()
    }

    // MARK: - Layouts

    private var split: some View {
        HStack(alignment: .top, spacing: 0) {
            column {
                VStack(alignment: .leading, spacing: Spacing.small) {
                    header.padding(.bottom, Spacing.regular)
                    if model.phase == .journal {
                        ForEach(model.nightRows) { nightRow($0) }
                    }
                }
                .padding(Spacing.medium)
            }
            .frame(width: PaneWidth.sideListMax - Spacing.page * 3)
            Rectangle().fill(.separator).frame(width: Stroke.hairline)
            column {
                reading
                    .padding(Spacing.page)
                    .frame(maxWidth: ReadableColumn.maxLineWidth, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }

    private var narrow: some View {
        column {
            VStack(alignment: .leading, spacing: Spacing.medium) {
                header
                if model.phase == .journal, model.nightRows.count > 1 { nightMenu }
                reading
            }
            .padding(Spacing.medium)
        }
    }

    /// A column scrolls only while it holds a night; the states centre in it.
    @ViewBuilder
    private func column(@ViewBuilder _ content: () -> some View) -> some View {
        if scrolls, model.phase == .journal {
            ScrollView { content().frame(maxWidth: .infinity, alignment: .topLeading) }
        } else {
            content().frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - The nights

    private var header: some View {
        HStack(spacing: Spacing.regular) {
            Image(systemName: "moon.stars").foregroundStyle(WatchmanJournalStyle.tone)
            Text(model.title).font(.headline)
            Spacer(minLength: Spacing.regular)
            if model.scopeOptions.count > 1 || model.scope != nil { scopeMenu }
        }
    }

    private var scopeMenu: some View {
        Menu {
            Toggle(WatchmanJournalCopy.scopeAll, isOn: scopeBinding(nil))
            ForEach(model.scopeOptions, id: \.id) { option in
                Toggle(option.name, isOn: scopeBinding(option.id))
            }
        } label: {
            MenuLabel(text: model.scopeTitle, systemImage: "square.stack",
                      color: model.scope == nil ? .secondary : Color.accentColor)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func scopeBinding(_ id: Int64?) -> Binding<Bool> {
        Binding(get: { model.scope == id }, set: { if $0 { model.scope = id } })
    }

    private var nightMenu: some View {
        Menu {
            ForEach(model.nightRows) { row in
                Toggle(row.title, isOn: Binding(get: { row.selected }, set: { if $0 { model.selectedNight = row.id } }))
            }
        } label: {
            MenuLabel(text: model.page?.title ?? "", systemImage: "moon", color: .secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func nightRow(_ row: WatchmanJournalViewModel.NightRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
            Group {
                if row.live {
                    ProgressView().controlSize(.mini)
                } else {
                    Circle().fill(row.selected ? Color.accentColor : .clear)
                        .frame(width: IconSize.stateDot, height: IconSize.stateDot)
                }
            }
            .frame(width: Spacing.medium)
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(row.title).font(.callout.weight(row.selected ? .semibold : .regular))
                Text(row.line).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.regular)
        .padding(.vertical, Spacing.compact)
        .kitRow(isSelected: row.selected)
        .contentShape(Rectangle())
        .onTapGesture { model.selectedNight = row.id }
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - The reading side

    @ViewBuilder
    private var reading: some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            if let line = model.daemonLine {
                WatchmanJournalNotice(icon: "exclamationmark.triangle.fill", tone: Tone.warning, text: line)
            }
            if let error = model.actionError {
                WatchmanJournalNotice(icon: "exclamationmark.triangle.fill", tone: Tone.warning, text: error)
            }
            switch model.phase {
            case .loading:
                VStack(spacing: Spacing.regular) {
                    ProgressView().controlSize(.small)
                    Text(model.loadingText).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed:
                VStack(spacing: Spacing.medium) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(Tone.warning)
                    Text(model.readFailedText)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: PaneWidth.narrowPage)
                    Button(model.retryTitle) { Task { await model.retry() } }.buttonStyle(.kitPrimary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .empty:
                FeatureEmptyState(
                    copy: model.emptyCopy, readiness: nil, syncLine: nil, turnOnError: nil, isTurningOn: false,
                    onAction: { _ in },
                    extra: {
                        Text(model.emptyHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: PaneWidth.narrowPage)
                    }
                )
                .frame(maxHeight: .infinity)
            case .journal:
                if let page = model.page { WatchmanNightPage(model: model, page: page) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: model.phase == .journal ? nil : .infinity, alignment: .topLeading)
    }
}

/// One night: its header, Waiting for you, Decided, Checks nobody ran.
private struct WatchmanNightPage: View {
    let model: WatchmanJournalViewModel
    let page: WatchmanJournalViewModel.Page

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            header
            if let busy = page.busyLine {
                HStack(spacing: Spacing.regular) {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.callout).lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(Spacing.medium)
                .background(WatchmanJournalStyle.tone.opacity(ChipTint.fillOpacity),
                            in: RoundedRectangle(cornerRadius: Radius.row))
            }
            if !page.waiting.isEmpty {
                section(model.waitingTitle, count: page.waiting.count, trailing: nil) {
                    ForEach(page.waiting) { card in
                        WatchmanWaitingCard(card: card, model: model)
                    }
                }
            }
            if page.decidedCount > 0 || !page.ownerFirst.isEmpty {
                section(model.decidedTitle, count: page.decidedCount, trailing: page.decidedSummary) {
                    ForEach(page.decided) { WatchmanDecisionCard(card: $0, model: model) }
                    if !page.sureLines.isEmpty { lines(page.sureLines, icon: "checkmark.circle.fill", tone: Tone.success) }
                    if !page.ownerFirst.isEmpty { lines(page.ownerFirst, icon: "person.fill.checkmark", tone: .secondary) }
                }
            }
            if !page.checks.isEmpty {
                section(model.checksTitle, count: page.checks.count, trailing: nil) {
                    lines(page.checks, icon: "forward.circle", tone: Tone.status("gray"))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                Text(page.title).font(.title3.weight(.semibold))
                Spacer(minLength: Spacing.regular)
                // D24: no budget stops the night; the header shows what it cost.
                Text(page.cost).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(page.span).font(.caption).foregroundStyle(.secondary)
            ForEach(page.gapLines, id: \.self) { line in
                Label(line, systemImage: "moon.zzz").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func section(
        _ title: String, count: Int, trailing: String?, @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(Tracking.caps)
                    .foregroundStyle(.secondary)
                CountBadge(text: "\(count)")
                Spacer(minLength: Spacing.regular)
                if let trailing, !trailing.isEmpty { Text(trailing).font(.caption).foregroundStyle(.secondary) }
            }
            content()
        }
    }

    private func lines(_ lines: [WatchmanJournalViewModel.Line], icon: String, tone: Color) -> some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            ForEach(lines) { line in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                    Image(systemName: line.icon ?? icon).foregroundStyle(tone)
                    VStack(alignment: .leading, spacing: Spacing.tight) {
                        Text(line.title).font(.callout).fixedSize(horizontal: false, vertical: true)
                        if let note = line.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                        Text(line.meta).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: Spacing.regular)
                    if line.canMarkDone {
                        Button(model.markDoneTitle) { Task { await model.markDone(line.id) } }
                            .buttonStyle(.kitSecondary)
                    }
                }
            }
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

/// A parked or handed item: what the owner has to do.
private struct WatchmanWaitingCard: View {
    let card: WatchmanJournalViewModel.Card
    let model: WatchmanJournalViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                Image(systemName: card.handed ? "person.fill.questionmark" : "hand.raised.fill")
                    .foregroundStyle(Tone.warning)
                Text(card.question).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            }
            if let reason = card.reason { Text(reason).font(.callout).fixedSize(horizontal: false, vertical: true) }
            HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                Text(card.place).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: Spacing.regular)
                if card.canOpen {
                    Button(model.openSessionTitle) { model.openSession(card.id) }.buttonStyle(.kitQuiet)
                }
                if card.canMarkDone {
                    Button(model.markDoneTitle) { Task { await model.markDone(card.id) } }.buttonStyle(.kitSecondary)
                }
            }
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

/// One decision Watchman took for the owner and was not sure about.
private struct WatchmanDecisionCard: View {
    let card: WatchmanJournalViewModel.Card
    let model: WatchmanJournalViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            HStack(spacing: Spacing.regular) {
                if let badge = card.badge { Chip(text: badge, color: Tone.warning, dot: true) }
                Text(card.place).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(card.question).font(.headline).fixedSize(horizontal: false, vertical: true)
            if let choice = card.choice {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                    Text(model.choseLabel).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(choice).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let rationale = card.rationale {
                Text(rationale).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if !card.precedents.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.small) {
                    Text(model.leanedOn).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(card.precedents, id: \.self) { precedent in
                        Label(precedent, systemImage: "arrow.turn.down.right").font(.caption)
                    }
                }
            }
            Text(card.meta).font(.caption).foregroundStyle(.secondary)
            if let outcome = card.outcome {
                Label(outcome, systemImage: "arrow.forward.circle").font(.caption).foregroundStyle(.secondary)
            }
            if let feedback = card.feedbackLine {
                Label(feedback, systemImage: "person.fill.checkmark").font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let send = card.sendLine {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                    Label(send, systemImage: card.sendFailed ? "exclamationmark.triangle.fill" : "paperplane")
                        .font(.caption)
                        .foregroundStyle(card.sendFailed ? Tone.warning : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if card.sendFailed {
                        Button(model.retryTitle) { Task { await model.retrySend(card.id) } }.buttonStyle(.kitQuiet)
                    }
                }
            }
            actions
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

extension WatchmanDecisionCard {
    /// OK and Correct… while the decision is not judged; Open session
    /// whenever there is a session to open.
    @ViewBuilder
    fileprivate var actions: some View {
        if card.canJudge || card.canOpen {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.regular) {
                    judgeButtons
                    Spacer(minLength: Spacing.regular)
                    openButton
                }
                VStack(alignment: .leading, spacing: Spacing.small) {
                    HStack(spacing: Spacing.regular) { judgeButtons }
                    openButton
                }
            }
            .padding(.top, Spacing.tight)
        }
    }

    @ViewBuilder
    private var judgeButtons: some View {
        if card.canJudge {
            Button(model.okTitle) { Task { await model.ok(card.id) } }.buttonStyle(.kitSecondary)
            Button(model.correctTitle) { model.beginCorrect(card.id) }.buttonStyle(.kitSecondary)
        }
    }

    @ViewBuilder
    private var openButton: some View {
        if card.canOpen { Button(model.openSessionTitle) { model.openSession(card.id) }.buttonStyle(.kitQuiet) }
    }
}

/// A line above the journal that says why it may be stale.
private struct WatchmanJournalNotice: View {
    let icon: String
    let tone: Color
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
            Image(systemName: icon).foregroundStyle(tone)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(Spacing.medium)
        .background(tone.opacity(ChipTint.fillOpacity), in: RoundedRectangle(cornerRadius: Radius.row))
    }
}

/// Watchman's own marks: the journal's moon, the busy line's fill.
enum WatchmanJournalStyle {
    static let tone = Tone.status("purple")
}
