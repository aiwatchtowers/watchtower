import Foundation

/// The People screens' copy (#1769, spec §5): the person card's basis line,
/// Stop card for this person / Make cards again, the Team Summary and the
/// owner's org links. `PeopleCardCopyTests` pins it to the mockups'
/// `SlackPolicyMockCopy`. `name` is the person as shown, `@dana`.
public enum PeopleCardCopy {
    public static func basisLine(messages: Int, channels: Int) -> String {
        "Based on \(messages) message\(messages == 1 ? "" : "s") in \(channels) "
            + "channel\(channels == 1 ? "" : "s") you share"
    }

    /// A card's window, "Nov 3 – Nov 16" (English, like the rest of the app).
    public static func period(from: Date, to: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "MMM d"
        return "\(formatter.string(from: from)) – \(formatter.string(from: to))"
    }

    public static let stopCard = "Stop card for this person"
    public static func stopTitle(name: String) -> String { "Stop the card for \(name)?" }
    public static func stopBody(name: String) -> String {
        "Watchtower deletes \(name)'s card and makes no new one. Messages, digests, search and "
            + "Find experts are not affected. You can make cards again later."
    }
    public static let stopConfirm = "Stop card"
    public static let cancel = "Cancel"
    public static func stoppedLine(name: String) -> String { "No card for \(name): you stopped it." }
    public static let makeAgain = "Make cards again"

    /// The CLI call behind Stop card / Make cards again failed; the card is
    /// as the database has it.
    public static func actionFailed(stopping: Bool, _ detail: String) -> String {
        (stopping ? "Couldn't stop the card: " : "Couldn't make cards again: ") + detail
    }

    /// The list's section of people whose cards the owner stopped; a row
    /// opens the stopped view with Make cards again. New copy (fix round 1).
    public static let stoppedCardsTitle = "Stopped cards"

    // The person view's other labels (moved here from the views).
    public static let overviewTab = "Overview"
    public static let connectionsTab = "Connections"
    public static let viewPickerTitle = "View"
    public static let close = "Close"
    public static let retry = "Retry"
    public static let profileContextTitle = "How the system understands you"
    public static let insufficientData = "Not enough data for full analysis. Results will improve as more "
        + "messages are collected."
    public static let insufficientDataShort = "Not enough data for full analysis"
    public static let accomplishmentsTitle = "Accomplishments"
    public static let highlightsTitle = "Highlights"
    public static let expertiseTitle = "Expertise"
    public static let historyTitle = "History"

    /// The Team Summary's run line: "haiku · 700 tokens · $0.0010".
    public static func runLine(model: String, tokens: Int, costUSD: Double) -> String {
        "\(model) · \(tokens) tokens · " + String(format: "$%.4f", costUSD)
    }

    public static let decisionRoleTitle = "Decision role"
    public static let guideTitle = "Communication Guide"
    public static let tacticsTitle = "Tactics"
    public static let teamSummaryTitle = "Team Summary"
    public static let tipsTitle = "Tips"

    public static let orgLinksTitle = "Your org links"
    public static let orgLinksEmpty = "No org links yet. Add your manager, peers and reports in your profile."
    public static let editConnections = "Edit Connections"

    /// An org link's relation to the owner.
    public enum OrgRole: Sendable {
        case manager, peer, report
    }

    public static func orgRoleTitle(_ role: OrgRole) -> String {
        switch role {
        case .manager: "Manager"
        case .peer: "Peer"
        case .report: "Report"
        }
    }
}
