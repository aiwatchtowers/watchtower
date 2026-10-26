import SwiftUI

/// A screen pushed on Now's stack: Settings, from the gear (design pass
/// spec §5).
enum NowRoute: Hashable, CaseIterable {
    case settings
}

/// The Now tab (spec §5.5, mockup 1): the Mac status chip, Waiting for you
/// across every workbench (each row a card, a quick question with its
/// one-tap answers), Working with timers, then the next meeting with
/// Record. A `ScrollView`, so each row is its own link.
struct NowView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var answerError: String?

    private var replica: WorkbenchReplicaModel { env.workbenchReplica }

    var body: some View {
        NavigationStack {
            // The working timers tick, and the Mac turns asleep by the clock
            // alone.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                content(NowModel(snapshot: replica.snapshot, linked: env.linkedDevice != nil, now: context.date), date: context.date)
            }
            .navigationTitle("Now")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: NowRoute.settings) {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .hubSwitcher()
            .navigationDestination(for: NowRoute.self) { _ in SettingsView() }
            .navigationDestination(for: String.self) { EventDetailView(eventID: $0) }
            // An event detail pushed here opens its recap here (Open recap).
            .navigationDestination(for: CalendarRoute.self) { route in
                switch route {
                case let .event(id): EventDetailView(eventID: id)
                case .recordings: RecordingsListView()
                case let .recap(id): RecapView(transcriptID: id)
                }
            }
            .navigationDestination(for: AskRoute.self) { route in
                AskView(replica: replica, drafts: env.askDrafts, answerer: env.askAnswerer, askID: route.id)
            }
            // A permission request's row opens its session (#517).
            .navigationDestination(for: SessionRoute.self) { route in
                WorkchatView(replica: replica, sessionID: route.id, store: env.store, requester: env.chatRequests)
            }
            .navigationDestination(for: SessionChatRoute.self) { route in
                SessionChatView(replica: replica, route: route, store: env.store, requester: env.chatRequests)
            }
            .navigationDestination(for: BoardTargetRoute.self) { route in
                BoardTargetDetailView(replica: replica, writer: env.boardWriter, targetID: route.id)
            }
            .refreshable { await env.refresh(.pull) }
        }
    }

    private func content(_ model: NowModel, date: Date) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                MacStatusChip(model: model.chip)
                SectionHeader("Waiting for you", count: model.waitingCount, tone: model.waitingHeaderTone)
                waiting(model)
                if !model.working.isEmpty {
                    SectionHeader("Working", count: model.working.count)
                    working(model)
                }
                if let next = NextMeetingCardModel(events: env.calendarReplica.snapshot.events, now: date, calendar: .current) {
                    SectionHeader("Next meeting")
                    NextMeetingRow(card: next)
                }
            }
            .padding(.horizontal, Spacing.large)
            .padding(.bottom, Spacing.large)
        }
        .background(Color(.systemBackground))
        .alert("Couldn't send", isPresented: Binding(get: { answerError != nil }, set: { if !$0 { answerError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(answerError ?? "")
        }
    }

    /// One card per row, then "N more on your Mac".
    @ViewBuilder
    private func waiting(_ model: NowModel) -> some View {
        if let empty = model.emptyText {
            Text(empty)
                .font(TypeScale.rowTitle)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Spacing.small)
        } else {
            VStack(spacing: Spacing.regular) {
                ForEach(model.waitingForYou) { row in
                    NowWaitingCard(row: row, isAnswering: isAnswering(row)) { pick(row, $0) }
                }
            }
            if model.waitingMore > 0 {
                Text("\(model.waitingMore) more on your Mac")
                    .font(TypeScale.meta)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Spacing.small)
                    .padding(.top, Spacing.compact)
            }
        }
    }

    /// One card of flat rows split by hairlines.
    private func working(_ model: NowModel) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(model.working.enumerated()), id: \.element.id) { index, row in
                if index > 0 {
                    CardRowDivider()
                }
                NavigationLink(value: SessionRoute(id: row.id)) {
                    FlatRow(icon: .session(tone: .green, isRing: false), title: row.title, titleLineLimit: 1, insets: EdgeInsets()) {
                        Text(row.meta)
                    } trailing: {
                        if let time = row.time {
                            Text(time).font(TypeScale.time).foregroundStyle(.tertiary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                .buttonStyle(.plain)
            }
        }
        .card(padding: EdgeInsets(top: Spacing.small, leading: Spacing.medium, bottom: Spacing.small, trailing: Spacing.medium))
    }

    // MARK: - Quick answers

    private func isAnswering(_ row: NowWaitingRow) -> Bool {
        guard case let .ask(askID) = row.id else { return false }
        return env.askAnswerer.isSending(askID) || replica.snapshot.pending.contains {
            $0.action.kind == .askAnswer && $0.entityRecordName == AskAnswerer.recordName(askID) && $0.state == .pending
        }
    }

    /// A one-tap answer: the pick goes into the ask's draft and is sent as
    /// the full form would send it (the workchat's path).
    private func pick(_ row: NowWaitingRow, _ option: InlineAskOption) {
        guard case let .ask(askID) = row.id,
              let ask = replica.snapshot.asks.first(where: { $0.id == askID }), let quick = ask.quick else { return }
        env.askDrafts.update(askID) { $0.picks[quick.questionID] = AskQuestionPick(labels: [option.label]) }
        Task {
            do {
                _ = try await env.askAnswerer.send(ask)
            } catch {
                answerError = BoardWriteText.sendError(error)
            }
        }
    }
}

/// One Waiting-for-you card (mockup 1): the state mark, the title, a mono
/// command line for a permission prompt, the meta line and the age; a
/// quick question adds its answers and Open under the text.
private struct NowWaitingCard: View {
    let row: NowWaitingRow
    let isAnswering: Bool
    let onPick: (InlineAskOption) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            link {
                FlatRow(icon: .state(glyph: row.glyph, tone: row.tone), title: row.title, insets: EdgeInsets()) {
                    VStack(alignment: .leading, spacing: Spacing.tight) {
                        if let code = row.code {
                            Text(code).font(TypeScale.code)
                        }
                        Text(row.meta)
                    }
                } trailing: {
                    Text(row.age).font(TypeScale.time).foregroundStyle(.tertiary)
                }
                .accessibilityElement(children: .combine)
            }
            .buttonStyle(.plain)
            if !row.options.isEmpty {
                answers
            }
        }
        .card()
    }

    /// The answers, the recommended one prominent, then Open; they wrap
    /// to a column when they do not fit on one line.
    private var answers: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.compact) { buttons }
            VStack(alignment: .leading, spacing: Spacing.compact) { buttons }
        }
        .padding(.leading, PhoneMetrics.iconColumn + Spacing.cozy)
        .disabled(isAnswering)
    }

    /// Compact answers (mockup 1's `.btn`), 44 pt tall to tap.
    @ViewBuilder private var buttons: some View {
        ForEach(row.options) { option in
            if option.isRecommended {
                Button { onPick(option) } label: { answerLabel(option.label) }.buttonStyle(.borderedProminent)
            } else {
                Button { onPick(option) } label: { answerLabel(option.label) }.buttonStyle(.bordered)
            }
        }
        link { answerLabel("Open") }.buttonStyle(.bordered)
    }

    private func answerLabel(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .lineLimit(2)
            .frame(minHeight: PhoneMetrics.minTouch - 2 * Spacing.compact)
    }

    @ViewBuilder
    private func link<Label: View>(@ViewBuilder _ label: () -> Label) -> some View {
        switch row.destination {
        case let .ask(id): NavigationLink(value: AskRoute(id: id), label: label)
        case let .session(id): NavigationLink(value: SessionRoute(id: id), label: label)
        }
    }
}

/// The next meeting as a calendar row (mockup 1), tap for the event, with
/// Record under it.
private struct NextMeetingRow: View {
    @Environment(AppEnvironment.self) private var env
    let card: NextMeetingCardModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            NavigationLink(value: card.id) {
                CalendarRow(model: card.row)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            RecordButton {
                Task { await env.recorder.recordMeeting(card.meetingEvent) }
            }
            .disabled(!env.canStartCapture)
        }
    }
}
