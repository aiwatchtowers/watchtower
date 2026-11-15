import WatchtowerCore

/// One native button of a row with a `ref`: what `InboxRowActionsView`
/// draws and what `InboxRefHooks.accessibilityPresses` names, from the one
/// list `InboxRowActionsContent.rowButtons(hasBulk:)`, so the two never drift.
struct InboxRowButton: Equatable {
    /// On the row, or in its ⋯ menu (hidden while the row is busy).
    enum Place: Equatable { case bar, more }

    let title: String
    let press: InboxRowPress
    var enabled = true
    var place: Place = .bar
    var destructive = false
    var help: String?
    /// A menu's choices (Snooze ▾, Not now ▾); VoiceOver names each
    /// "<menu> <choice>".
    var choices: [Self] = []
    /// An idea's Not now choice: its day is computed at the press, never
    /// when the row was drawn.
    var notNow: IdeaNotNow?

    /// The press as of now.
    var currentPress: InboxRowPress {
        notNow.map { .notNow(until: $0.until()) } ?? press
    }
}

extension InboxRowActionsContent {
    /// The row's native buttons in the order drawn, each with its enable
    /// rule. `hasBulk`: a sender or Older row's **Mark All Done…** press is
    /// there (the row draws none without it).
    func rowButtons(hasBulk: Bool) -> [InboxRowButton] {
        switch kind {
        case let .inboxItem(openLabel, openEnabled, canReply, showsHandToAgent):
            let snooze = InboxMessagePane.snoozeChoices.map {
                InboxRowButton(title: $0.label, press: .snooze(duration: $0.duration),
                               enabled: !isOff(.snooze(duration: $0.duration)))
            }
            return (openLabel.map { [InboxRowButton(title: $0, press: .open, enabled: openEnabled)] } ?? [])
                + (canReply ? [InboxRowButton(title: "Reply…", press: .reply, enabled: reply == nil && !isOff(.reply))] : [])
                + [own("Done", .done), own("Hide", .hide),
                   InboxRowButton(title: "Snooze", press: .snooze(duration: ""), enabled: !isOff(.snooze(duration: "")),
                                  choices: snooze),
                   InboxRowButton(title: "Discuss in Chat", press: .discussInChat, place: .more)]
                + (showsHandToAgent ? [InboxRowButton(title: "Hand to Agent…", press: .handToAgent, place: .more)] : [])
        case let .track(custom, linkedTargetID):
            return [own("Done", .done), own("Stop watching", .stopWatching, place: .more)]
                + (custom ? [] : [own("Make a Task", .makeTask, place: .more)])
                + (custom && linkedTargetID != nil ? [own("Go to Target", .goToTarget, place: .more)] : [])
                + (custom ? [own("Delete…", .deleteTrack, place: .more)] : [])
        case let .idea(kind, status, awaitsVerdict):
            return Self.ideaButtons(kind: kind, status: status, awaitsVerdict: awaitsVerdict).map(ideaButton)
        case .reminder:
            return [own("Done", .done), own("Snooze 1h", .snoozeHour)]
        case let .action(_, buttons):
            return buttons.map(actionButton)
        case .mailSender, .waitingOlder:
            return bulkRowPresses.compactMap { press in
                switch press {
                case .open:
                    InboxRowButton(title: "Open", press: .open, enabled: senderOpenEnabled,
                                   help: (senderLink ?? (senderOpenEnabled ? .opens : .missing)).help)
                case .markAllDone: hasBulk ? own("Mark All Done…", .markAllDone) : nil
                case .mute: own("Mute", .mute, help: "Hide this sender from Mail waiting; the mail stays where it is")
                default: nil
                }
            }
        }
    }

    /// A button enabled unless `isOff(press)`.
    private func own(
        _ title: String, _ press: InboxRowPress, place: InboxRowButton.Place = .bar, help: String? = nil
    ) -> InboxRowButton {
        InboxRowButton(title: title, press: press, enabled: !isOff(press), place: place, help: help)
    }

    private func ideaButton(_ button: IdeaButton) -> InboxRowButton {
        switch button {
        case .approve: own("Approve", .approve)
        case .makeTask: own("Make a Task", .makeTask)
        case .notNow:
            InboxRowButton(
                title: "Not now", press: button.press, enabled: !isOff(button.press),
                choices: IdeaNotNow.allCases.map {
                    InboxRowButton(title: $0.label, press: button.press, enabled: !isOff(button.press), notNow: $0)
                })
        case .reject: InboxRowButton(title: "Reject", press: .reject, enabled: !isOff(.reject), destructive: true)
        case .activate: own("Activate", .activate)
        case .drop: InboxRowButton(title: "Drop", press: .drop, enabled: !isOff(.drop), destructive: true)
        }
    }

    private func actionButton(_ button: ActionButton) -> InboxRowButton {
        switch button {
        case .approve: own("Approve", .approve)
        case .reject: own("Reject", .reject)
        case .edit: own("Edit…", .edit, help: "Open the full proposal")
        case .openDraft: own("Open Draft", .openDraft, help: "Read the whole recipe in the editor and save it there")
        case .retry: own("Retry", .retry)
        case .dismiss: own("Dismiss", .dismiss, help: ConnectorCallProposal.dismissNote)
        }
    }
}
