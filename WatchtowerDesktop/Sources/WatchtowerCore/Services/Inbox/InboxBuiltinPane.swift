import Foundation

/// Which pane an artifact's reading pane draws (spec "Waiting for me and
/// Mail waiting", "Slack today"): Slack today's own pane, the two waiting
/// built-ins under their count line, or any other artifact under its
/// provenance line with the **Run** link.
package enum InboxBuiltinPane: Equatable, Sendable {
    case slackToday, waitingForMe, mailWaiting, other

    /// The pane for an artifact of `automationID`, given the built-ins'
    /// automations as read (nil: that built-in is not there).
    package static func of(
        automationID: Int64,
        slackToday: Int64?,
        waitingForMe: Int64?,
        mailWaiting: Int64?
    ) -> Self {
        switch automationID {
        case slackToday: .slackToday
        case waitingForMe: .waitingForMe
        case mailWaiting: .mailWaiting
        default: .other
        }
    }

    package static func of(_ card: AutomationOutputCard, _ read: InboxFolderMenuSnapshot) -> Self {
        of(automationID: card.automationID, slackToday: read.slackToday?.automationID,
           waitingForMe: read.waitingForMe.automationID, mailWaiting: read.mailWaiting.automationID)
    }

    /// The header's **Run** link to the card's run: an ordinary artifact
    /// only. The waiting built-ins say their counts instead.
    package var showsRunLink: Bool { self == .other }

    /// **Mute Senders…** in the header: Mail waiting only.
    package var offersMuteSenders: Bool { self == .mailWaiting }

    /// The Morning brief's **All in Waiting for me** target in `entries`:
    /// Waiting for me's artifact, else the Messages entry standing in for
    /// it, else nil (no link).
    package static func waitingForMeEntryID(_ entries: [InboxFolderEntry], waitingForMe: Int64?) -> String? {
        if let waitingForMe, let artifact = entries.first(where: { entry in
            if case let .artifact(card) = entry { return card.automationID == waitingForMe }
            return false
        }) {
            return artifact.id
        }
        return entries.contains(.legacyMessages) ? InboxFolderEntry.legacyMessages.id : nil
    }
}
