import Foundation

/// What Discuss in Chat and Hand to Agent… carry for an Inbox card of any
/// kind: the card's title, where it came from, and its body as markdown.
/// The body quotes other people (messages, tracks, ideas, automation output),
/// so every text built from it fences it as data (`InboxCardTexts`).
package struct InboxCardSubject: Equatable, Sendable {
    package let selection: InboxSelection
    package let title: String
    /// One line, e.g. "From the Inbox card of the automation X, run #7."
    /// Fixed text for every kind but automation output: no sender, subject
    /// or title, which are other people's words and stay in the data fence.
    package let provenance: String
    /// Markdown; data, never instructions.
    package let body: String
    /// "" = none.
    package let link: String
    /// "high" | "medium" | "low".
    package let priority: String
    package let workbenchID: Int64?

    package init(
        selection: InboxSelection,
        title: String,
        provenance: String,
        body: String,
        link: String = "",
        priority: String = "medium",
        workbenchID: Int64? = nil
    ) {
        self.selection = selection
        self.title = title
        self.provenance = provenance
        self.body = body
        self.link = link
        self.priority = priority
        self.workbenchID = workbenchID
    }

    /// "inbox-card-<kind>-<id>.md": distinct per kind and card.
    package var attachmentName: String {
        let (kind, id): (String, String) = switch selection {
        case let .proposal(value): ("proposal", String(value))
        case let .reminder(value): ("reminder", String(value))
        case let .output(value): ("output", String(value))
        case let .day(value): ("day", value)
        case let .track(value): ("track", String(value))
        case let .idea(value): ("idea", String(value))
        case let .message(value): ("message", String(value))
        }
        return "inbox-card-\(kind)-\(id).md"
    }

    /// Whether the card is an automation's output: the one kind whose title
    /// is the owner's own recipe line and whose texts keep spec B2's words.
    package var isAutomationOutput: Bool {
        if case .output = selection { return true }
        return false
    }

    /// Hand to Agent…'s first line (the target's title). An automation card
    /// leads with its title (spec B2); every other kind with fixed text that
    /// names the kind and id, so a mail subject, a channel or an AI summary
    /// of colleagues' messages never becomes the first line of a task.
    package var taskLead: String {
        switch selection {
        case .output: title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        case let .message(id): "Inbox message #\(id)"
        case let .track(id): "Track #\(id)"
        case let .idea(id): "Idea #\(id)"
        case let .day(date): "Your day \(date)"
        case let .proposal(id): "Inbox proposal #\(id)"
        case let .reminder(id): "Inbox reminder #\(id)"
        }
    }
}

package extension InboxCardSubject {
    init(_ card: AutomationOutputCard) {
        self.init(
            selection: .output(card.id),
            title: card.title,
            provenance: "From the Inbox card of the automation \(card.automationName), run #\(card.runID).",
            body: card.body,
            link: card.link,
            priority: Self.priority(card.priority),
            workbenchID: card.workbenchID
        )
    }

    /// The day's briefing sections (one bullet per item) and plan items.
    init(day: InboxDayCard, items: [DayPlanItem]) {
        var sections: [String] = []
        if let briefing = day.briefing {
            sections.append(Self.section("Attention", briefing.parsedAttention.map(\.text)))
            sections.append(Self.section("Your day", briefing.parsedYourDay.map(\.text)))
            sections.append(Self.section("What happened", briefing.parsedWhatHappened.map(\.text)))
            sections.append(Self.section("Team pulse", briefing.parsedTeamPulse.map(\.text)))
            sections.append(Self.section("Coaching", briefing.parsedCoaching.map(\.text)))
        }
        let plan = items.map { item in
            let time = item.timeRange.map { "\($0) " } ?? ""
            return "[\(item.status.rawValue)] \(time)\(Self.line(item.title))"
        }
        sections.append(Self.section("Day plan (\(day.planDone) of \(day.planTotal) done)", plan))
        self.init(
            selection: .day(day.date),
            title: "Briefing and day plan of \(day.date)",
            provenance: "From the Inbox day card of \(day.date).",
            body: sections.filter { !$0.isEmpty }.joined(separator: "\n\n")
        )
    }

    /// The track and its events, the unread ones first.
    init(track card: InboxTrackCard, events: [TrackEvent]) {
        let track = card.track
        let ordered = events.filter(\.isUnread) + events.filter { !$0.isUnread }
        let lines = ordered.map { event in
            let detail = event.detail.isEmpty ? "" : ": \(Self.line(event.detail))"
            return "\(event.isUnread ? "New: " : "")\(Self.line(event.summary))\(detail)"
        }
        var parts = [track.context.isEmpty ? "" : track.context]
        parts.append(Self.section("Events", lines))
        self.init(
            selection: .track(track.id),
            title: track.text,
            provenance: "From the Inbox track #\(track.id), \(card.newEventCount) new events.",
            body: parts.filter { !$0.isEmpty }.joined(separator: "\n\n"),
            priority: Self.priority(track.priority)
        )
    }

    init(idea: Idea, mentions: [IdeaMention]) {
        let quotes = mentions.map { mention in
            let who = mention.author.isEmpty ? mention.sourceKind.label : "\(Self.line(mention.author)) (\(mention.sourceKind.label))"
            return "\(who): \(Self.line(mention.quote))"
        }
        let parts = [idea.essence, Self.section("Mentions", quotes)]
        self.init(
            selection: .idea(idea.id),
            title: idea.title,
            provenance: "From the Inbox \(idea.kind.rawValue) card #\(idea.id).",
            body: parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
        )
    }

    init(message row: HomeFeedInboxRow) {
        let item = row.item
        let place = row.whereText.map { " in \(Self.line($0))" } ?? ""
        var parts = [item.snippet]
        if !item.whyMatters.isEmpty { parts.append("Why it matters: \(item.whyMatters)") }
        if !item.threadDigest.isEmpty { parts.append("Thread: \(item.threadDigest)") }
        self.init(
            selection: .message(item.id),
            title: "\(Self.line(row.who))\(place)",
            provenance: "From the Inbox message #\(item.id).",
            body: parts.filter { !$0.isEmpty }.joined(separator: "\n\n"),
            link: item.permalink,
            priority: Self.priority(item.priority)
        )
    }

    private static func priority(_ raw: String) -> String {
        ["high", "medium", "low"].contains(raw) ? raw : "medium"
    }

    private static func line(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func section(_ heading: String, _ lines: [String]) -> String {
        let bullets = lines.map(line).filter { !$0.isEmpty }.map { "- \($0)" }
        return bullets.isEmpty ? "" : ([heading] + bullets).joined(separator: "\n")
    }
}
