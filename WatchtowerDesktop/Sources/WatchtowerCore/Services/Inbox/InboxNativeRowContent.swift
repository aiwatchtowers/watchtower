import Foundation

/// Why Needs approval shows today's native cards instead of the recipe's,
/// and what its one press does (spec "Needs approval" → States).
package struct NeedsApprovalNoteContent: Equatable, Sendable {
    package enum State: Equatable, Sendable {
        /// The `approval-cards` feature is off: **Turn On** enables it.
        case off
        /// The built-in was stopped under AUTO-08 while the feature is on:
        /// its own **Turn On** resumes it (`resumeStoppedBuiltin`).
        case stopped
        /// The latest `needs-approval` run failed: **Run History**.
        case lastRunFailed
    }

    package let state: State
    /// The reason the last Turn On returned; the note stays.
    package var failure: String?
    /// A Turn On under way.
    package var isApplying: Bool

    package init(state: State, failure: String? = nil, isApplying: Bool = false) {
        self.state = state
        self.failure = failure
        self.isApplying = isApplying
    }

    package var text: String {
        switch state {
        case .off: "Showing approvals in the standard card — Needs approval is off."
        case .stopped:
            "Showing approvals in the standard card — Needs approval was stopped after a run that would not end."
        case .lastRunFailed: "Showing approvals in the standard card — the last run failed."
        }
    }

    package var buttonTitle: String {
        state == .lastRunFailed ? "Run History" : "Turn On"
    }
}

