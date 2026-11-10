import SwiftUI
import WatchtowerCore

/// The Desktop's side of A's row `ref` seam (spec "Native row actions for a
/// `ref`"): a row draws only while its record is shown (`InboxRefState`),
/// carries at its trailing edge exactly the buttons that kind's Inbox card
/// has today, and under it a failed press's line with **Retry**. Every press
/// goes to `InboxRowActionHandler`, which calls today's functions only.
@MainActor
struct InboxRefHooks {
    let vm: ActionStripViewModel
    let navScreens: Set<String>
    var workbenches: [Workbench] = []
    /// `AgentActionCardView.sessionHoldsCall` for a proposal (a connector call).
    var sessionHoldsCall: (AgentAction) -> Bool = { _ in false }
    /// The idea verdicts' `IdeasViewModel` is there; without it an idea
    /// row's buttons are drawn disabled.
    var ideasAvailable = true
    var onCommand: (InboxCardCommand) -> Void = { _ in }
    var onPress: (InboxRef, InboxRowPress) -> Void = { _, _ in }

    var hooks: ArtifactRefHooks {
        Self.make(
            isShown: { vm.folderMenu.snapshot.refState.isShown($0) },
            content: content, subject: subject, workbenches: workbenches, onCommand: onCommand, onPress: onPress)
    }

    /// The hooks over `content` (nil: no native actions): the buttons at the
    /// row's trailing edge, a proposal's summary, a failed press's line or
    /// the Reply composer under it, an idea row's own press. The design shots draw through it too.
    static func make(
        isShown: @escaping (InboxRef) -> Bool,
        content: @escaping (InboxRef, ArtifactRenderMode) -> InboxRowActionsContent?,
        subject: @escaping (InboxRef) -> InboxCardSubject? = { _ in nil },
        workbenches: [Workbench] = [],
        onCommand: @escaping (InboxCardCommand) -> Void = { _ in },
        onPress: @escaping (InboxRef, InboxRowPress) -> Void = { _, _ in }
    ) -> ArtifactRefHooks {
        ArtifactRefHooks(
            isOpen: { isShown(inboxRef($0)) },
            nativeActions: { ref, mode in
                let inbox = inboxRef(ref)
                guard let content = content(inbox, mode) else { return nil }
                return AnyView(InboxRefRowActions(
                    content: content, subject: subject(inbox), workbenches: workbenches, onCommand: onCommand
                ) { onPress(inbox, $0) })
            },
            // The recipe's own buttons step aside only for native ones: a
            // shown row the read does not list (past a cap, a kind its list
            // leaves out) keeps them, never ending with no buttons.
            nativeKinds: { ref in
                guard let content = content(inboxRef(ref), .inbox) else { return [] }
                return nativeKinds(ref.kind, hasReply: content.hasReply)
            },
            nativeFooter: { ref, mode in
                let inbox = inboxRef(ref)
                guard let content = content(inbox, mode), content.hasFooter else { return nil }
                return AnyView(InboxRowActionsFooter(content: content) { onPress(inbox, $0) })
            },
            open: { ref in
                // An idea row opens its full card (Merge…, Make a Task, Delete…).
                guard ref.kind == .idea else { return nil }
                let inbox = inboxRef(ref)
                return { onPress(inbox, .open) }
            }
        )
    }

    /// The Core mirror of a Kit ref (the same raw values).
    static func inboxRef(_ ref: ArtifactRef) -> InboxRef {
        let kind: InboxRef.Kind = switch ref.kind {
        case .inboxItem: .inboxItem
        case .track: .track
        case .idea: .idea
        case .reminder: .reminder
        case .action: .action
        }
        return InboxRef(kind: kind, id: ref.id)
    }

    /// The recipe's row actions a native one replaces ("Duplicates"): a
    /// ping keeps one Open, one Discuss in Chat and one Hand to Agent…; a
    /// track and an idea have Make a Task natively; a reminder's Slack link
    /// is its card's. A ping with a native Reply… (Slack, Jira, Linear)
    /// also drops the recipe's `reply`; a mail item keeps it.
    static func nativeKinds(_ kind: ArtifactRefKind, hasReply: Bool = false) -> Set<ArtifactActionKind> {
        switch kind {
        case .inboxItem: hasReply ? [.open, .chat, .agent, .reply] : [.open, .chat, .agent]
        case .track, .idea: [.target]
        case .reminder: [.open]
        case .action: []
        }
    }

