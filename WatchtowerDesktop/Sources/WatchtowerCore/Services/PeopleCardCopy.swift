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