/// The native actions of one artifact row with a `ref` (spec "Native row
/// actions for a `ref`"): exactly that kind's Inbox card buttons today, plus
/// **Reply…** on an `inbox_item` with a write path (asks #445, #451).
package struct InboxRowActionsContent: Equatable {
    package enum Kind: Equatable {
        /// A ping (`InboxMessagePane`): Open under its source's label while
        /// it has a permalink, disabled when `InboxCardLinkPolicy` refuses
        /// it; Reply… (Slack, Jira, Linear); Done, Hide, Snooze ▾; ⋯ with
        /// Discuss in Chat and, when the card offers it, Hand to Agent….
        case inboxItem(openLabel: String?, openEnabled: Bool, canReply: Bool, showsHandToAgent: Bool)
        /// A track (`InboxTrackPane`): Done, ⋯ Stop watching and Make a Task
        /// (extracted) or Delete… (custom), Go to Target only with a linked
        /// target.
        case track(custom: Bool, linkedTargetID: Int64?)
        /// An idea: `IdeaDetailPane`'s verdict buttons for its kind and
        /// status (`ideaButtons`).
        case idea(kind: Idea.Kind, status: Idea.Status, awaitsVerdict: Bool)
        /// A due reminder: Done, Snooze 1h.
        case reminder
        /// A proposal: its own summary (`AgentActionCardView.rowSummary`),
        /// drawn under the row's line next to Approve whatever the look's
        /// row says (A's contract item 3), and the buttons its native card
        /// offers today (`AgentActionCardView.rowButtons`).
        case action(summary: String, buttons: [ActionButton])
        /// A Mail waiting sender row (`address` = its
        /// `InboxPeopleRule.senderKey`): Open (the newest mail's link,
        /// disabled without one or when `InboxCardLinkPolicy` refuses it),
        /// Mark All Done…, Mute.
        case mailSender(address: String, openEnabled: Bool)
        /// Waiting for me's Older note row: Mark All Done….
        case waitingOlder
    }

    /// One of a proposal row's buttons. **Edit…** and **Open Draft** open
    /// the native card (its argument editor, the automation editor) where
    /// the row cannot make a press the way the card does.
    package enum ActionButton: Equatable, Sendable {
        case approve, reject, edit, openDraft, retry, dismiss

        /// The press it makes.
        package var press: InboxRowPress {
            switch self {
            case .approve: .approve
            case .reject: .reject
            case .edit: .edit
            case .openDraft: .openDraft
            case .retry: .retry
            case .dismiss: .dismiss
            }
        }
    }

    package enum State: Equatable, Sendable {
        case idle
        /// A press on this row runs: its buttons wait, a progress mark shows.
        case busy
        /// The last press failed: the row stays with the error and **Retry**.
        case failed(message: String)
    }

    /// The Reply composer under an `inbox_item` row, or the caption while
    /// its proposal waits in Needs approval.
    package enum Reply: Equatable, Sendable {
        case composing(text: String, error: String?)
        case waiting
    }

    /// One of an idea row's buttons.
    package enum IdeaButton: Equatable, Sendable {
        case approve, makeTask, notNow, reject, activate, drop

        /// The press it makes (Not now's moment is picked in its menu).
        package var press: InboxRowPress {
            switch self {
            case .approve: .approve
            case .makeTask: .makeTask
            case .notNow: .notNow(until: "")
            case .reject: .reject
            case .activate: .activate
            case .drop: .drop
            }
        }
    }

    package let kind: Kind
    package var state: State
    package var reply: Reply?
    /// A's `.preview` mode: every native action drawn disabled.
    package var isPreview: Bool
    /// No `watchtower` binary: the row's presses that run the CLI are drawn
    /// disabled and the footer says why (`usesCLI`); a write straight to the
    /// database and what only opens or navigates stay.
    package var cliMissing: Bool
    /// What would carry the row's writes is not there yet (an idea's
    /// `IdeasViewModel`): its writes are drawn disabled, never dead.
    package var writesUnavailable: Bool
    /// A proposal row's failed verb (`AgentActionFeed.RowError.verb`).
    package var failedVerb: String?
    /// A sender row's Open link (its tooltip); nil for every other kind.
    package var senderLink: SenderLink?

    package init(
        kind: Kind,
        state: State = .idle,
        reply: Reply? = nil,
        isPreview: Bool = false,
        cliMissing: Bool = false,
        writesUnavailable: Bool = false,
        failedVerb: String? = nil
    ) {
        self.kind = kind
        self.state = state
        self.reply = reply
        self.isPreview = isPreview
        self.cliMissing = cliMissing
        self.writesUnavailable = writesUnavailable
        self.failedVerb = failedVerb
    }

    package var isBusy: Bool { state == .busy }

    /// A ping with **Reply…** (a Slack, Jira or Linear item).
    package var hasReply: Bool {
        if case let .inboxItem(_, _, canReply, _) = kind { return canReply }
        return false
    }

    /// A proposal's own summary, drawn under the row's line; nil for any other kind.
    package var actionSummary: String? {
        guard case let .action(summary, _) = kind, !summary.isEmpty else { return nil }
        return summary
    }

    /// Whether the row has anything under its line (`InboxRowActionsFooter`).
    package var hasFooter: Bool {
        state != .idle || reply != nil || showsCLIMissingLine || actionSummary != nil
    }

    /// The footer's missing-CLI line: only on a row that draws a press
    /// the missing CLI turns off, so a list of database-only rows stays quiet.
    package var showsCLIMissingLine: Bool { cliMissing && drawsCLIPress }

    /// Whether the row draws a press that runs the `watchtower` CLI.
    private var drawsCLIPress: Bool {
        switch kind {
        case .inboxItem: true
        case let .action(_, buttons): buttons.contains { usesCLI($0.press) }
        case let .track(custom, _): custom
        case .idea, .reminder: false
        case .mailSender, .waitingOlder: true
        }
    }

    /// Whether `press` on this row runs the `watchtower` CLI: a ping's
    /// Done / Hide / Snooze and Reply (`watchtower inbox …`, `actions
    /// propose`), every proposal verb (`watchtower actions …`), a custom
    /// track's Stop watching (its recipe through `automations disable`).
    /// A reminder's and an idea's writes, a track's Done and an auto
    /// track's Stop watching, and Make a Task are GRDB writes. A custom
    /// track's Retry counts as the CLI's: the failed press is not known here.
    package func usesCLI(_ press: InboxRowPress) -> Bool {
        guard press.writes else { return false }
        switch kind {
        case .inboxItem, .action: return true
        case let .track(custom, _): return custom && (press == .stopWatching || press == .retryFailedPress)
        case .idea, .reminder: return false
        case .mailSender, .waitingOlder: return press == .markAllDone
        }
    }

    /// A sender row's Open can be pressed (its newest mail has a link the
    /// card rules open); false for every other kind.
    package var senderOpenEnabled: Bool {
        if case let .mailSender(_, openEnabled) = kind { return openEnabled }
        return false
    }

    /// A sender or Older row's presses, in the order drawn; empty for every
    /// other kind (drawn by their own cases). Mark All Done… is a bulk
    /// press (`InboxBulkCenter`), never one of the row's own writes.
    package var bulkRowPresses: [InboxRowPress] {
        switch kind {
        case .mailSender: [.open, .markAllDone, .mute]
        case .waitingOlder: [.markAllDone]
        case .inboxItem, .track, .idea, .reminder, .action: []
        }
    }

    /// A sender row for `address` (any spelling) whose newest open mail has
    /// `newestPermalink` (`WaitingQueries.newestPermalink`).
    package static func mailSenderKind(address: String, newestPermalink: String?, navScreens: Set<String>) -> Kind {
        .mailSender(address: InboxPeopleRule.senderKey(address),
                    openEnabled: senderLink(newestPermalink, navScreens: navScreens) == .opens)
    }

    /// What a sender row's Open has: no link, a link `InboxCardLinkPolicy`
    /// refuses, or one it opens. Its `help` says why a disabled Open is off.
    package enum SenderLink: Equatable, Sendable {
        case missing, refused, opens

        package var help: String {
            switch self {
            case .missing: "This sender's newest mail has no link"
            case .refused: "This sender's newest mail has a link Watchtower doesn't open"
            case .opens: "Open this sender's newest mail"
            }
        }
    }

    package static func senderLink(_ permalink: String?, navScreens: Set<String>) -> SenderLink {
        guard let url = senderURL(permalink) else { return .missing }
        return InboxCardLinkPolicy.permits(url, navScreens: navScreens) ? .opens : .refused
    }

    /// The one parser of a sender's newest link, for Open's state and its
    /// press alike: nil for no link, an empty one or one that is not a URL.
    package static func senderURL(_ permalink: String?) -> URL? {
        guard let permalink, !permalink.isEmpty else { return nil }
        return URL(string: permalink)
    }

    /// The footer's **Retry** under a failed press. A proposal's repeats
    /// its failed verb only while the row still offers that press (an
    /// Approve whose execution then failed has left the pending state), and
    /// never beside the row's own Retry: one Retry a row.
    package var footerOffersRetry: Bool {
        guard case let .action(_, buttons) = kind else { return true }
        guard !buttons.contains(.retry), let failedVerb else { return false }
        return Self.actionRetry(verb: failedVerb, buttons: buttons) != nil
    }

    /// The press a proposal's footer **Retry** repeats for its failed
    /// `verb` (`AgentActionFeed.RowError.verb`), nil when the row's current
    /// buttons no longer offer it.
    package static func actionRetry(verb: String, buttons: [ActionButton]) -> InboxRowPress? {
        let button: ActionButton? = switch verb {
        case "approve": .approve
        case "reject": .reject
        case "apply": .retry
        case "dismiss": .dismiss
        default: nil
        }
        guard let button, buttons.contains(button) else { return nil }
        return button.press
    }

    /// The footer's line while the CLI is missing (the folder menu's words).
    package static let cliMissingMessage = InboxFoldersCLIError.cliUnavailable.localizedDescription

    /// Whether `press` is drawn disabled: a CLI press while the CLI is
    /// missing, or a write while the row's writes are unavailable.
    package func isOff(_ press: InboxRowPress) -> Bool {
        (cliMissing && usesCLI(press)) || (writesUnavailable && press.writes)
    }

    /// `IdeaActionBar`'s verdict buttons, without its Merge, delete and a
    /// decision's Supersede / Reverse (the full pane opens on a press of
    /// the row): awaiting a verdict → Approve, Make a Task (ideas), Not now
    /// (not notes), Reject; an active idea → Make a Task, Not now, Drop; a
    /// not-now idea → Activate, Make a Task, Drop; an active note → Drop; a
    /// rejected or dropped one (and a decision not now) → Activate.
    package static func ideaButtons(kind: Idea.Kind, status: Idea.Status, awaitsVerdict: Bool) -> [IdeaButton] {
        if awaitsVerdict {
            return [.approve] + (kind == .idea ? [.makeTask] : []) + (kind == .note ? [] : [.notNow]) + [.reject]
        }
        if kind == .decision {
            return [.rejected, .dropped, .notNow].contains(status) ? [.activate] : []
        }
        switch (kind, status) {
        case (.idea, .active): return [.makeTask, .notNow, .drop]
        case (.idea, .notNow): return [.activate, .makeTask, .drop]
        case (.note, .active): return [.drop]
        case (_, .rejected), (_, .dropped): return [.activate]
        default: return []
        }
    }
}

