import SwiftUI
import WatchtowerKit

/// Opens one ask's form, from a Waiting-for-you card, a session's or a
/// target's asks, or a closed ask.
struct AskRoute: Hashable {
    let id: Int64
}

/// One ask on the phone (spec §13 B4): the header, the summary and what to
/// look at, then the kind's form (question pages, the review snapshot with
/// its comments and verdict, the check steps), the note and Send. A closed
/// ask shows its stored answer read-only; one whose payload did not fit
/// says to open it on the Mac.
struct AskView: View {
    @Environment(AppEnvironment.self) private var env
    let replica: WorkbenchReplicaModel
    @State private var model: AskViewModel

    init(replica: WorkbenchReplicaModel, drafts: AskDraftStore, answerer: AskAnswerer, askID: Int64) {
        self.replica = replica
        _model = State(initialValue: AskViewModel(askID: askID, drafts: drafts, answerer: answerer))
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if let form = model.form(snapshot: replica.snapshot, now: context.date),
               let ask = replica.snapshot.asks.first(where: { $0.id == model.askID }) {
                content(form, ask: ask)
                    .onChange(of: form.status) { model.followSuccessor(snapshot: replica.snapshot, now: context.date) }
                    .onAppear { model.followSuccessor(snapshot: replica.snapshot, now: context.date) }
            } else {
                ContentUnavailableView("Ask not found", systemImage: "questionmark.bubble", description: Text("It is no longer on your Mac."))
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let alertScreen { env.navigation.screenAppeared(alertScreen) }
            model.observeChat(sessionID: chatSessionID, store: env.store)
        }
        .onDisappear {
            if let alertScreen { env.navigation.screenDisappeared(alertScreen) }
            model.stopObservingChat()
        }
        .onChange(of: chatSessionID) { model.observeChat(sessionID: chatSessionID, store: env.store) }
    }

    /// The session whose chat may carry the agent's message before the ask.
    private var chatSessionID: Int64? {
        replica.snapshot.asks.first { $0.id == model.askID }?.sessionID
    }

    /// This form as a work alert names it: its own alerts stay quiet while it is on top.
    private var alertScreen: AlertDestination? {
        env.activeHubID.map { .ask(hubID: $0, askID: model.askID) }
    }

    private func content(_ form: AskFormModel, ask: OwnerAsk) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.large) {
                AskHeaderView(form: form)
                if let context = form.agentContext {
                    AskAgentContextView(context: context)
                }
                if let notice = model.carriedNotice {
                    Text(notice).font(TypeScale.meta).foregroundStyle(.secondary)
                }
                body(of: form, ask: ask)
                if let status = AskStatusRow.Model(form.status) {
                    AskStatusRow(model: status) { dismiss(status) }
                }
                if let error = model.sendError {
                    Text(error).font(TypeScale.meta).foregroundStyle(PhoneTone.red.color)
                }
            }
            .padding(.horizontal, Spacing.large)
            .padding(.vertical, Spacing.regular)
        }
        .background(Color(.systemBackground))
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if form.openOnMac == nil, form.closedStatus == nil {
                AskSendBar(form: form, ask: ask, model: model)
            }
        }
    }

    @ViewBuilder
    private func body(of form: AskFormModel, ask: OwnerAsk) -> some View {
        if let openOnMac = form.openOnMac {
            VStack(alignment: .leading, spacing: Spacing.regular) {
                Label(openOnMac, systemImage: "desktopcomputer").font(TypeScale.rowEmphasis)
                Text(AskText.openOnMacReason).font(TypeScale.rowTitle).foregroundStyle(.secondary)
            }
            .card(.plain)
        } else if let status = form.closedStatus {
            closedAnswer(form, status: status)
        } else {
            if let page = form.question {
                QuestionAskView(page: page, model: model, isEditable: form.isEditable)
            }
            if let review = form.review {
                ReviewAskView(review: review, specReview: ask.specReview, model: model, isEditable: form.isEditable)
            }
            if !form.checks.isEmpty {
                CheckAskView(rows: form.checks, model: model, isEditable: form.isEditable)
            }
            if form.question?.isLast ?? true {
                SheetField(label: "Note") {
                    TextField("Anything else for the agent (optional)", text: noteBinding, axis: .vertical)
                        .lineLimit(2...8)
                        .disabled(!form.isEditable)
                }
                if let hint = form.noteHint {
                    Text(hint).font(TypeScale.meta).foregroundStyle(PhoneTone.red.color)
                }
            }
        }
    }

    private func closedAnswer(_ form: AskFormModel, status: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(status)
            VStack(alignment: .leading, spacing: 0) {
                if form.closedLines.isEmpty {
                    Text("No answer was stored")
                        .font(TypeScale.rowTitle)
                        .foregroundStyle(.secondary)
                        .padding(Card.padding)
                }
                ForEach(Array(form.closedLines.enumerated()), id: \.offset) { index, line in
                    if index > 0 { CardRowDivider() }
                    VStack(alignment: .leading, spacing: Spacing.tight) {
                        Text(line.label).font(TypeScale.meta).foregroundStyle(.secondary)
                        Text(line.value).font(TypeScale.rowTitle)
                    }
                    .padding(Card.padding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }
            .card(.plain, padding: EdgeInsets())
        }
    }

    private var noteBinding: Binding<String> {
        Binding(get: { model.draft.note }, set: { model.setNote($0) })
    }

    private func dismiss(_ status: AskStatusRow.Model) {
        guard let rowID = status.rowID else { return }
        model.dismiss(rowID: rowID, snapshot: replica.snapshot)
    }
}

