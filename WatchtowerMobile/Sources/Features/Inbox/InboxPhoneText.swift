import Foundation
import WatchtowerInterface
import WatchtowerSync

/// The shared Inbox copy (`WatchtowerInterface.TowerText`); the phone's own `TowerText` (the tower word) keeps
/// the plain name.
typealias InboxText = WatchtowerInterface.TowerText
/// The generated Inbox card; the phone's `Card` is the card recipe.
typealias InboxCard = WatchtowerInterface.Card

/// The Inbox tab's own strings, the ones only the phone draws (mobile Inbox spec §7). Every other line comes from
/// the shared models and `InboxText`. `InboxPhoneTextTests` pins each one.
enum InboxPhoneText {
    static let tabTitle = "Inbox"
    /// The root's caps header over its own entries.
    static let rootHeader = "Inbox"
    static let needsApproval = "Needs approval"
    /// An `inbox_act` the outbox could not deliver.
    static func notDelivered(hub: String) -> String {
        "Not delivered — \(TowerText.name(hub)) didn't get it."
    }

    /// The phone could not read its copy of the Inbox or queue a press (a local failure): Retry tries again.
    static let localFailure = "This iPhone couldn't read or send that. Try again."
    /// A refusal echo without a message.
    static let refusedFallback = "Watchtower refused this action."
    /// A command the phone's transport does not carry.
    static let notOnThePhone = "This isn't available on the phone."
    /// An Inbox press in the Not delivered list: "Done in the Inbox".
    static func inInbox(_ verb: String) -> String {
        "\(verb) in the Inbox"
    }

    static let inboxAction = "An Inbox action"

    /// The root's line while the hub is away: "as of 40 min ago".
    static func asOf(_ phrase: String) -> String {
        "as of \(phrase)"
    }

    /// A reminder's link to the message it is about.
    static let messageLink = "Open the message"
    /// The ⋯ menu's title.
    static let more = "More"

    /// A verb the phone does not send, as its disabled menu entry or button: "Hand to Agent… — on your Mac".
    static func macOnlyLabel(_ label: String, note: String? = InboxText.onYourMac) -> String {
        guard let note, !note.isEmpty else { return label }
        return "\(label) — \(note.prefix(1).lowercased())\(note.dropFirst())"
    }

    /// The row detail's link out: "Open in Slack ↗" from the row's "Open in Slack".
    static func openInDetail(_ openLabel: String) -> String {
        "\(openLabel) ↗"
    }

    /// An automation card's header line (mockup §4): "ϟ Weekly mail roundup · run #12 · 2 h ago", or "ϟ Release
    /// checklist · Updated 12 min ago" on a living card.
    static func cardHeader(automation: String, run: Int64, at: Date, living: Bool, now: Date) -> String {
        if living || run <= 0 {
            return "ϟ \(automation) · \(InboxText.updatedAgo(at, now: now))"
        }
        // runLine is "ϟ run #12 · 2 h ago": the automation goes after its mark.
        return "ϟ \(automation) · \(InboxText.runLine(run: Int(run), at: at, now: now).dropFirst(2))"
    }

    /// The Didn't confirm card's title (mockup §6): the Run Now that may or may not have run.
    static func runNowTitle(_ name: String) -> String {
        "Run “\(name)” now"
    }

    /// The outbox's Inbox line while presses wait (mockup §6 Mac away).
    static func waitingToSend(_ count: Int) -> String {
        "Waiting to send · \(count)"
    }

    /// What waits ("Done · Approve") and when it applies.
    static func appliesWhenAwake(verbs: [String], hub: String) -> String {
        let when = "They apply when \(TowerText.name(hub)) wakes."
        return verbs.isEmpty ? when : "\(verbs.joined(separator: " · ")). \(when)"
    }

    static func notDeliveredCount(_ count: Int) -> String {
        "Not delivered · \(count)"
    }

    /// A queued `inbox_act`'s verb as the outbox line names it; nil for a read mark or a press.
    static func verb(of params: [String: JSONValue]) -> String? {
        guard let data = try? JSONEncoder().encode(params), let request = try? JSONDecoder().decode(ActRequest.self, from: data) else {
            return nil
        }
        switch request.verb {
        case .done: return InboxText.done
        case .dismiss: return InboxText.dismiss
        case .runNow: return InboxText.runNow
        case .replyPropose: return InboxText.reply
        case .ref:
            guard let verb = request.params.refVerb else { return nil }
            let title = InboxRefVerbs.title(verb, kind: request.params.refKind ?? .inboxItem)
            return title.isEmpty ? nil : title
        case .approval:
            switch request.params.approvalVerb {
            case .approve?: return InboxText.approve
            case .reject?: return InboxText.reject
            case .retry?: return InboxText.retry
            case .dismiss?: return InboxText.dismiss
            default: return nil
            }
        default: return nil
        }
    }

    /// Needs approval's line on the root: the first two proposals, then how many more.
    static func approvalsSummary(_ titles: [String]) -> String {
        let shown = titles.prefix(2)
        let rest = titles.count - shown.count
        return (shown + (rest > 0 ? ["\(rest) more"] : [])).joined(separator: " · ")
    }
}

/// How long a snooze lasts (the Mac's `InboxMessagePane.snoozeChoices`, the reminder's hour) and its `until`.
enum InboxSnooze: CaseIterable {
    case hour, day, threeDays, week

    var label: String {
        switch self {
        case .hour: InboxText.snoozeOneHour
        case .day: InboxText.snoozeOneDay
        case .threeDays: InboxText.snoozeThreeDays
        case .week: InboxText.snoozeOneWeek
        }
    }

    var seconds: TimeInterval {
        switch self {
        case .hour: 3_600
        case .day: 86_400
        case .threeDays: 3 * 86_400
        case .week: 7 * 86_400
        }
    }

    /// The snooze's end, RFC 3339 UTC to the second.
    func until(from now: Date) -> String {
        now.addingTimeInterval(seconds).ISO8601Format()
    }

    /// The menu's choices for an inbox item (the reminder's one hour is its own button).
    static let menu: [Self] = [.day, .threeDays, .week]
}
