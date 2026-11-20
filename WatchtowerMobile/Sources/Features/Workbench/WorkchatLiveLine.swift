import Observation
import SwiftUI
import WatchtowerChatText
import WatchtowerKit
import WatchtowerSync

/// The Mac's live line on the phone (#2112 spec §4, §5; mockups L1–L7, L10): what the session does now, above the
/// composer, and the turn's steps behind a tap. The wording is the shared `WorkchatLivePresentation`'s; this model only
/// decides what to feed it from the chat record, the session's state and the tower's freshness.
enum WorkchatLiveLine {
    /// Failure and out-of-date: the phone keeps orange for waiting and asks (spec §14), so red as the freshness line.
    static let warningTone = PhoneTone.red

    /// Busy as the Mac's `busy` counts it: a turn, background agents (they go out as working) or an approval (a
    /// permission card pauses the turn, it does not end it).
    static func working(_ session: TerminalSessionState) -> Bool {
        session.live && [.working, .needsApproval].contains(session.stateKind)
    }

    /// When the tower stopped sending, or nil while it sends (C4): its last publish (`lastPublishAt`, else the
    /// heartbeat) once `ReplicaFreshness` says stale or offline. A kind stuck alone does not age the line.
    static func staleSince(_ freshness: ReplicaFreshness?, heartbeat: HeartbeatPayload?) -> Date? {
        guard let freshness, freshness.state != .stuck else { return nil }
        return heartbeat.map { $0.lastPublishAt ?? $0.updatedAt } ?? .distantPast
    }

    /// The live line, or nil: no turn runs, an older hub (no live block), or a permission card or ask stands in for it.
    static func row(
        chat: SessionChat?,
        arrivedSinceOpen: Bool,
        working: Bool,
        stateAt: Date?,
        staleSince: Date?,
        cardShown: Bool,
        stepsOpen: Bool,
        now: Date
    ) -> WorkchatLivePresentation.Row? {
        guard working, let input = input(chat: chat, arrivedSinceOpen: arrivedSinceOpen, staleSince: staleSince, now: now)
        else { return nil }
        let row = WorkchatLivePresentation.row(
            snapshot: input.snapshot, error: input.error, loaded: input.loaded, working: true, stateAt: stateAt, now: now,
            activityHidden: cardShown, stepsOpen: stepsOpen
        )
        return row?.activity == true ? row : nil
    }

    /// The turn's steps above the line while the owner has them open, or nil.
    static func steps(
        chat: SessionChat?,
        arrivedSinceOpen: Bool,
        working: Bool,
        staleSince: Date?,
        cardShown: Bool,
        stepsOpen: Bool,
        now: Date
    ) -> WorkchatLivePresentation.StepsSlot? {
        guard stepsOpen, working, !cardShown,
              let input = input(chat: chat, arrivedSinceOpen: arrivedSinceOpen, staleSince: staleSince, now: now)
        else { return nil }
        return WorkchatLivePresentation.stepsSlot(snapshot: input.snapshot, error: input.error, working: true, now: now)
    }

    /// What the steps slot's own closing watches (spec §5): the turn, a card and the conversation.
    struct StepsWatch: Equatable {
        var working: Bool
        /// The live block says the turn is over; false without a block (the slot hides then, it does not close).
        var turnOver: Bool
        var cardShown: Bool
        var conversation: String?

        init(chat: SessionChat?, working: Bool, cardShown: Bool) {
            self.working = working
            turnOver = chat?.activityLive.map { !$0.turnActive } ?? false
            self.cardShown = cardShown
            conversation = chat?.activityLive?.conversation
        }
    }

    private struct Input {
        var snapshot: SessionFeedLive?
        var error: String?
        var loaded: Bool
    }