/// The kind's icon and word, "#109" and "1 of 2"; the title, where it came
/// from, the summary, what changed since the last round and what to look
/// at (design pass A1).
private struct AskHeaderView: View {
    let form: AskFormModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            // Where it came from sits with its links (#1786); the links stay
            // their own buttons outside the combined accessibility element.
            VStack(alignment: .leading, spacing: Spacing.compact) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
                    Label(form.kindName, systemImage: form.kindIcon)
                        .font(TypeScale.kind)
                        .foregroundStyle(form.headerTone.color)
                    Text(form.idText).font(TypeScale.time).foregroundStyle(.secondary)
                    Spacer(minLength: Spacing.regular)
                    if let page = form.pageText {
                        Text(page).font(TypeScale.meta).foregroundStyle(.secondary)
                    }
                }
                Text(form.title).font(TypeScale.screenTitle)
                Text(form.subline).font(TypeScale.meta).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            if !form.sourceLinks.isEmpty {
                AskSourceLinksView(links: form.sourceLinks)
            }
            if !form.summary.isEmpty || !form.changes.isEmpty || !form.focus.isEmpty {
                details
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            if !form.summary.isEmpty {
                Text(form.summary).font(TypeScale.rowTitle)
            }
            if !form.changes.isEmpty {
                Text("Changed since the last round: \(form.changes)").font(TypeScale.rowTitle).foregroundStyle(.secondary)
            }
            ForEach(Array(form.focus.enumerated()), id: \.offset) { _, focus in
                Label(focus, systemImage: "scope").font(TypeScale.meta).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Open session and Task #415 under the header (#1786): each pushes its
/// screen onto the current stack, whose back button returns to the ask with
/// its draft. Only links whose screen is on the phone are passed in.
private struct AskSourceLinksView: View {
    let links: [AskFormModel.SourceLink]

    var body: some View {
        FlowRow(spacing: Spacing.regular) {
            ForEach(links) { link in
                switch link.destination {
                case let .session(id): NavigationLink(value: SessionRoute(id: id)) { label(link) }.buttonStyle(.plain)
                case let .target(id): NavigationLink(value: BoardTargetRoute(id: id)) { label(link) }.buttonStyle(.plain)
                }
            }
        }
    }

    private func label(_ link: AskFormModel.SourceLink) -> some View {
        let paint = Pill.paint(.tinted, tone: .accent)
        return HStack(spacing: Spacing.small) {
            Image(systemName: link.icon)
            Text(link.title).lineLimit(1)
            Image(systemName: "chevron.right").font(TypeScale.badge)
        }
        .font(TypeScale.kind)
        .foregroundStyle(paint.text)
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.compact)
        .background(paint.fill, in: Capsule())
        .overlay(Capsule().strokeBorder(paint.stroke, lineWidth: ChipTint.strokeWidth))
        .frame(minHeight: PhoneMetrics.minTouch)
        .contentShape(Rectangle())
    }
}

/// The agent's last message before the ask (#1786), when the phone already
/// has the session's chat; long text folds to five lines behind Show more.
private struct AskAgentContextView: View {
    let context: AskFormModel.AgentContext
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Label(context.label, systemImage: "text.bubble")
                .font(TypeScale.meta)
                .foregroundStyle(.secondary)
            Text(context.text)
                .font(TypeScale.rowTitle)
                .lineLimit(context.isLong && !isExpanded ? AskText.agentContextFoldLines : nil)
                .textSelection(.enabled)
            if context.isLong {
                Button(isExpanded ? AskText.showLess : AskText.showMore) { isExpanded.toggle() }
                    .font(TypeScale.meta)
                    .frame(minHeight: PhoneMetrics.minTouch)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(.plain)
    }
}

/// The answer on its way, refused (with Dismiss), or applied.
struct AskStatusRow: View {
    struct Model: Equatable {
        let text: String
        let isFailure: Bool
        /// The overlay row Dismiss removes; nil when there is none to dismiss.
        let rowID: String?

        init?(_ status: AskFormModel.Status) {
            switch status {
            case .none: return nil
            case let .sending(text): (self.text, isFailure, rowID) = (text, false, nil)
            case let .failed(text, row): (self.text, isFailure, rowID) = (text, true, row)
            case let .notOpen(text, row, _): (self.text, isFailure, rowID) = (text, true, row)
            case let .applied(text): (self.text, isFailure, rowID) = (text, false, nil)
            }
        }
    }

    let model: Model
    let dismiss: () -> Void

    var body: some View {
        HStack {
            Text(model.text)
                .font(TypeScale.meta)
                .foregroundStyle(model.isFailure ? PhoneTone.red.color : Color.secondary)
            Spacer(minLength: Spacing.regular)
            if model.rowID != nil {
                Button("Dismiss", action: dismiss)
                    .frame(minHeight: PhoneMetrics.minTouch)
            }
        }
    }
}

/// Send (or Next question on a question page that is not the last), or
/// Request changes and Approve on a review (mockup 10); the footer.
private struct AskSendBar: View {
    let form: AskFormModel
    let ask: OwnerAsk
    let model: AskViewModel

    var body: some View {
        VStack(spacing: 0) {
            actions
            if let page = form.question, page.index > 0, form.review == nil {
                Button(AskText.previous) { model.previous() }
                    .frame(minHeight: PhoneMetrics.minTouch)
            }
            Text(form.footer)
                .font(TypeScale.meta)
                .foregroundStyle(.secondary)
                .padding(.bottom, Spacing.regular)
        }
        .background(Color(.systemBackground), ignoresSafeAreaEdges: .bottom)
    }

    @ViewBuilder private var actions: some View {
        if form.review != nil {
            PrimaryActionBar(
                primary: BarAction(title: AskText.approve, isEnabled: form.canSendVerdict) { verdict(.approved) },
                secondary: BarAction(title: AskText.requestChanges, isEnabled: form.canSendVerdict) { verdict(.changes) }
            )
        } else if let page = form.question, !page.isLast {
            PrimaryActionBar(primary: BarAction(title: AskText.next) { model.next(of: page.count) })
        } else {
            PrimaryActionBar(primary: BarAction(title: AskText.send, isEnabled: form.canSend) {
                Task { await model.send(ask) }
            })
        }
    }

    private func verdict(_ verdict: OwnerAskAnswer.Verdict) {
        Task { await model.review(verdict, ask) }
    }
}