    /// The row's native actions as the last read has its record; nil (no
    /// actions) when the read does not list it.
    func content(_ ref: InboxRef, _ mode: ArtifactRenderMode) -> InboxRowActionsContent? {
        guard let kind = kind(ref) else { return nil }
        let reply = ref.kind == .inboxItem ? vm.replyState(Int(ref.id)) : nil
        return InboxRowActionsContent(kind: kind, state: state(ref), reply: reply, isPreview: mode == .preview,
                                      cliMissing: mode != .preview && vm.folderMenu.isCLIMissing,
                                      writesUnavailable: ref.kind == .idea && !ideasAvailable,
                                      failedVerb: ref.kind == .action ? vm.actionFeed.rowErrors[ref.id]?.verb : nil)
    }

    /// Reply on the Messages entry's message card while it stands in for
    /// Waiting for me (before its first run, after a failed run): the same
    /// Reply… as a row, for an item with a write path, off with the
    /// footer's line while the CLI is missing. Nil otherwise — today's card.
    func messageReply(_ row: HomeFeedInboxRow) -> InboxRowActionsContent? {
        guard vm.folderMenu.snapshot.waitingForMe.messagesStandIn,
              InboxReplyPolicy.tool(for: row.item) != nil else { return nil }
        let id = row.item.id
        return InboxRowActionsContent(
            kind: .inboxItem(openLabel: nil, openEnabled: false, canReply: true, showsHandToAgent: true),
            state: vm.isWriting(.message(id)) ? .busy : .idle, reply: vm.replyState(id),
            cliMissing: vm.folderMenu.isCLIMissing)
    }

    /// The title a Reply names as its host ("Reply from <host>"): the
    /// artifact the row is on, else the Messages legacy entry.
    static func replyHost(_ item: InboxListItem?) -> String {
        guard case let .output(card)? = item else { return "Messages" }
        return card.title.isEmpty ? "Automation output" : card.title
    }

    private func kind(_ ref: InboxRef) -> InboxRowActionsContent.Kind? {
        let feed = vm.feed
        switch ref.kind {
        case .inboxItem:
            guard let row = feed.messages.first(where: { Int64($0.item.id) == ref.id }) else { return nil }
            let link = InboxMessagePane.link(row.item.permalink)
            return .inboxItem(openLabel: link.map { _ in InboxMessagePane.openLabel(row.item.triggerType) },
                              openEnabled: link.map { InboxCardLinkPolicy.permits($0, navScreens: navScreens) } ?? false,
                              canReply: InboxReplyPolicy.tool(for: row.item) != nil, showsHandToAgent: true)
        case .track:
            guard let track = feed.tracks.first(where: { Int64($0.track.id) == ref.id })?.track else { return nil }
            return .track(custom: track.isCustom, linkedTargetID: track.linkedTargetID.map(Int64.init))
        case .idea:
            guard let idea = feed.ideas.first(where: { Int64($0.id) == ref.id }) else { return nil }
            return .idea(kind: idea.kind, status: idea.status, awaitsVerdict: idea.awaitsVerdict)
        case .reminder:
            return feed.reminders.contains { $0.id == ref.id } ? .reminder : nil
        case .action:
            guard let action = feed.proposals.first(where: { $0.id == ref.id }) else { return nil }
            let buttons = AgentActionCardView.rowButtons(
                for: action, sessionHolds: sessionHoldsCall(action), offersRetry: !vm.isSupersededButtonRow(action))
            return .action(summary: AgentActionCardView.rowSummary(for: action), buttons: buttons)
        }
    }

    /// Busy while a press on the row runs; failed while its last press's
    /// error stands. A proposal's both live in `AgentActionFeed`.
    private func state(_ ref: InboxRef) -> InboxRowActionsContent.State {
        if ref.kind == .action {
            if vm.actionFeed.inFlight.contains(ref.id) { return .busy }
            return vm.actionFeed.rowErrors[ref.id].map { .failed(message: $0.message) } ?? .idle
        }
        if vm.isWriting(ref.selection) { return .busy }
        return vm.rowErrors[ref.selection].map { .failed(message: $0.message) } ?? .idle
    }

    /// What Discuss in Chat and Hand to Agent… carry for a ping.
    private func subject(_ ref: InboxRef) -> InboxCardSubject? {
        guard ref.kind == .inboxItem,
              let row = vm.feed.messages.first(where: { Int64($0.item.id) == ref.id }) else { return nil }
        return InboxCardSubject(message: row)
    }
}

/// A row's native buttons with the Hand to Agent… picker anchored to them
/// (`InboxCommonRow`'s rule: the card's own workbench, else the picker,
/// else the press as it is and `AppState.perform` says why).
struct InboxRefRowActions: View {
    let content: InboxRowActionsContent
    let subject: InboxCardSubject?
    let workbenches: [Workbench]
    let onCommand: (InboxCardCommand) -> Void
    let onPress: (InboxRowPress) -> Void