    /// Spec §4's table, as the presentation's inputs; nil for an older hub. The snapshot's `observedAt` is the tower's
    /// freshness (C4), never the hub's read time: now while the tower sends, `staleSince` once it stopped.
    private static func input(chat: SessionChat?, arrivedSinceOpen: Bool, staleSince: Date?, now: Date) -> Input? {
        // Out of date even when the last publish is recent (Relay unanswered): the presentation judges by age.
        let observedAt = staleSince.map { min($0, now.addingTimeInterval(-WorkchatLivePresentation.staleAfter)) } ?? now
        let stale = staleSince != nil
        let arrived = arrivedSinceOpen && chat != nil
        if arrived, chat?.liveVersion == nil { return nil }
        guard arrived || stale else { return Input(snapshot: nil, error: nil, loaded: false) }
        let error = arrived ? chat?.liveError : nil
        // The hub saw no turn yet, or the tower stopped before the first record: "Working…" or the stale wording.
        var snapshot = chat?.activityLive ?? (error == nil || stale ? SessionFeedLive(observedAt: nil, turnActive: false) : nil)
        snapshot?.observedAt = observedAt
        return Input(snapshot: snapshot, error: error, loaded: true)
    }
}

/// The owner's steps toggle per session while the app runs (spec §5): closed by default, it closes by itself at turn
/// end, Stop, a permission card or a new conversation.
@MainActor
@Observable
final class WorkchatStepsMemory {
    /// Open sessions, with the conversation each was opened on.
    private var open: [Int64: String?] = [:]

    func isOpen(_ sessionID: Int64) -> Bool { open[sessionID] != nil }

    func toggle(_ sessionID: Int64, conversation: String?) {
        if isOpen(sessionID) {
            open[sessionID] = nil
        } else {
            open[sessionID] = .some(conversation)
        }
    }

    func close(_ sessionID: Int64) { open[sessionID] = nil }

    /// Closes the slot once the turn it showed is over or out of sight.
    func note(_ sessionID: Int64, _ watch: WorkchatLiveLine.StepsWatch) {
        guard let opened = open[sessionID] else { return }
        let newConversation = watch.conversation.map { $0 != opened } ?? false
        if !watch.working || watch.cardShown || watch.turnOver || newConversation {
            open[sessionID] = nil
        }
    }
}

/// The line: symbol (pulsing on a running step unless Reduce Motion), the text cut in the middle, Retry or the timer,
/// and the steps chevron. With steps the whole line is their toggle. Its one-second redraw lives here only, while
/// the line is on screen.
struct WorkchatLiveLineView: View {
    /// The row at a given moment; the timeline asks it once a second.
    let row: (Date) -> WorkchatLivePresentation.Row?
    let onToggleSteps: () -> Void
    let onRetry: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let row = row(context.date) {
                line(row)
            }
        }
    }

    @ViewBuilder
    private func line(_ row: WorkchatLivePresentation.Row) -> some View {
        HStack(spacing: Spacing.compact) {
            if row.chevron != nil {
                Button(action: onToggleSteps) {
                    activity(row).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(WorkchatLivePresentation.stepsToggleHint(open: row.chevron == "chevron.down"))
            } else {
                activity(row)
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
        .foregroundStyle(row.warning ? WorkchatLiveLine.warningTone.color : PhoneTone.secondary.color)
        .padding(.horizontal, Spacing.large)
        .frame(maxWidth: .infinity, minHeight: PhoneMetrics.minTouch, alignment: .leading)
        .background(Fill.rest)
    }

    private func activity(_ row: WorkchatLivePresentation.Row) -> some View {
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
    let slot: (Date) -> WorkchatLivePresentation.StepsSlot?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .caption) private var rowHeight: CGFloat = 26

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let slot = slot(context.date) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(slot.rows) { step($0) }
                    }
                    .padding(.vertical, Spacing.small)
                }
                .defaultScrollAnchor(.bottom)
                .frame(height: WorkchatLivePresentation.stepsHeight(rowHeight: rowHeight) + 2 * Spacing.small)
                .background(Fill.rest)
            }
        }
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