/// A press on a row's native actions (`InboxRowActionsView`).
package enum InboxRowPress: Equatable, Sendable {
    case open, reply, done, hide, snooze(duration: String), discussInChat, handToAgent
    case stopWatching, makeTask, goToTarget, deleteTrack
    case approve, reject, edit, openDraft, retry, dismiss, notNow(until: String), activate, drop
    case snoozeHour
    /// **Mark All Done…** on a sender or Older row; **Mute** on a sender row.
    case markAllDone, mute
    /// **Retry** under a failed press: repeats it.
    case retryFailedPress
    case replyChanged(String), proposeReply, cancelReply
}

package extension InboxRowPress {
    /// The press writes (a CLI call or a database write), as opposed to one
    /// that only opens, navigates or edits a draft.
    var writes: Bool {
        switch self {
        case .open, .discussInChat, .handToAgent, .goToTarget, .deleteTrack, .edit, .openDraft,
             .replyChanged, .cancelReply: false
        case .reply, .done, .hide, .snooze, .stopWatching, .makeTask, .approve, .reject, .retry, .dismiss,
             .notNow, .activate, .drop, .snoozeHour, .retryFailedPress, .proposeReply, .markAllDone, .mute: true
        }
    }
}

/// A row's failed press (spec "Native row actions", Failure): the message
/// shown under the row and the press its **Retry** repeats.
package struct InboxRowFailure: Equatable, Sendable {
    package let message: String
    package let press: InboxRowPress

    package init(message: String, press: InboxRowPress) {
        self.message = message
        self.press = press
    }
}

package extension InboxRef {
    /// The strip's key for this ref's record: its busy flag and row error;
    /// nil for a text-id ref, which has no strip record.
    var selection: InboxSelection? {
        switch kind {
        case .inboxItem: .message(Int(id))
        case .track: .track(Int(id))
        case .idea: .idea(Int(id))
        case .reminder: .reminder(id)
        case .action: .proposal(id)
        case .mailSender, .waitingOlder: nil
        }
    }
}
