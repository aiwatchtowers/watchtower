import Observation
import SwiftUI
import WatchtowerChatText
import WatchtowerKit
import WatchtowerSync

/// The Mac's live line on the phone (#2112 spec §4, §5; mockups L1–L8, L10): what the session (or one subagent) does
/// now, above the composer, and the turn's steps behind a tap. The wording is the shared `WorkchatLivePresentation`'s;
/// this model only decides what to feed it from the chat record, the session's state and the tower's freshness.
enum WorkchatLiveLine {
    /// Failure and out of date: the freshness line's tone (the phone keeps orange for waiting and asks, spec §14).
    static let warningToneUse = ToneUse(element: "workchat live line warning", tone: ReplicaFreshness.tone, role: .status)

    /// Busy as the Mac's `busy` counts it: a turn, background agents (they go out as working) or an approval (a
    /// permission card pauses the turn, it does not end it).
    static func working(_ session: TerminalSessionState) -> Bool {
        session.live && [.working, .needsApproval].contains(session.stateKind)
    }

    /// A subagent's line runs while the session works and the subagent's own turn has not ended.
    static func working(_ session: TerminalSessionState, subagent chat: SessionChat?) -> Bool {
        working(session) && chat?.activityLive?.turnActive != false
    }

    /// What one chat screen feeds the line at a moment.
    struct Inputs: Equatable {
        var chat: SessionChat?
        /// The record answers this opening of the screen (`SessionChatViewModel.recordArrivedSinceOpen`).
        var arrivedSinceOpen: Bool
        var working: Bool
        var stateAt: Date?
        /// `ReplicaFreshness.staleSince`: nil while the tower sends.
        var staleSince: Date?
        /// A permission card or an inline ask stands above the composer.
        var cardShown = false
        var stepsOpen = false
    }

    /// The live line, or nil: no turn runs, an older hub (no live block), no record yet behind a stale tower, or a
    /// permission card or ask stands in for it.
    static func row(_ inputs: Inputs, now: Date) -> WorkchatLivePresentation.Row? {
        guard inputs.working, let fed = feed(inputs, now: now) else { return nil }
        let row = WorkchatLivePresentation.row(
            snapshot: fed.snapshot, error: fed.error, loaded: fed.loaded, working: true, stateAt: inputs.stateAt, now: now,
            activityHidden: inputs.cardShown, stepsOpen: inputs.stepsOpen
        )
        return row?.activity == true ? row : nil
    }

    /// The turn's steps above the line while the owner has them open, or nil.
    static func steps(_ inputs: Inputs, now: Date) -> WorkchatLivePresentation.StepsSlot? {
        guard inputs.stepsOpen, inputs.working, !inputs.cardShown, let fed = feed(inputs, now: now) else { return nil }
        return WorkchatLivePresentation.stepsSlot(snapshot: fed.snapshot, error: fed.error, working: true, now: now)
    }

    /// What the steps slot's own closing watches (spec §5): the turn, a card and the conversation.
    struct StepsWatch: Equatable {
        var working: Bool
        /// The live block says the turn is over; false without a block (the slot hides then, it does not close).
        var turnOver: Bool
        var cardShown: Bool
        var conversation: String?
        var turnAt: Date?

        init(chat: SessionChat?, working: Bool, cardShown: Bool) {
            self.working = working
            turnOver = chat?.activityLive.map { !$0.turnActive } ?? false
            self.cardShown = cardShown
            conversation = chat?.activityLive?.conversation
            turnAt = chat?.activityLive?.turnAt
        }
    }

    private struct Fed {
        var snapshot: SessionFeedLive?
        var error: String?
        var loaded: Bool
    }

    /// Spec §4's table, as the presentation's inputs; nil when no line may show. The snapshot's `observedAt` is the
    /// tower's freshness (C4), never the hub's read time: now while the tower sends, `staleSince` once it stopped.
    private static func feed(_ inputs: Inputs, now: Date) -> Fed? {
        let stale = inputs.staleSince != nil
        guard let chat = inputs.chat else {
            // No record yet: Loading while the tower sends; behind a stale tower nothing says the hub is live-capable.
            return stale ? nil : Fed(snapshot: nil, error: nil, loaded: false)
        }
        // An older hub never has a line, stale or not.
        guard chat.liveVersion != nil else { return nil }
        guard inputs.arrivedSinceOpen || stale else { return Fed(snapshot: nil, error: nil, loaded: false) }
        let error = inputs.arrivedSinceOpen ? chat.liveError : nil
        // The hub saw no turn yet, or the tower stopped before this opening's record: "Working…" or the stale wording.
        var snapshot = chat.activityLive ?? (error == nil || stale ? SessionFeedLive(observedAt: nil, turnActive: false) : nil)
        snapshot?.observedAt = inputs.staleSince ?? now
        return Fed(snapshot: snapshot, error: error, loaded: true)
    }
}

/// The owner's steps toggle per chat while the app runs (spec §5): closed by default, it closes by itself at turn
/// end, Stop, a permission card, a new conversation or a new turn.
@MainActor
@Observable
final class WorkchatStepsMemory {
    /// The turn a slot was opened on.
    private struct Opened {
        var conversation: String?
        var turnAt: Date?
    }

    private var open: [SessionChatRoute: Opened] = [:]

    func isOpen(_ route: SessionChatRoute) -> Bool { open[route] != nil }

    func toggle(_ route: SessionChatRoute, _ watch: WorkchatLiveLine.StepsWatch) {
        open[route] = isOpen(route) ? nil : Opened(conversation: watch.conversation, turnAt: watch.turnAt)
    }