    @State private var picking = false

    var body: some View {
        InboxRowActionsView(content: content) { press in
            if press == .handToAgent, let subject {
                handToAgent(subject)
            } else {
                onPress(press)
            }
        }
        .popover(isPresented: $picking, arrowEdge: .bottom) {
            if let subject {
                InboxWorkbenchPicker(workbenches: workbenches) { id in
                    picking = false
                    onCommand(.agent(subject, task: InboxCardTexts.handToAgentTask(subject), workbench: .id(id)))
                }
                .popoverSurface()
            }
        }
    }

    private func handToAgent(_ subject: InboxCardSubject) {
        let task = InboxCardTexts.handToAgentTask(subject)
        switch InboxAgentHandoff.workbench(for: nil, cardWorkbenchID: subject.workbenchID, workbenches: workbenches) {
        case .workbench(let id): onCommand(.agent(subject, task: task, workbench: .id(id)))
        case .pick where !workbenches.isEmpty: picking = true
        case .pick: onCommand(.agent(subject, task: task, workbench: nil))
        }
    }
}

/// Carries out a press on a row's native actions through today's functions
/// only (STRIP-03): a ping's Done / Hide / Snooze through the strip's
/// `watchtower inbox …`, its Open / Discuss in Chat as the card's commands;
/// a track's Done and Stop watching through the strip's writes, Make a Task
/// as its card does; an idea's verdicts through `IdeasViewModel` (IDEA-04);
/// a reminder's Done and Snooze 1h through the strip's GRDB writes; a
/// proposal's Approve / Reject / Retry / Dismiss through `AgentActionFeed`.
/// **Retry** under a failed press repeats exactly that press.
@MainActor
struct InboxRowActionHandler {
    let vm: ActionStripViewModel
    var ideas: IdeasViewModel?
    var onCommand: (InboxCardCommand) -> Void = { _ in }
    /// A track's Make a Task (`AppState.makeTask(fromTrack:)`): why it failed, or nil.
    var onMakeTaskFromTrack: (Track) async -> String? = { _ in nil }
    var onGoToTarget: (Int) -> Void = { _ in }
    /// An idea made into a task: its new target's id.
    var onIdeaMadeTask: (Int) -> Void = { _ in }
    /// **Edit…** on a proposal: its native card's argument editor.
    var onEditAction: (Int64) -> Void = { _ in }
    /// **Open Draft** on a pending `save_automation` (`AppState.openSaveProposalDraft`).
    var onOpenSaveDraft: (SaveAutomationCardModel) -> Void = { _ in }
    /// `AgentActionCardView.sessionHoldsCall` for a proposal (a connector call).
    var sessionHoldsCall: (AgentAction) -> Bool = { _ in false }
    var navScreens: Set<String> = []
    var now: () -> Date = { Date() }
    /// The title of what the rows are on — an artifact's, or "Messages" for
    /// the legacy entry — for a Reply's reason ("Reply from <host>").
    var replyHost = "Messages"

    func press(_ press: InboxRowPress, on ref: InboxRef) async {
        if pressNow(press, on: ref) { return }
        if press == .retryFailedPress {
            await retry(ref)
            return
        }
        switch ref.kind {
        case .inboxItem: await message(press, id: Int(ref.id))
        case .track: await track(press, id: Int(ref.id))
        case .idea: await idea(press, id: Int(ref.id))
        case .reminder: await reminder(press, id: ref.id)
        case .action: await action(press, id: ref.id)
        }
    }

    /// The Reply composer's own presses (open, type, cancel), carried out at
    /// once so keystrokes never reorder; true when `press` was one of them.
    @discardableResult
    func pressNow(_ press: InboxRowPress, on ref: InboxRef) -> Bool {
        guard ref.kind == .inboxItem else { return false }
        let id = Int(ref.id)
        switch press {
        case .reply: vm.startReply(id)
        case let .replyChanged(text): vm.editReply(id, text: text)
        case .cancelReply: vm.cancelReply(id)
        default: return false
        }
        return true
    }

    /// The failed press again: a proposal's by the verb that failed, any
    /// other row's as it was kept with its error.
    private func retry(_ ref: InboxRef) async {
        if ref.kind == .action {
            // The failed verb again, only while the row still offers it: an
            // Approve whose execution then failed is not approved twice.
            guard let verb = vm.actionFeed.rowErrors[ref.id]?.verb,
                  let action = vm.feed.proposals.first(where: { $0.id == ref.id }),
                  let again = InboxRowActionsContent.actionRetry(
                      verb: verb,
                      buttons: AgentActionCardView.rowButtons(
                          for: action, sessionHolds: sessionHoldsCall(action),
                          offersRetry: !vm.isSupersededButtonRow(action)))
            else { return }
            await self.action(again, id: ref.id)
            return
        }
        guard let failed = vm.rowErrors[ref.selection]?.press, failed != .retryFailedPress else { return }
        await press(failed, on: ref)
    }