    func close(_ route: SessionChatRoute) { open[route] = nil }

    /// Stop closes the slot once the Mac took the request; a refused Stop leaves it as it was.
    func close(_ route: SessionChatRoute, after stop: () async throws -> Void) async throws {
        try await stop()
        close(route)
    }

    /// Closes the slot once the turn it showed is over or out of sight. A conversation or turn appearing where the
    /// slot was opened without one does not count as a new one.
    func note(_ route: SessionChatRoute, _ watch: WorkchatLiveLine.StepsWatch) {
        guard let opened = open[route] else { return }
        let newConversation = opened.conversation != nil && watch.conversation != nil && watch.conversation != opened.conversation
        let newTurn = opened.turnAt != nil && watch.turnAt != nil && watch.turnAt != opened.turnAt
        if !watch.working || watch.cardShown || watch.turnOver || newConversation || newTurn {
            open[route] = nil
        }
    }

    /// Forgets the chats of sessions the replica no longer has.
    func prune(keeping sessions: Set<Int64>) {
        for route in open.keys where !sessions.contains(route.sessionID) {
            open[route] = nil
        }
    }
}

/// The line and, when open, the turn's steps above it, under one one-second timeline that runs only while a line
/// shows. Shared by the workchat and a subagent's chat.
struct WorkchatLiveSection: View {
    let route: SessionChatRoute
    /// The inputs at a moment (the tower's freshness moves with the clock).
    let inputs: (Date) -> WorkchatLiveLine.Inputs
    let steps: WorkchatStepsMemory
    let onRetry: () -> Void

    var body: some View {
        if WorkchatLiveLine.row(inputs(.now), now: .now) != nil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let now = context.date
                let current = inputs(now)
                VStack(spacing: 0) {
                    if let slot = WorkchatLiveLine.steps(current, now: now) {
                        WorkchatStepsSlotView(slot: slot)
                    }
                    if let row = WorkchatLiveLine.row(current, now: now) {
                        WorkchatLiveLineView(
                            row: row,
                            onToggleSteps: {
                                let input = inputs(.now)
                                steps.toggle(route, .init(chat: input.chat, working: input.working, cardShown: input.cardShown))
                            },
                            onRetry: onRetry
                        )
                    }
                }
            }
        }
    }
}

/// The line: symbol (pulsing on a running step unless Reduce Motion), the text cut in the middle, Retry or the timer,
/// and the steps chevron. With steps the whole line is their toggle.
struct WorkchatLiveLineView: View {
    let row: WorkchatLivePresentation.Row
    let onToggleSteps: () -> Void
    let onRetry: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Spacing.compact) {
            if row.chevron != nil {
                Button(action: onToggleSteps) {
                    activity.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(WorkchatLivePresentation.stepsToggleHint(open: row.chevron == "chevron.down"))
            } else {
                activity
            }
            if row.retry {
                Button(action: onRetry) {
                    Text(WorkchatLivePresentation.retryTitle)
                        .font(TypeScale.meta.weight(.semibold))
                        .foregroundStyle(PhoneTone.accent.color)
                        .frame(minHeight: PhoneMetrics.minTouch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .font(TypeScale.meta)
        .foregroundStyle(row.warning ? WorkchatLiveLine.warningToneUse.tone.color : PhoneTone.secondary.color)
        .padding(.horizontal, Spacing.large)
        .frame(maxWidth: .infinity, minHeight: PhoneMetrics.minTouch, alignment: .leading)
        .background(Fill.rest, ignoresSafeAreaEdges: [])
    }

    private var activity: some View {
        HStack(spacing: Spacing.compact) {
            Image(systemName: row.symbol)
                .symbolEffect(.pulse, isActive: row.pulse && !reduceMotion)
                .frame(width: PhoneMetrics.iconColumn)
                .accessibilityHidden(true)
            Text(row.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Spacing.compact)
            if let elapsed = row.elapsed {
                Text(elapsed).monospacedDigit()
            }
            if let chevron = row.chevron {
                Image(systemName: chevron).font(TypeScale.capsHeader).accessibilityHidden(true)
            }
        }
        .frame(minHeight: PhoneMetrics.minTouch)
        .accessibilityElement(children: .combine)
    }
}

/// The turn's steps above the line: six rows tall from the moment it opens, scrolling past that, pinned to the
/// newest step; the running step in the primary colour with its timer.
struct WorkchatStepsSlotView: View {
    let slot: WorkchatLivePresentation.StepsSlot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .caption) private var rowHeight: CGFloat = 26

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(slot.rows) { step($0) }
            }
            .padding(.vertical, Spacing.small)
        }
        .defaultScrollAnchor(.bottom)
        .frame(height: WorkchatLivePresentation.stepsHeight(rowHeight: rowHeight) + 2 * Spacing.small)
        .background(Fill.rest, ignoresSafeAreaEdges: [])
    }

    private func step(_ row: WorkchatLivePresentation.StepRow) -> some View {
        HStack(spacing: Spacing.compact) {
            Image(systemName: row.symbol)
                .symbolEffect(.pulse, isActive: row.running && !reduceMotion)
                .frame(width: PhoneMetrics.iconColumn)
                .accessibilityHidden(true)
            Text(row.summary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: Spacing.compact)
            if let time = row.time {
                Text(time).monospacedDigit()
            }
        }
        .font(TypeScale.meta)
        .foregroundStyle(row.running ? PhoneTone.primary.color : PhoneTone.secondary.color)
        .padding(.horizontal, Spacing.large)
        .frame(height: rowHeight)
        .accessibilityElement(children: .combine)
    }
}