    private func message(_ press: InboxRowPress, id: Int) async {
        guard let row = vm.feed.messages.first(where: { $0.item.id == id }) else { return }
        let subject = InboxCardSubject(message: row)
        switch press {
        case .open:
            if let link = InboxMessagePane.link(row.item.permalink),
               InboxCardLinkPolicy.permits(link, navScreens: navScreens) {
                onCommand(.openLink(link))
            }
        case .discussInChat: onCommand(.chat(subject, message: InboxCardTexts.discussMessage(subject)))
        case .done: await vm.messageDone(id)
        case .hide: await vm.hideMessage(id)
        case let .snooze(duration): await vm.snoozeMessage(id, duration: duration)
        case .proposeReply:
            guard let draft = vm.replyDrafts[id] else { return }
            await vm.proposeReply(id, text: draft.text, host: replyHost)
        default: break
        }
    }

    private func track(_ press: InboxRowPress, id: Int) async {
        guard let track = vm.feed.tracks.first(where: { $0.track.id == id })?.track else { return }
        switch press {
        case .done: await vm.markTrackDone(id)
        case .stopWatching: await vm.stopWatching(track)
        case .makeTask:
            await vm.runRowPress(.track(id), press: .makeTask) { await onMakeTaskFromTrack(track) }
        case .goToTarget:
            if let target = track.linkedTargetID { onGoToTarget(target) }
        case .deleteTrack:
            // Its inline confirmation lives on the track's card.
            await vm.open(folder: nil, select: .card(.track(id)))
        default: break
        }
    }

    private func idea(_ press: InboxRowPress, id: Int) async {
        if press == .open {
            await vm.open(folder: nil, select: .card(.idea(id)))
            return
        }
        guard let ideas, let idea = vm.feed.ideas.first(where: { $0.id == id }) else { return }
        let verdict: (() async -> Bool)? = switch press {
        case .approve: { await ideas.approve(idea) }
        case .reject: { await ideas.reject(idea) }
        case .activate: { await ideas.activate(idea) }
        case .drop: { await ideas.drop(idea) }
        case let .notNow(until): { await ideas.notNow(idea, until: until) }
        default: nil
        }
        if let verdict {
            await vm.runRowPress(.idea(id), press: press) {
                // `write` sets `errorMessage` on the main actor before it returns: it is this call's.
                await verdict() ? nil : ideas.errorMessage ?? "Couldn't change the idea"
            }
        } else if press == .makeTask {
            await vm.runRowPress(.idea(id), press: press) {
                guard let target = await ideas.convertToTarget(idea) else {
                    return ideas.errorMessage ?? "Couldn't make a task"
                }
                onIdeaMadeTask(target)
                return nil
            }
        }
    }

    private func reminder(_ press: InboxRowPress, id: Int64) async {
        switch press {
        case .done: await vm.markReminderDone(id)
        case .snoozeHour:
            let until = ISO8601DateFormatter().string(from: now().addingTimeInterval(3600))
            await vm.snoozeReminder(id, until: until)
        default: break
        }
    }

    private func action(_ press: InboxRowPress, id: Int64) async {
        switch press {
        case .approve:
            // The args the row has now: a proposal changed since is refused by Go's digest check.
            guard let action = vm.feed.proposals.first(where: { $0.id == id }) else { return }
            await vm.approve(id, shownArgs: action.argsJSON)
        case .reject: await vm.reject(id)
        case .retry:
            // As the native card: never a superseded button row; a target
            // button's newest row retries through Try again (apply, or
            // apply --force when stranded in executing).
            guard let action = vm.feed.proposals.first(where: { $0.id == id }),
                  !vm.isSupersededButtonRow(action) else { return }
            if vm.targetFacts(for: action) != nil { await vm.tryAgainTarget(id) } else { await vm.retry(id) }
        case .dismiss: await vm.dismiss(id)
        case .edit: onEditAction(id)
        case .openDraft:
            guard let action = vm.feed.proposals.first(where: { $0.id == id }),
                  action.tool == SaveAutomationCardModel.tool else { return }
            onOpenSaveDraft(SaveAutomationCardModel(action: action))
        default: break
        }
    }
}
